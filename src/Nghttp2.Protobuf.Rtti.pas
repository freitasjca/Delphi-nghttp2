unit Nghttp2.Protobuf.Rtti;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Nghttp2.Protobuf.Rtti
//  RTTI-driven bridge between message classes and Nghttp2.Protobuf wire codec.
//  M1b of the horse-provider-nghttp2 gRPC plan (2026-08-07).
//
//  Enumerates `[ProtoMember(N)]`-annotated published properties on a message
//  class, caches the tag→property map per class, and orchestrates
//  serialize/deserialize through TProtoWriter / TProtoReader from
//  Nghttp2.Protobuf.
//
//  Types supported:
//    Int32 / Integer  — pkInt32        Single      — pkFloat
//    Int64            — pkInt64        Double      — pkDouble
//    string           — pkString       enum        — pkEnum (int32 varint)
//    Boolean          — pkBool         TBytes      — pkBytes
//    nested class     — pkSubmessage
//    TArray<T>        — repeated, for any T above  (M1c.2)
//
//  TBytes is proto3 `bytes` (a scalar), NOT `repeated uint8` — so TArray<Byte>
//  is deliberately excluded from repeated handling. Changing that would
//  re-frame every existing bytes field on the wire.
//
//  Still deferred:
//    ZigZag (sint32/sint64), fixed/sfixed, unsigned (uint32/uint64), maps
//
//  ── Design decisions ─────────────────────────────────────────────────────
//
//  1. Global TRttiContext — per horse-grpc SKILL §3 "RTTI Context Lifetime":
//     TRttiContext is a value type but internally refs a global manager;
//     using a class-var static instance keeps every discovered TRttiType
//     and TRttiProperty valid for the process lifetime, avoiding dangling
//     refs during concurrent serialize/deserialize.
//
//  2. Thread-safe cache — TDictionary<TClass, TProtoTypeInfo> guarded by
//     TCriticalSection. Once a class is scanned, subsequent calls hit the
//     cache. Fast path is lock-and-lookup.
//
//  3. Attribute discovery — Delphi and FPC 3.2+ both expose
//     TRttiProperty.GetAttributes returning a TArray of TCustomAttribute
//     descendants. Filter by "is TProtoMemberAttribute".
//
//  4. Type inference from Pascal type — TypInfo.TTypeKind + property type
//     handle. `Boolean` is a TypeKind = tkEnumeration whose handle equals
//     TypeInfo(Boolean); disambiguate via handle comparison.
//
//  5. Value marshalling — TRttiProperty.GetValue / SetValue with TValue.
//     Use From<T> for correct type tagging when SetValue-ing a TValue back.
//
//  This file dual-compiles on Delphi and FPC/Lazarus.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, SyncObjs, Rtti, TypInfo, Generics.Collections
{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs, System.Rtti,
  System.TypInfo, System.Generics.Collections
{$IFEND}
  , Nghttp2.Protobuf;

type
  // ── Proto3 field kinds we can currently marshal ──────────────────────────
  // M1c   (2026-08-07) added pkFloat, pkDouble, pkEnum, pkBytes, pkSubmessage.
  // M1c.2 (2026-08-20) added REPEATED fields: any TArray<T> whose T is one of
  //   the kinds below — packed on the wire for numerics, LEN-per-element for
  //   string/bytes/submessage. Repeated is a framing property, recorded on
  //   TProtoFieldInfo.IsRepeated, not a kind of its own.
  // Still deferred: unsigned variants (UInt32/UInt64), ZigZag variants
  //   (SInt32/SInt64), fixed variants (Fixed32/64/SFixed32/64), and maps.
  TProtoFieldKind = (
    pkInt32,
    pkInt64,
    pkString,
    pkBool,
    pkFloat,
    pkDouble,
    pkEnum,       // encoded as int32 varint on the wire
    pkBytes,      // TBytes property
    pkSubmessage  // nested TObject class instance
  );

  // ── Cached info about ONE annotated property ─────────────────────────────
  TProtoFieldInfo = record
    Tag:            Integer;
    Name:           string;           // property name — for diagnostics
    Prop:           TRttiProperty;    // long-lived — anchored to THorseProtobufRtti.FContext
    { For a repeated field this is the ELEMENT kind, not a kind of its own.
      Keeping it that way is what lets the scalar read/write code below be
      reused per element instead of duplicated into a parallel enum. }
    Kind:           TProtoFieldKind;
    SubmessageClass: TClass;          // set only when Kind = pkSubmessage

    // ── Repeated fields (M1c.2) ────────────────────────────────────────────
    IsRepeated:     Boolean;          // property is TArray<T>, T <> Byte
    ArrayTypeInfo:  PTypeInfo;        // the TArray<T> type — for TValue.FromArray
    ElemTypeInfo:   PTypeInfo;        // T — for building element TValues
  end;

  // ── Cached info about ONE message class ──────────────────────────────────
  TProtoTypeInfo = record
    TypeClass: TClass;
    Fields:    TArray<TProtoFieldInfo>;   // ORDERED BY TAG for deterministic output
  end;

  // ── Errors ───────────────────────────────────────────────────────────────
  EProtoRttiError = class(Exception);

  // ── Global registry / cache (singleton via class methods) ────────────────
  { THorseProtobufRtti is a process-wide singleton implemented via class
    methods + class vars. The one TRttiContext instance lives for the
    program lifetime — every TRttiType and TRttiProperty returned from
    GetTypeInfo remains valid until the program exits.

    Thread-safe: all mutation of the cache dictionary is guarded by
    FLock. Repeat lookups for the same class are O(1) after the first
    scan. }
  THorseProtobufRtti = class
  strict private
    class var FContext: TRttiContext;
    class var FCache:   TDictionary<TClass, TProtoTypeInfo>;
    class var FLock:    TCriticalSection;
    class var FReady:   Boolean;

    class procedure LazyInit;
    class function BuildTypeInfo(AClass: TClass): TProtoTypeInfo;
    { Maps one RTTI type to a scalar proto kind. Split out of InferProtoKind so
      the repeated branch can ask the same question about its ELEMENT type —
      `repeated int32` and `int32` differ in framing, never in element coding.
      ADesc names what is being described in error text ("property X" vs
      "element type of property X"), because a failure inside an array is
      otherwise indistinguishable from one on the property itself. }
    class procedure InferScalarKind(ARttiType: TRttiType; const ADesc: string;
      out AKind: TProtoFieldKind; out ASubmessageClass: TClass);
    class procedure InferProtoKind(AProp: TRttiProperty; var AField: TProtoFieldInfo);
  public
    (* GetTypeInfo returns cached info for AClass, building it on first call.
       Raises EProtoRttiError if AClass has NO ProtoMember-annotated
       properties -- most likely a caller mistake (forgot the M+ directive,
       forgot published section, or forgot the attribute). *)
    class function GetTypeInfo(AClass: TClass): TProtoTypeInfo;

    (* Explicit shutdown (rarely needed -- finalization does this too).
       Idempotent. *)
    class procedure Shutdown;
  end;

  // ── Orchestrator ─────────────────────────────────────────────────────────
  { TProtoSerializer converts between proto3 wire bytes and message-class
    instances. Uses THorseProtobufRtti for field discovery and
    Nghttp2.Protobuf for wire I/O. Stateless — all methods are class-level. }
  TProtoSerializer = class
  public
    { Serialize the published-property state of AObj into proto3 bytes.
      AObj MUST be a class instance with at least one `[ProtoMember]`
      annotated published property. }
    class function Serialize(AObj: TObject): TBytes;

    { Deserialize AData into AObj's published properties. AObj must
      already be constructed by the caller (proto3 has no distinct
      "message present" state — an empty byte array leaves AObj with
      Pascal-default field values). Unknown fields in AData are silently
      skipped per proto3 spec. }
    class procedure Deserialize(const AData: TBytes; AObj: TObject);
  end;

implementation

// ── THorseProtobufRtti ───────────────────────────────────────────────────────

class procedure THorseProtobufRtti.LazyInit;
begin
  // Guard against double-init in racy scenarios — use a boolean flag with
  // a critical-section double-check. First call in a process bootstraps
  // FContext, FCache, FLock; subsequent calls no-op.
  if FReady then Exit;

  // We're pre-Lock construction — use a plain create-and-set pattern.
  // The class-var write is atomic on all supported architectures for
  // pointer-sized values, and the FReady flag write is the "commit" point.
  if FLock = nil then
    FLock := TCriticalSection.Create;
  FLock.Enter;
  try
    if FReady then Exit;
    // Sentinel: FContext value-type is zero-initialised by class-var default
    // (its internal ref-manager pointer is nil, triggering lazy manager
    // acquisition on first GetType). No explicit Create needed.
    FCache := TDictionary<TClass, TProtoTypeInfo>.Create;
    FReady := True;
  finally
    FLock.Leave;
  end;
end;

class procedure THorseProtobufRtti.Shutdown;
begin
  if not FReady then Exit;
  FLock.Enter;
  try
    if not FReady then Exit;
    FCache.Free;
    FCache := nil;
    FContext.Free;
    FReady := False;
  finally
    FLock.Leave;
  end;
  FLock.Free;
  FLock := nil;
end;

class function THorseProtobufRtti.GetTypeInfo(AClass: TClass): TProtoTypeInfo;
begin
  LazyInit;

  FLock.Enter;
  try
    if FCache.TryGetValue(AClass, Result) then Exit;

    Result := BuildTypeInfo(AClass);
    FCache.Add(AClass, Result);
  finally
    FLock.Leave;
  end;
end;

class procedure THorseProtobufRtti.InferScalarKind(ARttiType: TRttiType;
  const ADesc: string; out AKind: TProtoFieldKind; out ASubmessageClass: TClass);
var
  LTypeInfo:  PTypeInfo;
  LDynArrType: TRttiDynamicArrayType;
begin
  LTypeInfo        := ARttiType.Handle;
  ASubmessageClass := nil;

  case ARttiType.TypeKind of
    tkInteger:
      AKind := pkInt32;
    tkInt64:
      AKind := pkInt64;
    tkChar, tkWChar, tkString, tkLString, tkWString, tkUString
    {$IF DEFINED(FPC)}
      // FPC: with {$MODE DELPHI}{$H+}, `string` = AnsiString = tkAString (9).
      // Delphi's `string` = UnicodeString = tkUString (24); its `AnsiString`
      // is tkLString (already in the list above). This branch mirrors both.
      , tkAString
    {$IFEND}:
      AKind := pkString;
    tkEnumeration:
      begin
        // Boolean on Delphi is a Pascal enumeration whose PTypeInfo is
        // System.Boolean. Every other enum type maps to pkEnum (int32 on
        // the wire). On FPC, Boolean has its own TypeKind (tkBool = 18),
        // handled by the FPC-only branch below — this arm covers only true
        // enumerations there.
        if LTypeInfo = System.TypeInfo(Boolean) then
          AKind := pkBool
        else
          AKind := pkEnum;
      end;
{$IF DEFINED(FPC)}
    tkBool:
      // FPC-only: Boolean has a distinct TypeKind (18), not tkEnumeration.
      // ByteBool / WordBool / LongBool also land here — all map to proto3 bool
      // (single-byte varint on the wire).
      AKind := pkBool;
{$IFEND}
    tkFloat:
      begin
        // Distinguish Single vs Double by the underlying PTypeInfo handle.
        // Extended, Comp, Currency deliberately excluded — not proto3 scalars.
        if LTypeInfo = System.TypeInfo(Single) then
          AKind := pkFloat
        else if LTypeInfo = System.TypeInfo(Double) then
          AKind := pkDouble
        else
          raise EProtoRttiError.CreateFmt(
            'ProtoMember %s: tkFloat with type kind not Single/Double is unsupported. ' +
            'Proto3 supports only float (Single) and double (Double).',
            [ADesc]);
      end;
    tkDynArray:
      begin
        { Only TBytes reaches here as a SCALAR — proto3 `bytes` is a length-
          delimited scalar, not a repeated field. Every other dynamic array is
          a repeated field and was peeled off by InferProtoKind before this
          call, so arriving here with one means nesting: TArray<TArray<T>>,
          which proto3 cannot express (repeated repeated is illegal; it
          requires a wrapper message). }
        LDynArrType := ARttiType as TRttiDynamicArrayType;
        if (LDynArrType.ElementType <> nil)
          and (LDynArrType.ElementType.Handle = System.TypeInfo(Byte)) then
          AKind := pkBytes
        else
          raise EProtoRttiError.CreateFmt(
            'ProtoMember %s: nested dynamic array. proto3 has no "repeated repeated" — ' +
            'wrap the inner array in a message class and use TArray<TWrapper>.',
            [ADesc]);
      end;
    tkClass:
      begin
        // Nested message. Return the class handle so Serialize/Deserialize
        // can recurse via GetTypeInfo(ASubmessageClass).
        AKind := pkSubmessage;
        ASubmessageClass := (ARttiType as TRttiInstanceType).MetaclassType;
      end;
  else
    raise EProtoRttiError.CreateFmt(
      'ProtoMember %s has type kind %d — not supported. ' +
      'Covered: Int32/Int64/string/Boolean/Float/Double/Enum/TBytes/submessage, ' +
      'and TArray<> of any of those. ' +
      'UInt/SInt/Fixed variants remain deferred.',
      [ADesc, Ord(ARttiType.TypeKind)]);
  end;
end;

{ Peels one level of "repeated" off the property type, then defers to
  InferScalarKind for the element.

  TBytes is the deliberate exception: TArray<Byte> is proto3 `bytes`, a scalar,
  NOT `repeated uint8`. Testing for it before treating any dynamic array as
  repeated is what keeps existing TBytes fields encoding exactly as they did —
  the alternative would silently re-frame every one of them and break the wire
  compatibility the 52/52 codec suite locks in. }
class procedure THorseProtobufRtti.InferProtoKind(AProp: TRttiProperty;
  var AField: TProtoFieldInfo);
var
  LDynArrType: TRttiDynamicArrayType;
  LElemType:   TRttiType;
begin
  AField.IsRepeated    := False;
  AField.ArrayTypeInfo := nil;
  AField.ElemTypeInfo  := nil;

  if AProp.PropertyType.TypeKind = tkDynArray then
  begin
    LDynArrType := AProp.PropertyType as TRttiDynamicArrayType;
    LElemType   := LDynArrType.ElementType;

    if LElemType = nil then
      raise EProtoRttiError.CreateFmt(
        'ProtoMember property "%s": dynamic array with no element RTTI.', [AProp.Name]);

    if LElemType.Handle <> System.TypeInfo(Byte) then
    begin
      AField.IsRepeated    := True;
      AField.ArrayTypeInfo := AProp.PropertyType.Handle;
      AField.ElemTypeInfo  := LElemType.Handle;
      InferScalarKind(LElemType,
        Format('element type of property "%s"', [AProp.Name]),
        AField.Kind, AField.SubmessageClass);
      Exit;
    end;
  end;

  InferScalarKind(AProp.PropertyType, Format('property "%s"', [AProp.Name]),
    AField.Kind, AField.SubmessageClass);
end;

class function THorseProtobufRtti.BuildTypeInfo(AClass: TClass): TProtoTypeInfo;
var
  LType:  TRttiType;
  LProp:  TRttiProperty;
  LAttr:  TCustomAttribute;
  LMember: TProtoMemberAttribute;
  LList:  TList<TProtoFieldInfo>;
  LField: TProtoFieldInfo;
  I, J:   Integer;
  LTmp:   TProtoFieldInfo;
begin
  Result.TypeClass := AClass;

  LType := FContext.GetType(AClass);
  if LType = nil then
    raise EProtoRttiError.CreateFmt('No RTTI for class %s — is {$M+} enabled in its unit?', [AClass.ClassName]);

  LList := TList<TProtoFieldInfo>.Create;
  try
    for LProp in LType.GetProperties do
    begin
      // Only published properties can carry attributes reliably on both
      // compilers (public/protected/private RTTI is limited). Filter here.
      if LProp.Visibility <> mvPublished then Continue;

      LMember := nil;
      for LAttr in LProp.GetAttributes do
        if LAttr is TProtoMemberAttribute then
        begin
          LMember := TProtoMemberAttribute(LAttr);
          Break;
        end;
      if LMember = nil then Continue;

      { Zeroed rather than assigned field-by-field: TProtoFieldInfo gained
        repeated-field members, and LField is reused across loop iterations —
        a stale IsRepeated from the previous property would otherwise carry
        into this one. }
      Finalize(LField);
      FillChar(LField, SizeOf(LField), 0);

      LField.Tag  := LMember.Tag;
      LField.Name := LProp.Name;
      LField.Prop := LProp;
      InferProtoKind(LProp, LField);

      LList.Add(LField);
    end;

    if LList.Count = 0 then
      raise EProtoRttiError.CreateFmt(
        'Class %s has no [ProtoMember]-annotated published properties. '
        + 'Check {$M+}, `published` section, and TProtoMemberAttribute imports.',
        [AClass.ClassName]);

    // Sort by tag for deterministic wire output. Small N (typically < 20)
    // so a simple insertion sort in-place is fine — no need for TArray.Sort.
    for I := 1 to LList.Count - 1 do
    begin
      LTmp := LList[I];
      J := I - 1;
      while (J >= 0) and (LList[J].Tag > LTmp.Tag) do
      begin
        LList[J + 1] := LList[J];
        Dec(J);
      end;
      LList[J + 1] := LTmp;
    end;

    SetLength(Result.Fields, LList.Count);
    for I := 0 to LList.Count - 1 do
      Result.Fields[I] := LList[I];
  finally
    LList.Free;
  end;
end;

// ── TProtoSerializer ─────────────────────────────────────────────────────────

{ proto3 packs repeated NUMERIC scalars by default: one LEN record holding the
  concatenated values, no per-element tag. string / bytes / submessage cannot
  be packed — their encodings are already length-delimited, so packing would be
  ambiguous — and are emitted as one tagged record per element.

  Decoders must accept BOTH forms for packable types regardless of which the
  encoder chose (proto3 language guide, "Packed Encoding"); Deserialize below
  does. This function only decides what we EMIT. }
function IsPackableKind(AKind: TProtoFieldKind): Boolean;
begin
  Result := AKind in [pkInt32, pkInt64, pkBool, pkEnum, pkFloat, pkDouble];
end;

{ One packed element, tagless, into AWriter. Mirrors the body of the matching
  Write*Field in Nghttp2.Protobuf minus its WriteTag — the encodings must stay
  identical, only the framing differs. }
procedure WritePackedElement(AWriter: TProtoWriter; AKind: TProtoFieldKind;
  const AValue: TValue);
var
  LU32: UInt32;
  LU64: UInt64;
  LSingle: Single;
  LDouble: Double;
begin
  case AKind of
    pkInt32: AWriter.WriteVarint(UInt64(Int64(AValue.AsInteger)));
    pkInt64: AWriter.WriteVarint(UInt64(AValue.AsInt64));
    pkBool:  if AValue.AsBoolean then AWriter.WriteVarint(1) else AWriter.WriteVarint(0);
    pkEnum:  AWriter.WriteVarint(UInt64(Int64(AValue.AsOrdinal)));
    pkFloat:
      begin
        LSingle := AValue.AsType<Single>;
        Move(LSingle, LU32, 4);
        AWriter.WriteFixed32(LU32);
      end;
    pkDouble:
      begin
        LDouble := AValue.AsType<Double>;
        Move(LDouble, LU64, 8);
        AWriter.WriteFixed64(LU64);
      end;
  else
    raise EProtoRttiError.CreateFmt(
      'WritePackedElement: kind %d is not packable.', [Ord(AKind)]);
  end;
end;

{ One tagged element for a non-packable repeated field. Each element repeats
  the tag, which is exactly how proto3 encodes repeated string/bytes/message. }
procedure WriteUnpackedElement(AWriter: TProtoWriter; ATag: Integer;
  AKind: TProtoFieldKind; const AValue: TValue);
var
  LSubObj: TObject;
begin
  case AKind of
    pkString: AWriter.WriteStringField(ATag, AValue.AsString);
    pkBytes:  AWriter.WriteBytesField(ATag, AValue.AsType<TBytes>);
    pkSubmessage:
      begin
        LSubObj := AValue.AsObject;
        { A nil ELEMENT is not the same as an absent field. Skipping it would
          silently shorten the array the peer receives, so the count no longer
          matches what was sent — encode it as a zero-length submessage, which
          decodes to a default-constructed instance. }
        if LSubObj = nil then
          AWriter.WriteSubmessageField(ATag, nil)
        else
          AWriter.WriteSubmessageField(ATag, TProtoSerializer.Serialize(LSubObj));
      end;
  else
    raise EProtoRttiError.CreateFmt(
      'WriteUnpackedElement: kind %d unexpected here.', [Ord(AKind)]);
  end;
end;

class function TProtoSerializer.Serialize(AObj: TObject): TBytes;
var
  LInfo:      TProtoTypeInfo;
  LWriter:    TProtoWriter;
  LField:     TProtoFieldInfo;
  LValue:     TValue;
  LSubObj:    TObject;
  LSubBytes:  TBytes;
  LPacked:    TProtoWriter;   // M1c.2 — packed repeated payload
  LCount:     Integer;
  LIdx:       Integer;
begin
  if AObj = nil then
    raise EProtoRttiError.Create('Serialize: AObj is nil');

  LInfo := THorseProtobufRtti.GetTypeInfo(AObj.ClassType);
  LWriter := TProtoWriter.Create;
  try
    for LField in LInfo.Fields do
    begin
      LValue := LField.Prop.GetValue(AObj);

      // ── Repeated (M1c.2) ────────────────────────────────────────────────
      if LField.IsRepeated then
      begin
        LCount := LValue.GetArrayLength;
        { An empty repeated field emits nothing at all — proto3 has no way to
          distinguish "empty" from "absent", and both decode to length 0. }
        if LCount = 0 then Continue;

        if IsPackableKind(LField.Kind) then
        begin
          LPacked := TProtoWriter.Create;
          try
            for LIdx := 0 to LCount - 1 do
              WritePackedElement(LPacked, LField.Kind, LValue.GetArrayElement(LIdx));
            { WriteSubmessageField is just "tag with pwLen + length-prefixed
              payload", which is precisely the packed framing — reused rather
              than reimplemented so the two cannot drift. }
            LWriter.WriteSubmessageField(LField.Tag, LPacked.ToBytes);
          finally
            LPacked.Free;
          end;
        end
        else
          for LIdx := 0 to LCount - 1 do
            WriteUnpackedElement(LWriter, LField.Tag, LField.Kind,
              LValue.GetArrayElement(LIdx));

        Continue;
      end;

      case LField.Kind of
        pkInt32:   LWriter.WriteInt32Field(LField.Tag, LValue.AsInteger);
        pkInt64:   LWriter.WriteInt64Field(LField.Tag, LValue.AsInt64);
        pkString:  LWriter.WriteStringField(LField.Tag, LValue.AsString);
        pkBool:    LWriter.WriteBoolField(LField.Tag, LValue.AsBoolean);
        pkFloat:   LWriter.WriteFloatField(LField.Tag, LValue.AsExtended);
        pkDouble:  LWriter.WriteDoubleField(LField.Tag, LValue.AsExtended);
        pkEnum:    LWriter.WriteEnumField(LField.Tag, LValue.AsOrdinal);
        pkBytes:   LWriter.WriteBytesField(LField.Tag, LValue.AsType<TBytes>);
        pkSubmessage:
          begin
            // Nested message — recurse.  Nil submessage means "field absent"
            // per proto3 default semantics — skip emission entirely.
            LSubObj := LValue.AsObject;
            if LSubObj = nil then Continue;
            LSubBytes := TProtoSerializer.Serialize(LSubObj);
            LWriter.WriteSubmessageField(LField.Tag, LSubBytes);
          end;
      else
        raise EProtoRttiError.CreateFmt(
          'Serialize: field "%s" (tag %d) — unhandled ProtoKind %d.',
          [LField.Name, LField.Tag, Ord(LField.Kind)]);
      end;
    end;
    Result := LWriter.ToBytes;
  finally
    LWriter.Free;
  end;
end;

{ Reads ONE element of a repeated field from AReader, positioned just after its
  tag (unpacked) or at the next value inside a packed block. AElemTypeInfo is
  needed only for enums, whose TValue must carry the concrete enum type rather
  than a bare ordinal. }
function ReadScalarElement(AReader: TProtoReader; AKind: TProtoFieldKind;
  AElemTypeInfo: PTypeInfo; ASubmessageClass: TClass): TValue;
var
  LSubObj: TObject;
begin
  case AKind of
    pkInt32:  Result := TValue.From<Integer>(AReader.ReadVarintAsInt32);
    pkInt64:  Result := TValue.From<Int64>(AReader.ReadVarintAsInt64);
    pkBool:   Result := TValue.From<Boolean>(AReader.ReadBool);
    pkFloat:  Result := TValue.From<Single>(AReader.ReadFloat);
    pkDouble: Result := TValue.From<Double>(AReader.ReadDouble);
    pkEnum:   Result := TValue.FromOrdinal(AElemTypeInfo, AReader.ReadVarintAsInt32);
    pkString: Result := TValue.From<string>(AReader.ReadString);
    pkBytes:  Result := TValue.From<TBytes>(AReader.ReadBytes);
    pkSubmessage:
      begin
        { Every element gets its own instance. The array owns them, so the
          message class is responsible for freeing them in its destructor —
          same contract as a scalar submessage property. }
        LSubObj := ASubmessageClass.Create;
        TProtoSerializer.Deserialize(AReader.ReadBytes, LSubObj);
        { TValue.Make with the ELEMENT's type info, not TValue.From<TObject>.
          The latter tags the value as plain TObject, and TValue.FromArray
          then has to fit a TObject-typed element into a TArray<TConcrete> —
          which fails outright on FPC and is merely unchecked on Delphi.
          Make carries the declared class through. }
        TValue.Make(@LSubObj, AElemTypeInfo, Result);
      end;
  else
    raise EProtoRttiError.CreateFmt(
      'ReadScalarElement: unhandled kind %d.', [Ord(AKind)]);
  end;
end;

class procedure TProtoSerializer.Deserialize(const AData: TBytes; AObj: TObject);
var
  LInfo:       TProtoTypeInfo;
  LReader:     TProtoReader;
  LTag:        Integer;
  LWire:       TProtoWireType;
  LField:      TProtoFieldInfo;
  I:           Integer;
  LFound:      Boolean;
  LValue:      TValue;
  LEnumOrd:    Int32;
  LSubBytes:   TBytes;
  LSubObj:     TObject;
  { M1c.2 — repeated fields accumulate across wire records rather than
    overwriting. A sender may split one repeated field into several records
    (and may mix packed with unpacked), so the array can only be built once
    the whole message has been read. Keyed by tag. }
  LRepeated:   TObjectDictionary<Integer, TList<TValue>>;
  LAccum:      TList<TValue>;
  LPackReader: TProtoReader;
  LElems:      TArray<TValue>;
begin
  if AObj = nil then
    raise EProtoRttiError.Create('Deserialize: AObj is nil');

  LInfo := THorseProtobufRtti.GetTypeInfo(AObj.ClassType);

  LRepeated := TObjectDictionary<Integer, TList<TValue>>.Create([doOwnsValues]);
  try
  LReader := TProtoReader.Create(AData);
  try
    while LReader.ReadTag(LTag, LWire) do
    begin
      LFound := False;
      for I := 0 to Length(LInfo.Fields) - 1 do
      begin
        if LInfo.Fields[I].Tag = LTag then
        begin
          LField := LInfo.Fields[I];
          LFound := True;

          // ── Repeated (M1c.2) ────────────────────────────────────────────
          if LField.IsRepeated then
          begin
            if not LRepeated.TryGetValue(LTag, LAccum) then
            begin
              LAccum := TList<TValue>.Create;
              LRepeated.Add(LTag, LAccum);
            end;

            { A packable kind arriving as pwLen is a PACKED block: one record
              holding many tagless values. The same kind arriving as its
              native wire type is a single unpacked element. proto3 requires
              decoders to accept both no matter which the encoder chose, and
              this is the branch that honours it.

              Non-packable kinds (string/bytes/message) are also pwLen, hence
              the IsPackableKind guard — without it every repeated string
              would be misread as a packed block of varints. }
            if IsPackableKind(LField.Kind) and (LWire = pwLen) then
            begin
              LPackReader := TProtoReader.Create(LReader.ReadLenBytes);
              try
                while not LPackReader.Eof do
                  LAccum.Add(ReadScalarElement(LPackReader, LField.Kind,
                    LField.ElemTypeInfo, LField.SubmessageClass));
              finally
                LPackReader.Free;
              end;
            end
            else
              LAccum.Add(ReadScalarElement(LReader, LField.Kind,
                LField.ElemTypeInfo, LField.SubmessageClass));

            Break;
          end;

          case LField.Kind of
            pkInt32:
              begin
                LValue := TValue.From<Integer>(LReader.ReadVarintAsInt32);
                LField.Prop.SetValue(AObj, LValue);
              end;
            pkInt64:
              begin
                LValue := TValue.From<Int64>(LReader.ReadVarintAsInt64);
                LField.Prop.SetValue(AObj, LValue);
              end;
            pkString:
              begin
                LValue := TValue.From<string>(LReader.ReadString);
                LField.Prop.SetValue(AObj, LValue);
              end;
            pkBool:
              begin
                LValue := TValue.From<Boolean>(LReader.ReadBool);
                LField.Prop.SetValue(AObj, LValue);
              end;
            pkFloat:
              begin
                LValue := TValue.From<Single>(LReader.ReadFloat);
                LField.Prop.SetValue(AObj, LValue);
              end;
            pkDouble:
              begin
                LValue := TValue.From<Double>(LReader.ReadDouble);
                LField.Prop.SetValue(AObj, LValue);
              end;
            pkEnum:
              begin
                // Enums encode as int32 varint. SetValue accepts an ordinal
                // TValue via TValue.FromOrdinal(TypeInfo, Value).
                LEnumOrd := LReader.ReadVarintAsInt32;
                LValue := TValue.FromOrdinal(LField.Prop.PropertyType.Handle, LEnumOrd);
                LField.Prop.SetValue(AObj, LValue);
              end;
            pkBytes:
              begin
                LValue := TValue.From<TBytes>(LReader.ReadBytes);
                LField.Prop.SetValue(AObj, LValue);
              end;
            pkSubmessage:
              begin
                // Read the LEN-prefixed submessage bytes, then recurse.
                // If the current property value is nil, allocate a fresh
                // instance of the submessage class (parameterless Create).
                LSubBytes := LReader.ReadBytes;
                LSubObj := LField.Prop.GetValue(AObj).AsObject;
                if LSubObj = nil then
                begin
                  LSubObj := LField.SubmessageClass.Create;
                  LField.Prop.SetValue(AObj, LSubObj);
                end;
                TProtoSerializer.Deserialize(LSubBytes, LSubObj);
              end;
          else
            raise EProtoRttiError.CreateFmt(
              'Deserialize: field "%s" (tag %d) — unhandled ProtoKind %d.',
              [LField.Name, LField.Tag, Ord(LField.Kind)]);
          end;
          Break;
        end;
      end;

      // Unknown field: proto3 requires silent skip.
      if not LFound then
        LReader.SkipField(LWire);
    end;

    { M1c.2 — build each repeated property once, now that every record for it
      has been seen. Assigning inside the read loop instead would make an array
      split across records overwrite itself down to its final fragment. }
    for I := 0 to Length(LInfo.Fields) - 1 do
    begin
      if not LInfo.Fields[I].IsRepeated then Continue;
      if not LRepeated.TryGetValue(LInfo.Fields[I].Tag, LAccum) then Continue;

      LElems := LAccum.ToArray;
      LValue := TValue.FromArray(LInfo.Fields[I].ArrayTypeInfo, LElems);
      LInfo.Fields[I].Prop.SetValue(AObj, LValue);
    end;
  finally
    LReader.Free;
  end;
  finally
    LRepeated.Free;
  end;
end;

initialization
  // FReady starts False by class-var default; LazyInit brings us up on first use.

finalization
  THorseProtobufRtti.Shutdown;

end.
