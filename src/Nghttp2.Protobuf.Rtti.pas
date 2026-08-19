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
//  Types supported in M1b (the 90% subset — extend in follow-up milestones):
//    Int32 / Integer  — pkInt32
//    Int64            — pkInt64
//    string           — pkString (UTF-8)
//    Boolean          — pkBool
//
//  Deferred to M1c or later:
//    ZigZag (sint32/sint64), fixed/sfixed, float/double, enum, bytes,
//    submessages, repeated fields (packed + LEN)
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
  // M1c (2026-08-07) adds pkFloat, pkDouble, pkEnum, pkBytes, pkSubmessage.
  // Still deferred to M1c.2: unsigned variants (UInt32/UInt64), ZigZag variants
  // (SInt32/SInt64), fixed variants (Fixed32/64/SFixed32/64), and repeated
  // fields (packed for numeric via TArray<T>, LEN-per-element for others).
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
    Kind:           TProtoFieldKind;
    SubmessageClass: TClass;          // set only when Kind = pkSubmessage
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
    class procedure InferProtoKind(AProp: TRttiProperty;
      out AKind: TProtoFieldKind; out ASubmessageClass: TClass);
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

class procedure THorseProtobufRtti.InferProtoKind(AProp: TRttiProperty;
  out AKind: TProtoFieldKind; out ASubmessageClass: TClass);
var
  LTypeInfo:  PTypeInfo;
  LDynArrType: TRttiDynamicArrayType;
begin
  LTypeInfo        := AProp.PropertyType.Handle;
  ASubmessageClass := nil;

  case AProp.PropertyType.TypeKind of
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
            'ProtoMember property "%s": tkFloat with type kind not Single/Double is unsupported. ' +
            'Proto3 supports only float (Single) and double (Double).',
            [AProp.Name]);
      end;
    tkDynArray:
      begin
        // Only TBytes (= TArray<Byte>) is supported in M1c. Other dynamic
        // arrays would be "repeated <element>" — deferred to M1c.2.
        LDynArrType := AProp.PropertyType as TRttiDynamicArrayType;
        if (LDynArrType.ElementType <> nil)
          and (LDynArrType.ElementType.Handle = System.TypeInfo(Byte)) then
          AKind := pkBytes
        else
          raise EProtoRttiError.CreateFmt(
            'ProtoMember property "%s": tkDynArray of non-Byte element is unsupported. ' +
            'Repeated-field support is deferred to M1c.2. Use TBytes for arbitrary byte payloads.',
            [AProp.Name]);
      end;
    tkClass:
      begin
        // Nested message. Return the class handle so Serialize/Deserialize
        // can recurse via GetTypeInfo(ASubmessageClass).
        AKind := pkSubmessage;
        ASubmessageClass := (AProp.PropertyType as TRttiInstanceType).MetaclassType;
      end;
  else
    raise EProtoRttiError.CreateFmt(
      'ProtoMember property "%s" has type kind %d — not supported. ' +
      'M1c covers Int32/Int64/string/Boolean/Float/Double/Enum/TBytes/submessage. ' +
      'UInt/SInt/Fixed variants + repeated fields deferred to M1c.2.',
      [AProp.Name, Ord(AProp.PropertyType.TypeKind)]);
  end;
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

      LField.Tag  := LMember.Tag;
      LField.Name := LProp.Name;
      LField.Prop := LProp;
      InferProtoKind(LProp, LField.Kind, LField.SubmessageClass);

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

class function TProtoSerializer.Serialize(AObj: TObject): TBytes;
var
  LInfo:      TProtoTypeInfo;
  LWriter:    TProtoWriter;
  LField:     TProtoFieldInfo;
  LValue:     TValue;
  LSubObj:    TObject;
  LSubBytes:  TBytes;
begin
  if AObj = nil then
    raise EProtoRttiError.Create('Serialize: AObj is nil');

  LInfo := THorseProtobufRtti.GetTypeInfo(AObj.ClassType);
  LWriter := TProtoWriter.Create;
  try
    for LField in LInfo.Fields do
    begin
      LValue := LField.Prop.GetValue(AObj);
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
begin
  if AObj = nil then
    raise EProtoRttiError.Create('Deserialize: AObj is nil');

  LInfo := THorseProtobufRtti.GetTypeInfo(AObj.ClassType);

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
  finally
    LReader.Free;
  end;
end;

initialization
  // FReady starts False by class-var default; LazyInit brings us up on first use.

finalization
  THorseProtobufRtti.Shutdown;

end.
