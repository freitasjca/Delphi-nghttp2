unit Nghttp2.Protobuf.WellKnown;

// ============================================================================
//  Nghttp2.Protobuf.WellKnown — Pascal equivalents of the protobuf
//  "well-known types" that are ORDINARY MESSAGES.
//
//  ── Why this unit exists ──
//
//  These were never a codec limitation. google.protobuf.Timestamp is
//  int64 seconds + int32 nanos; FieldMask is a repeated string. The RTTI
//  serializer has handled shapes like that since M1b. They failed only because
//  nobody had written the Pascal.
//
//  A survey of 7300 googleapis schemas put them at 1504 files, 21% — the
//  single largest remaining gap once nested declarations were flattened, and
//  1395 of those want one of the plain types below.
//
//  Struct, Value, ListValue and NullValue joined them in STRUCT-1 once
//  PRESENCE-1, ONEOF-1 and MAP-1 supplied what they needed — see the block
//  above their declarations below. The corpus tally put 286 of 7301 files
//  behind that family alone.
//
//  ── What is deliberately NOT here ──
//
//  Any, Api, Type, DescriptorProto. Any carries a type URL and an opaque
//  payload, so it needs dynamic type resolution — a registry mapping URLs to
//  classes at run time, which is a feature rather than four classes. The rest
//  are protobuf's own reflection machinery. 37 files want Any; 6 want the
//  others. Refusing them is honest where a half-working Any would not be.
//
//  ── Wire compatibility ──
//
//  Field numbers below are from google/protobuf/*.proto and are the contract.
//  A peer built with protoc encodes Timestamp as tag 1 varint + tag 2 varint;
//  so does this. Property NAMES are ours to choose and mean nothing on the
//  wire — see the `value` collision note on TProtobufBytesValue.
// ============================================================================

{$M+}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

// FPC needs the explicit extended-RTTI directive alongside {$M+}, INSIDE the
// interface section — without it TRttiType.GetProperties returns 0 and every
// message here silently serialises as empty. Same rule as every other message
// unit in this repo.
{$IF DEFINED(FPC)}
  {$RTTI EXPLICIT PROPERTIES([vcPublished]) FIELDS([vcPublic]) METHODS([vcPublic])}
{$ENDIF}

uses
{$IF DEFINED(FPC)}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
  Nghttp2.Protobuf;

type
  // ── google.protobuf.Timestamp ─────────────────────────────────────────────
  // Seconds since the Unix epoch plus a nanosecond fraction. 681 of 7300
  // googleapis files reference it — the most-used well-known type by a wide
  // margin.
  [TGrpcMessage]
  TProtobufTimestamp = class
  private
    Fseconds: Int64;
    Fnanos:   Integer;
  published
    [TProtoMember(1)] property seconds: Int64   read Fseconds write Fseconds;
    [TProtoMember(2)] property nanos:   Integer read Fnanos   write Fnanos;
  end;

  // ── google.protobuf.Duration ──────────────────────────────────────────────
  // Same shape as Timestamp, different meaning: a signed span rather than a
  // point in time. Kept as its own class because the wire types are distinct
  // and a generator must not substitute one for the other.
  [TGrpcMessage]
  TProtobufDuration = class
  private
    Fseconds: Int64;
    Fnanos:   Integer;
  published
    [TProtoMember(1)] property seconds: Int64   read Fseconds write Fseconds;
    [TProtoMember(2)] property nanos:   Integer read Fnanos   write Fnanos;
  end;

  // ── google.protobuf.FieldMask ─────────────────────────────────────────────
  // A set of field paths, used by partial-update APIs. 590 files.
  [TGrpcMessage]
  TProtobufFieldMask = class
  private
    Fpaths: TArray<string>;
  published
    [TProtoMember(1)] property paths: TArray<string> read Fpaths write Fpaths;
  end;

  // ── google.protobuf.Empty ─────────────────────────────────────────────────
  // Genuinely fieldless, and the reason TProtobufRtti had to learn that a
  // zero-field message can be deliberate: [TGrpcMessage] is what says so.
  // Overwhelmingly used as an RPC return type.
  [TGrpcMessage]
  TProtobufEmpty = class
  end;

  // ── The wrapper types ─────────────────────────────────────────────────────
  // Each boxes one scalar, so that a message field can distinguish "absent"
  // from "present and zero" WITHOUT proto3 explicit presence. That is the
  // whole point of them, and it works here: a nil submessage reference is
  // absent, a non-nil one is present.
  //
  // Which makes these the closest thing to `optional` this library can express
  // today — worth knowing, because `optional` itself remains refused.

  [TGrpcMessage]
  TProtobufDoubleValue = class
  private
    Fvalue: Double;
  published
    [TProtoMember(1)] property value: Double read Fvalue write Fvalue;
  end;

  [TGrpcMessage]
  TProtobufFloatValue = class
  private
    Fvalue: Single;
  published
    [TProtoMember(1)] property value: Single read Fvalue write Fvalue;
  end;

  [TGrpcMessage]
  TProtobufInt64Value = class
  private
    Fvalue: Int64;
  published
    [TProtoMember(1)] property value: Int64 read Fvalue write Fvalue;
  end;

  [TGrpcMessage]
  TProtobufUInt64Value = class
  private
    Fvalue: UInt64;
  published
    [TProtoMember(1)] property value: UInt64 read Fvalue write Fvalue;
  end;

  [TGrpcMessage]
  TProtobufInt32Value = class
  private
    Fvalue: Integer;
  published
    [TProtoMember(1)] property value: Integer read Fvalue write Fvalue;
  end;

  // uint32/uint64 wrappers depend on FIX-PROTO-UINT32-1 (1.10.0). Before that
  // fix a Cardinal above MaxInt sign-extended onto the wire, so these two
  // classes would have been quietly wrong rather than merely absent.
  [TGrpcMessage]
  TProtobufUInt32Value = class
  private
    Fvalue: Cardinal;
  published
    [TProtoMember(1)] property value: Cardinal read Fvalue write Fvalue;
  end;

  [TGrpcMessage]
  TProtobufBoolValue = class
  private
    Fvalue: Boolean;
  published
    [TProtoMember(1)] property value: Boolean read Fvalue write Fvalue;
  end;

  [TGrpcMessage]
  TProtobufStringValue = class
  private
    Fvalue: string;
  published
    [TProtoMember(1)] property value: string read Fvalue write Fvalue;
  end;

  [TGrpcMessage]
  TProtobufBytesValue = class
  private
    Fvalue: TBytes;
  published
    [TProtoMember(1)] property value: TBytes read Fvalue write Fvalue;
  end;

  // ── google.protobuf.Struct / Value / ListValue / NullValue ────────────────
  //
  //  STRUCT-1, 2026-09-06. The header above says these are "deliberately NOT
  //  here" because they need oneof and a presence model. Both arrived —
  //  PRESENCE-1, ONEOF-1 and MAP-1 — and ProtoStructProbe then confirmed the
  //  runtime carries the shape with NO codec change. That note is now history,
  //  kept because the reasoning still explains why they were absent so long.
  //
  //  ── Why they are worth the four classes ──
  //
  //  The C1c corpus tally put 286 of 7301 googleapis files behind this family
  //  ALONE — files that stop being refused if only this is closed, measured
  //  rather than estimated. Acceptance goes 94% -> 98.7%. Nothing else on the
  //  list is within an order of magnitude: `Any` is 37 files, the whole of
  //  Group B (sint/fixed) is 6.
  //
  //  ── Why HAND-WRITTEN rather than generated ──
  //
  //  Not a shortcut — two things the generator genuinely cannot emit:
  //
  //    1. A oneof whose members are MESSAGES. Clearing one means FREEING it,
  //       and protogen refuses that case outright rather than emit a leak.
  //       Here the destructor and ClearKind are written by hand, so it is
  //       simply correct.
  //    2. MUTUAL RECURSION. Struct -> entry -> Value -> Struct is a cycle, and
  //       the emitter writes classes in declaration order with no forward
  //       declarations. The four lines below are exactly what it cannot
  //       produce.
  //
  //  Bundling therefore routes AROUND both gaps instead of closing them. Said
  //  plainly so nobody reads this as evidence the generator grew those
  //  abilities — a .proto that declares its own recursive oneof is still
  //  refused, and rightly.
  //
  //  ── Wire format ──
  //
  //  From google/protobuf/struct.proto, and it is the contract:
  //    Struct.fields    = 1, map<string, Value>  (= repeated entry, key 1,
  //                                               value 2 — MAP-1's shape)
  //    Value.kind       = oneof over tags 1..6
  //    ListValue.values = 1, repeated Value
  //
  //  ── Ownership ──
  //
  //  Every message-typed member here is OWNED and freed by its holder, the
  //  same contract PROTOGEN-DTOR pinned for generated classes. Hand a Value to
  //  SetFields and the map owns it; do not free it yourself.

  // google.protobuf.NullValue. A single-member enum whose only value is 0 —
  // that is the entire type. It is an ENUM, not a message, which the generator
  // has to be told separately (WellKnownIsEnum in Protogen.Ast): treated as a
  // message it would be emitted into a destructor and freed.
  TProtobufNullValue = (NULL_VALUE);

  TProtobufStruct    = class;
  TProtobufValue     = class;
  TProtobufListValue = class;

  { Which member of Value.kind is set. Named exactly as protogen names a
    generated oneof discriminator — CaseEnumName / CaseValueName in
    Protogen.Emitter — so hand-written and generated oneofs read identically.
    None is first, so a fresh Value reports "nothing set" with no constructor. }
  TProtobufValueKindCase = (
    ProtobufValueKindCaseNone,
    ProtobufValueKindCaseNull_value,
    ProtobufValueKindCaseNumber_value,
    ProtobufValueKindCaseString_value,
    ProtobufValueKindCaseBool_value,
    ProtobufValueKindCaseStruct_value,
    ProtobufValueKindCaseList_value);

  { The synthesised map entry for Struct.fields. A proto3 map IS a repeated
    entry message with key = 1 and value = 2 — the same thing MAP-1 makes the
    parser build — so this is the hand-written twin of generated map code. }
  [TGrpcMessage]
  TProtobufStructFieldsEntry = class
  private
    Fkey:   string;
    Fvalue: TProtobufValue;
  public
    destructor Destroy; override;
  published
    [TProtoMember(1)] property key:   string         read Fkey   write Fkey;
    [TProtoMember(2)] property value: TProtobufValue read Fvalue write Fvalue;
  end;

  [TGrpcMessage]
  TProtobufStruct = class
  private
    Ffields: TArray<TProtobufStructFieldsEntry>;
  public
    destructor Destroy; override;

    { The same five accessors protogen emits for a map field, with the same
      names, over the same public entry array. Lookup is a linear scan, stated
      rather than hidden: proto maps are typically small. }
    function  FieldsCount: Integer;
    function  HasFields(const AKey: string): Boolean;
    function  GetFields(const AKey: string): TProtobufValue;
    { Takes ownership of AValue. Replacing an existing key FREES what was
      there — without that an ordinary overwrite leaks one Value per call —
      and re-setting a key to its own current value is a no-op rather than a
      free-then-dangle. }
    procedure SetFields(const AKey: string; const AValue: TProtobufValue);
    procedure ClearFields;
  published
    [TProtoMember(1)] property fields: TArray<TProtobufStructFieldsEntry>
      read Ffields write Ffields;
  end;

  { google.protobuf.Value — a dynamically typed value: null, number, string,
    bool, Struct or ListValue.

    Two presence mechanisms in ONE class, which is the shape ProtoStructProbe
    existed to validate:
      null/number/string/bool   a [TProtoHas] Boolean, because a scalar at its
                                default is otherwise indistinguishable from
                                absent
      struct_value/list_value   NIL, because a submessage already carries
                                presence — AttachHasBits REFUSES a has-bit
                                here, on exactly those grounds

    Setting any member clears the other five, which for the two message
    members means freeing them. }
  [TGrpcMessage]
  TProtobufValue = class
  private
    Fnull_value:       TProtobufNullValue;
    Fhas_null_value:   Boolean;
    Fnumber_value:     Double;
    Fhas_number_value: Boolean;
    Fstring_value:     string;
    Fhas_string_value: Boolean;
    Fbool_value:       Boolean;
    Fhas_bool_value:   Boolean;
    Fstruct_value:     TProtobufStruct;
    Flist_value:       TProtobufListValue;
    procedure Setnull_value  (const AValue: TProtobufNullValue);
    procedure Setnumber_value(const AValue: Double);
    procedure Setstring_value(const AValue: string);
    procedure Setbool_value  (const AValue: Boolean);
    procedure Setstruct_value(const AValue: TProtobufStruct);
    procedure Setlist_value  (const AValue: TProtobufListValue);
    function  GetKindCase: TProtobufValueKindCase;
  public
    destructor Destroy; override;
    procedure ClearKind;
    property KindCase: TProtobufValueKindCase read GetKindCase;
  published
    [TProtoMember(1)] property null_value: TProtobufNullValue
      read Fnull_value write Setnull_value;
    [TProtoHas(1)]    property has_null_value: Boolean read Fhas_null_value;

    [TProtoMember(2)] property number_value: Double
      read Fnumber_value write Setnumber_value;
    [TProtoHas(2)]    property has_number_value: Boolean read Fhas_number_value;

    [TProtoMember(3)] property string_value: string
      read Fstring_value write Setstring_value;
    [TProtoHas(3)]    property has_string_value: Boolean read Fhas_string_value;

    [TProtoMember(4)] property bool_value: Boolean
      read Fbool_value write Setbool_value;
    [TProtoHas(4)]    property has_bool_value: Boolean read Fhas_bool_value;

    // No [TProtoHas] on these two, deliberately — nil IS the answer.
    [TProtoMember(5)] property struct_value: TProtobufStruct
      read Fstruct_value write Setstruct_value;
    [TProtoMember(6)] property list_value: TProtobufListValue
      read Flist_value write Setlist_value;
  end;

  [TGrpcMessage]
  TProtobufListValue = class
  private
    Fvalues: TArray<TProtobufValue>;
  public
    destructor Destroy; override;
    { Appends and takes ownership. Provided because the alternative — build a
      TArray and assign the property — silently replaces the array WITHOUT
      freeing what was in it. }
    procedure Add(const AValue: TProtobufValue);
  published
    [TProtoMember(1)] property values: TArray<TProtobufValue>
      read Fvalues write Fvalues;
  end;

implementation

{ ── TProtobufStructFieldsEntry ────────────────────────────────────────────── }

destructor TProtobufStructFieldsEntry.Destroy;
begin
  Fvalue.Free;
  inherited;
end;

{ ── TProtobufStruct ───────────────────────────────────────────────────────── }

destructor TProtobufStruct.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(Ffields) do
    Ffields[I].Free;
  inherited;
end;

function TProtobufStruct.FieldsCount: Integer;
begin
  Result := Length(Ffields);
end;

function TProtobufStruct.HasFields(const AKey: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(Ffields) do
    if Ffields[I].key = AKey then Exit(True);
  Result := False;
end;

{ An absent key yields nil — proto3 says a missing map entry means the value
  type's default, and for a message that is nil. HasFields is there for callers
  who must tell absent from present. }
function TProtobufStruct.GetFields(const AKey: string): TProtobufValue;
var
  I: Integer;
begin
  for I := 0 to High(Ffields) do
    if Ffields[I].key = AKey then Exit(Ffields[I].value);
  Result := nil;
end;

procedure TProtobufStruct.SetFields(const AKey: string;
  const AValue: TProtobufValue);
var
  I: Integer;
  LEntry: TProtobufStructFieldsEntry;
begin
  for I := 0 to High(Ffields) do
    if Ffields[I].key = AKey then
    begin
      { Guarded: SetFields(k, GetFields(k)) must not free the instance and then
        store the pointer it just freed. }
      if Ffields[I].value <> AValue then
        Ffields[I].value.Free;
      Ffields[I].value := AValue;
      Exit;
    end;
  LEntry := TProtobufStructFieldsEntry.Create;
  LEntry.key   := AKey;
  LEntry.value := AValue;
  SetLength(Ffields, Length(Ffields) + 1);
  Ffields[High(Ffields)] := LEntry;
end;

procedure TProtobufStruct.ClearFields;
var
  I: Integer;
begin
  for I := 0 to High(Ffields) do
    Ffields[I].Free;
  SetLength(Ffields, 0);
end;

{ ── TProtobufValue ────────────────────────────────────────────────────────── }

destructor TProtobufValue.Destroy;
begin
  Fstruct_value.Free;
  Flist_value.Free;
  inherited;
end;

{ The two message members are FREED, not merely nilled: this class owns them. }
procedure TProtobufValue.ClearKind;
begin
  Fhas_null_value   := False;
  Fhas_number_value := False;
  Fhas_string_value := False;
  Fhas_bool_value   := False;
  FreeAndNil(Fstruct_value);
  FreeAndNil(Flist_value);
end;

procedure TProtobufValue.Setnull_value(const AValue: TProtobufNullValue);
begin
  ClearKind;
  Fnull_value     := AValue;
  Fhas_null_value := True;
end;

procedure TProtobufValue.Setnumber_value(const AValue: Double);
begin
  ClearKind;
  Fnumber_value     := AValue;
  Fhas_number_value := True;
end;

procedure TProtobufValue.Setstring_value(const AValue: string);
begin
  ClearKind;
  Fstring_value     := AValue;
  Fhas_string_value := True;
end;

procedure TProtobufValue.Setbool_value(const AValue: Boolean);
begin
  ClearKind;
  Fbool_value     := AValue;
  Fhas_bool_value := True;
end;

procedure TProtobufValue.Setstruct_value(const AValue: TProtobufStruct);
begin
  if Fstruct_value = AValue then Exit;
  ClearKind;
  Fstruct_value := AValue;
end;

procedure TProtobufValue.Setlist_value(const AValue: TProtobufListValue);
begin
  if Flist_value = AValue then Exit;
  ClearKind;
  Flist_value := AValue;
end;

{ Reads the has-bits for the scalar members and nil-ness for the message ones —
  the two presence mechanisms this class mixes, resolved in one place so a
  caller never has to know which member uses which. }
function TProtobufValue.GetKindCase: TProtobufValueKindCase;
begin
  if      Fhas_null_value      then Result := ProtobufValueKindCaseNull_value
  else if Fhas_number_value    then Result := ProtobufValueKindCaseNumber_value
  else if Fhas_string_value    then Result := ProtobufValueKindCaseString_value
  else if Fhas_bool_value      then Result := ProtobufValueKindCaseBool_value
  else if Fstruct_value <> nil then Result := ProtobufValueKindCaseStruct_value
  else if Flist_value   <> nil then Result := ProtobufValueKindCaseList_value
  else Result := ProtobufValueKindCaseNone;
end;

{ ── TProtobufListValue ────────────────────────────────────────────────────── }

destructor TProtobufListValue.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(Fvalues) do
    Fvalues[I].Free;
  inherited;
end;

procedure TProtobufListValue.Add(const AValue: TProtobufValue);
begin
  SetLength(Fvalues, Length(Fvalues) + 1);
  Fvalues[High(Fvalues)] := AValue;
end;

end.
