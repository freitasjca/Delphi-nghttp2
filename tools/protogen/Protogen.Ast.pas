unit Protogen.Ast;

// ============================================================================
//  Protogen.Ast — the parsed shape of a .proto file.
//
//  C1 of plans/horse-grpc-codegen.md. Deliberately dumb: these are records of
//  what was written, not a semantic model. Name resolution, reserved-word
//  renaming and the decision of which Pascal type to emit all belong to C2,
//  because they are questions about the OUTPUT, and keeping them out of here
//  is what lets the parser be tested against the input alone.
//
//  Ownership: TProtoFileNode owns everything reachable from it. Free the file
//  node and the whole tree goes. Nothing here is reference-counted, so do not
//  hold a child past its parent.
// ============================================================================

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, Generics.Collections;
{$ELSE}
  System.SysUtils, System.Classes, System.Generics.Collections;
{$IFEND}

type
  { The proto3 scalar set, complete — including the ones the RTTI serializer
    cannot express. The parser must RECOGNISE every scalar in order to reject
    the unsupported ones by name; a parser that only knew the supported subset
    would report "unknown type sint32", which names the wrong problem. }
  TProtoScalar = (
    psNone,        // not a scalar — TypeName refers to a message or enum
    psDouble, psFloat,
    psInt32, psInt64, psUInt32, psUInt64,
    psSInt32, psSInt64,                       // zigzag — unsupported downstream
    psFixed32, psFixed64, psSFixed32, psSFixed64,  // fixed  — unsupported
    psBool, psString, psBytes
  );

  TProtoLabel = (plNone, plRepeated, plOptional);

  TProtoMessageNode = class;   // forward — a field names its owner

  TProtoFieldNode = class
  public
    Name:       string;
    TypeName:   string;        // exactly as written, e.g. 'int32' or 'Address'
    Scalar:     TProtoScalar;  // psNone when TypeName is a message/enum ref
    Number:     Integer;
    FieldLabel: TProtoLabel;
    Line:       Integer;
    Column:     Integer;

    { ONEOF-1. The name of the oneof group this field belongs to, or '' when
      it is an ordinary field.

      Members are hoisted to the message's normal field list rather than kept
      in a nested structure, because that is exactly what they are on the
      WIRE: a oneof has no framing of its own, and each member is an ordinary
      tagged field. The "at most one is set" rule is a language-binding
      constraint, not a wire one — which is why supporting oneof needs no
      codec change at all, only generated setters that clear their siblings. }
    OneofName:  string;

    { MAP-1. True when this field came from `map<K,V>`.

      By the time it reaches here it IS an ordinary `repeated <Entry>` field —
      that is precisely what a proto3 map is on the wire, so the parser
      synthesises the entry message and rewrites the field, and nothing
      downstream needs a map concept to encode it.

      The flag exists only so the EMITTER knows to add dictionary accessors on
      top. Key and value types are not stored: the entry message has them, as
      field 1 and field 2, and reading them from there means the two can never
      disagree. }
    IsMap:      Boolean;

    { The message this field was DECLARED in.

      Nested messages are hoisted to file scope during parsing, which is what
      makes the emitter's job flat — but it erases the containment, and proto
      resolves a bare type name innermost-outward, so the containment is
      exactly what decides which type a name means. google/cloud/gkehub has
      two messages each nesting a different ControlPlaneManagement and each
      referring to its own by the bare name.

      Structure, not name resolution: this records what was written, which is
      all this unit is allowed to do. The resolving happens in
      Protogen.FileSet. }
    Owner: TProtoMessageNode;

    function IsRepeated: Boolean;
    function InOneof: Boolean;
  end;

  TProtoEnumValueNode = class
  public
    Name:   string;
    Number: Integer;
    Line:   Integer;
  end;

  // NESTING. Declarations nested inside a message are HOISTED to file scope by
  // the parser and carry the proto path that located them. An enum declared
  // inside message Outer arrives as:
  //
  //     Name          = 'Inner'
  //     QualifiedName = 'Outer.Inner'
  //
  // Both are kept because they answer different questions. QualifiedName is
  // the identity — it is what a field's type reference resolves against, and
  // it is unique within a file where Name is not. Name is what a reader
  // called it.
  //
  // What the Pascal type is finally NAMED is deliberately not decided here:
  // flattening 'Outer.Inner' to TOuterInner or TOuter_Inner is a question
  // about the OUTPUT, and belongs to the emitter along with reserved-word
  // renaming.
  //
  // Written with // because the natural illustration here is a proto snippet
  // containing braces, and a '}' inside a { } comment closes it early. That
  // has now broken this build three times in one session.
  TProtoEnumNode = class
  private
    FValues: TObjectList<TProtoEnumValueNode>;
  public
    Name:          string;
    QualifiedName: string;
    Line: Integer;
    constructor Create;
    destructor Destroy; override;
    property Values: TObjectList<TProtoEnumValueNode> read FValues;
  end;

  { Also hoisted when nested — see the note on TProtoEnumNode. }
  TProtoMessageNode = class
  private
    FFields: TObjectList<TProtoFieldNode>;
  public
    Name:          string;
    QualifiedName: string;
    Line: Integer;
    constructor Create;
    destructor Destroy; override;
    property Fields: TObjectList<TProtoFieldNode> read FFields;
    { Nil when no field carries this number. Used by the parser to reject
      duplicates, which protoc treats as an error and which would otherwise
      produce two Pascal properties with the same [TProtoMember]. }
    function FindByNumber(ANumber: Integer): TProtoFieldNode;
  end;

  TProtoRpcNode = class
  public
    Name:           string;
    RequestType:    string;
    ResponseType:   string;
    RequestStream:  Boolean;   // `stream` on the request  → client-streaming
    ResponseStream: Boolean;   // `stream` on the response → server-streaming
    Line:           Integer;
  end;

  TProtoServiceNode = class
  private
    FRpcs: TObjectList<TProtoRpcNode>;
  public
    Name: string;
    Line: Integer;
    constructor Create;
    destructor Destroy; override;
    property Rpcs: TObjectList<TProtoRpcNode> read FRpcs;
  end;

  TProtoFileNode = class
  private
    FMessages: TObjectList<TProtoMessageNode>;
    FEnums:    TObjectList<TProtoEnumNode>;
    FServices: TObjectList<TProtoServiceNode>;
    FImports:  TStringList;
    FPublicImports: TStringList;
  public
    Syntax:      string;   // always 'proto3' — the parser rejects anything else
    PackageName: string;
    constructor Create;
    destructor Destroy; override;
    property Messages: TObjectList<TProtoMessageNode> read FMessages;
    property Enums:    TObjectList<TProtoEnumNode>    read FEnums;
    property Services: TObjectList<TProtoServiceNode> read FServices;
    property Imports:  TStringList                    read FImports;
    // IMPORT-1. The subset of Imports declared `import public`, which a file
    // RE-EXPORTS: anyone importing this file may name their types too. Kept
    // separate rather than flagged in-place so Imports stays the plain list
    // every existing caller reads.
    property PublicImports: TStringList               read FPublicImports;
    function FindMessage(const AName: string): TProtoMessageNode;
    function FindEnum(const AName: string): TProtoEnumNode;
  end;

{ Maps a proto3 scalar keyword to its enum. psNone for anything else, which is
  how the parser tells a scalar from a message reference. }
function ScalarFromKeyword(const AWord: string): TProtoScalar;

{ The keyword for a scalar — used in diagnostics so a rejection quotes the
  user's own spelling back at them. }
function ScalarName(AScalar: TProtoScalar): string;

{ Maps a protobuf well-known type to the Pascal class that implements it in
  Nghttp2.Protobuf.WellKnown, or '' when the type is not bundled.

  One list, two consumers, and that is the point: the PARSER asks "may I accept
  a field of this type" and the EMITTER will ask "what do I call it". Splitting
  them would let the two drift, and the failure mode is a generator that
  accepts a schema it cannot emit.

  Not bundled, and each for a reason rather than an oversight: Struct, Value
  and ListValue are built on `oneof`; Any needs dynamic type resolution from a
  type URL; Api, Type and DescriptorProto are protobuf's own reflection
  machinery. All stay refused until presence exists. }
function WellKnownPascalClass(const AProtoName: string): string;
function WellKnownIsEnum(const AProtoName: string): Boolean;

{ Is AName (lowercased by the caller) a Pascal reserved word?

  Lives here rather than in the emitter because it has two consumers that must
  not drift: the emitter renames an enum VALUE that collides with one, and
  Protogen.FileSet renames a unit-name SEGMENT that does — 'type.proto' is a
  real file, and `Demo.Type` is not a legal unit name. }
function IsDelphiReservedWord(const AName: string): Boolean;

implementation

// ── TProtoFieldNode ─────────────────────────────────────────────────────────

function TProtoFieldNode.IsRepeated: Boolean;
begin
  Result := FieldLabel = plRepeated;
end;

function TProtoFieldNode.InOneof: Boolean;
begin
  Result := OneofName <> '';
end;

// ── TProtoEnumNode ──────────────────────────────────────────────────────────

constructor TProtoEnumNode.Create;
begin
  inherited Create;
  FValues := TObjectList<TProtoEnumValueNode>.Create(True);
end;

destructor TProtoEnumNode.Destroy;
begin
  FValues.Free;
  inherited Destroy;
end;

// ── TProtoMessageNode ───────────────────────────────────────────────────────

constructor TProtoMessageNode.Create;
begin
  inherited Create;
  FFields := TObjectList<TProtoFieldNode>.Create(True);
end;

destructor TProtoMessageNode.Destroy;
begin
  FFields.Free;
  inherited Destroy;
end;

function TProtoMessageNode.FindByNumber(ANumber: Integer): TProtoFieldNode;
var
  I: Integer;
begin
  for I := 0 to FFields.Count - 1 do
    if FFields[I].Number = ANumber then
      Exit(FFields[I]);
  Result := nil;
end;

// ── TProtoServiceNode ───────────────────────────────────────────────────────

constructor TProtoServiceNode.Create;
begin
  inherited Create;
  FRpcs := TObjectList<TProtoRpcNode>.Create(True);
end;

destructor TProtoServiceNode.Destroy;
begin
  FRpcs.Free;
  inherited Destroy;
end;

// ── TProtoFileNode ──────────────────────────────────────────────────────────

constructor TProtoFileNode.Create;
begin
  inherited Create;
  FMessages := TObjectList<TProtoMessageNode>.Create(True);
  FEnums    := TObjectList<TProtoEnumNode>.Create(True);
  FServices := TObjectList<TProtoServiceNode>.Create(True);
  FImports  := TStringList.Create;
  FPublicImports := TStringList.Create;
end;

destructor TProtoFileNode.Destroy;
begin
  FPublicImports.Free;
  FImports.Free;
  FServices.Free;
  FEnums.Free;
  FMessages.Free;
  inherited Destroy;
end;

{ Qualified name first, then simple. Once nested declarations are hoisted, two
  messages can legitimately share a simple Name ('Outer.Status' and
  'Other.Status'), so a simple-name lookup is ambiguous by construction —
  matching QualifiedName first means an exact path always wins over a guess. }
function TProtoFileNode.FindMessage(const AName: string): TProtoMessageNode;
var
  I: Integer;
begin
  for I := 0 to FMessages.Count - 1 do
    if SameText(FMessages[I].QualifiedName, AName) then
      Exit(FMessages[I]);
  { A PARTIAL path, which proto scoping resolves by walking outward:
    `ResourceInfo.ResourceType` written inside a message whose sibling declares
    ResourceInfo means `Outer.ResourceInfo.ResourceType`. Matched on a dot
    boundary so 'Info.Type' cannot match 'XInfo.Type'.

    Third in order, after both exact tests, so an exact name always wins. }
  for I := 0 to FMessages.Count - 1 do
    if (Pos('.', AName) > 0)
      and SameText(Copy(FMessages[I].QualifiedName,
                        Length(FMessages[I].QualifiedName) - Length(AName), MaxInt),
                   '.' + AName) then
      Exit(FMessages[I]);
  for I := 0 to FMessages.Count - 1 do
    if SameText(FMessages[I].Name, AName) then
      Exit(FMessages[I]);
  Result := nil;
end;

function TProtoFileNode.FindEnum(const AName: string): TProtoEnumNode;
var
  I: Integer;
begin
  for I := 0 to FEnums.Count - 1 do
    if SameText(FEnums[I].QualifiedName, AName) then
      Exit(FEnums[I]);
  { A PARTIAL path, which proto scoping resolves by walking outward:
    `ResourceInfo.ResourceType` written inside a message whose sibling declares
    ResourceInfo means `Outer.ResourceInfo.ResourceType`. Matched on a dot
    boundary so 'Info.Type' cannot match 'XInfo.Type'.

    Third in order, after both exact tests, so an exact name always wins. }
  for I := 0 to FEnums.Count - 1 do
    if (Pos('.', AName) > 0)
      and SameText(Copy(FEnums[I].QualifiedName,
                        Length(FEnums[I].QualifiedName) - Length(AName), MaxInt),
                   '.' + AName) then
      Exit(FEnums[I]);
  for I := 0 to FEnums.Count - 1 do
    if SameText(FEnums[I].Name, AName) then
      Exit(FEnums[I]);
  Result := nil;
end;

// ── Scalar keyword mapping ──────────────────────────────────────────────────

function ScalarFromKeyword(const AWord: string): TProtoScalar;
begin
  { Case-SENSITIVE on purpose: proto3 scalars are lowercase keywords, and
    `Int32` is a legal message name. Folding case here would silently turn a
    message reference into a scalar. }
  if      AWord = 'double'   then Result := psDouble
  else if AWord = 'float'    then Result := psFloat
  else if AWord = 'int32'    then Result := psInt32
  else if AWord = 'int64'    then Result := psInt64
  else if AWord = 'uint32'   then Result := psUInt32
  else if AWord = 'uint64'   then Result := psUInt64
  else if AWord = 'sint32'   then Result := psSInt32
  else if AWord = 'sint64'   then Result := psSInt64
  else if AWord = 'fixed32'  then Result := psFixed32
  else if AWord = 'fixed64'  then Result := psFixed64
  else if AWord = 'sfixed32' then Result := psSFixed32
  else if AWord = 'sfixed64' then Result := psSFixed64
  else if AWord = 'bool'     then Result := psBool
  else if AWord = 'string'   then Result := psString
  else if AWord = 'bytes'    then Result := psBytes
  else Result := psNone;
end;

function WellKnownPascalClass(const AProtoName: string): string;
var
  LName: string;
begin
  // Accept both the plain and leading-dot spellings — '.google.protobuf.X' is
  // how a schema escapes package-relative lookup, and it means the same type.
  LName := AProtoName;
  if (Length(LName) > 0) and (LName[1] = '.') then
    Delete(LName, 1, 1);

  if      LName = 'google.protobuf.Timestamp'   then Result := 'TProtobufTimestamp'
  else if LName = 'google.protobuf.Duration'    then Result := 'TProtobufDuration'
  else if LName = 'google.protobuf.FieldMask'   then Result := 'TProtobufFieldMask'
  else if LName = 'google.protobuf.Empty'       then Result := 'TProtobufEmpty'
  else if LName = 'google.protobuf.DoubleValue' then Result := 'TProtobufDoubleValue'
  else if LName = 'google.protobuf.FloatValue'  then Result := 'TProtobufFloatValue'
  else if LName = 'google.protobuf.Int64Value'  then Result := 'TProtobufInt64Value'
  else if LName = 'google.protobuf.UInt64Value' then Result := 'TProtobufUInt64Value'
  else if LName = 'google.protobuf.Int32Value'  then Result := 'TProtobufInt32Value'
  else if LName = 'google.protobuf.UInt32Value' then Result := 'TProtobufUInt32Value'
  else if LName = 'google.protobuf.BoolValue'   then Result := 'TProtobufBoolValue'
  else if LName = 'google.protobuf.StringValue' then Result := 'TProtobufStringValue'
  else if LName = 'google.protobuf.BytesValue'  then Result := 'TProtobufBytesValue'
  // STRUCT-1. Bundled once PRESENCE-1, ONEOF-1 and MAP-1 supplied what they
  // needed. NullValue is an ENUM, not a class - see WellKnownIsEnum, which
  // callers must consult before treating one of these as an owned instance.
  else if LName = 'google.protobuf.Struct'      then Result := 'TProtobufStruct'
  else if LName = 'google.protobuf.Value'       then Result := 'TProtobufValue'
  else if LName = 'google.protobuf.ListValue'   then Result := 'TProtobufListValue'
  else if LName = 'google.protobuf.NullValue'   then Result := 'TProtobufNullValue'
  // ANY-1. The CLASS is two fields and always could have been bundled; what
  // was missing was a way to put anything in it or get anything out. That is
  // Nghttp2.Protobuf.Any - TProtoAnyRegistry plus Pack/UnpackTo/UnpackNew -
  // which a generated unit does not reference, so nothing changes here beyond
  // the mapping.
  else if LName = 'google.protobuf.Any'         then Result := 'TProtobufAny'
  else Result := '';
end;

{ Is this bundled well-known type an ENUM rather than a message class?

  Only google.protobuf.NullValue is, and the distinction is load-bearing: an
  emitter that treats it as a message puts it in a generated destructor and
  emits `.Free` on an enum. Every other entry in the table above is a class. }
function WellKnownIsEnum(const AProtoName: string): Boolean;
var
  LName: string;
begin
  LName := AProtoName;
  if (Length(LName) > 0) and (LName[1] = '.') then
    Delete(LName, 1, 1);
  Result := LName = 'google.protobuf.NullValue';
end;

function ScalarName(AScalar: TProtoScalar): string;
begin
  case AScalar of
    psDouble:   Result := 'double';
    psFloat:    Result := 'float';
    psInt32:    Result := 'int32';
    psInt64:    Result := 'int64';
    psUInt32:   Result := 'uint32';
    psUInt64:   Result := 'uint64';
    psSInt32:   Result := 'sint32';
    psSInt64:   Result := 'sint64';
    psFixed32:  Result := 'fixed32';
    psFixed64:  Result := 'fixed64';
    psSFixed32: Result := 'sfixed32';
    psSFixed64: Result := 'sfixed64';
    psBool:     Result := 'bool';
    psString:   Result := 'string';
    psBytes:    Result := 'bytes';
  else
    Result := '<not a scalar>';
  end;
end;

function IsDelphiReservedWord(const AName: string): Boolean;
begin
  Result :=
    (AName = 'and')          or (AName = 'array')        or (AName = 'as')          or
    (AName = 'asm')          or (AName = 'begin')         or (AName = 'case')        or
    (AName = 'class')        or (AName = 'const')         or (AName = 'constructor') or
    (AName = 'destructor')   or (AName = 'dispinterface') or (AName = 'div')         or
    (AName = 'do')           or (AName = 'downto')        or (AName = 'else')        or
    (AName = 'end')          or (AName = 'except')        or (AName = 'exports')     or
    (AName = 'file')         or (AName = 'finalization')  or (AName = 'finally')     or
    (AName = 'for')          or (AName = 'function')      or (AName = 'goto')        or
    (AName = 'if')           or (AName = 'implementation')or (AName = 'in')          or
    (AName = 'inherited')    or (AName = 'initialization') or (AName = 'inline')     or
    (AName = 'interface')    or (AName = 'is')            or (AName = 'label')       or
    (AName = 'library')      or (AName = 'message')       or (AName = 'mod')         or
    (AName = 'nil')          or (AName = 'not')           or (AName = 'object')      or
    (AName = 'of')           or (AName = 'on')            or (AName = 'or')          or
    (AName = 'out')          or (AName = 'packed')        or (AName = 'procedure')   or
    (AName = 'program')      or (AName = 'property')      or (AName = 'raise')       or
    (AName = 'record')       or (AName = 'repeat')        or (AName = 'resourcestring') or
    (AName = 'set')          or (AName = 'shl')           or (AName = 'shr')         or
    (AName = 'string')       or (AName = 'then')          or (AName = 'threadvar')   or
    (AName = 'to')           or (AName = 'try')           or (AName = 'type')        or
    (AName = 'unit')         or (AName = 'until')         or (AName = 'uses')        or
    (AName = 'var')          or (AName = 'while')         or (AName = 'with')        or
    (AName = 'xor');
end;

end.
