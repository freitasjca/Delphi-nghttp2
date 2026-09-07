unit Protogen.Parser;

// ============================================================================
//  Protogen.Parser — recursive-descent parser for the proto3 subset.
//
//  C1 of plans/horse-grpc-codegen.md.
//
//  ── The refusals are the feature ──
//
//  This parser recognises MORE of proto3 than the generator can emit, and that
//  is deliberate. Section 6.1 of the plan settled which features are out and
//  why, and the whole point of the decision was that silently mis-encoding a
//  field is far worse than refusing it. A parser that simply did not know the
//  word `sint32` would report "unknown type", naming the wrong problem and
//  sending the user looking for a typo.
//
//  So every rejection here:
//    - names the construct in the user's own spelling
//    - gives the position
//    - says WHY it cannot be supported, distinguishing a structural limit from
//      a not-yet
//
//  The three groups, from plan 6.1:
//    A  uint32/uint64  — SUPPORTED since FIX-PROTO-UINT32-1 (Delphi-nghttp2
//                        1.10.0). Do not re-add these to the refusals.
//    B  sint*/fixed*   — structural. The wire layer implements them, but
//                        TProtoMemberAttribute carries only a tag, so a
//                        property cannot request a wire form.
//    C  map/oneof/optional — no representation at all.
//
//  ── What this deliberately does NOT do ──
//
//  No name resolution, no reserved-word renaming, no Pascal type mapping.
//  Those are questions about the OUTPUT and belong to C2. Keeping them out is
//  what lets this be tested against .proto input alone.
// ============================================================================

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$IFEND}
  Protogen.Ast,
  Protogen.Lexer;

type
  EProtoParseError = class(Exception)
  public
    Line:      Integer;
    Column:    Integer;
    Construct: string;   // the rejected/offending construct, as written
    constructor CreateAt(ALine, AColumn: Integer;
      const AConstruct, AMsg: string);
  end;

  TProtoParser = class
  private
    FLexer:    TProtoLexer;
    FFileName: string;
    FFile:     TProtoFileNode;

    function  Tok: TProtoToken;
    procedure NextTok;
    function  IsSymbol(const AValue: string): Boolean;
    function  IsIdent(const AValue: string): Boolean;
    procedure ExpectSymbol(const AValue: string);
    procedure ExpectIdentValue(const AValue: string);
    function  ExpectIdent: string;
    function  ExpectQualifiedIdent: string;
    function  ExpectNumber: Integer;

    { Raises. AReason must explain the limitation, not merely restate it. }
    procedure Refuse(const AConstruct, AReason: string);
    procedure RefuseAt(ALine, ACol: Integer;
      const AConstruct, AReason: string);
    procedure Fail(const AMsg: string);

    procedure ParseSyntax;
    procedure ParsePackage;
    procedure ParseImport;
    procedure SkipOptionStatement;
    procedure SkipFieldOptions;
    procedure SkipReserved;
    procedure ParseTopLevel;
    { AParentQualified is '' at file scope, or the enclosing message's
      QualifiedName. Nested declarations are HOISTED to the file's lists with
      the full path recorded — Pascal has no nested class scope to mirror them
      into, so hierarchy is preserved as a NAME rather than as structure. }
    procedure ParseMessage(const AParentQualified: string = '');
    procedure ParseMessageBody(AMsg: TProtoMessageNode);
    { AOneofName is TRAILING and OPTIONAL on purpose: the three existing call
      sites are positional and compile untouched. That is the shape the C4
      arity defect taught — a parameter inserted mid-list silently shifts
      every argument after it. }
    procedure ParseField(AMsg: TProtoMessageNode; AFieldLabel: TProtoLabel;
      ALabelLine, ALabelCol: Integer; const AOneofName: string = '');
    procedure ParseOneof(AMsg: TProtoMessageNode);
    procedure ParseMapField(AMsg: TProtoMessageNode);
    procedure ParseEnum(const AParentQualified: string = '');
    procedure ParseService;
    procedure ParseRpc(AService: TProtoServiceNode);
    procedure CheckScalarSupported(AScalar: TProtoScalar;
      const AFieldName: string; ALine, ACol: Integer);
    procedure CheckTypeNameSupported(const ATypeName: string;
      const AFieldName: string; ALine, ACol: Integer);
  public
    constructor Create(const AText, AFileName: string);
    destructor Destroy; override;
    { Parses the whole file. The caller OWNS the returned node and must free
      it. Raises EProtoParseError or EProtoLexError on anything it will not
      accept — there is no partial-success mode, because a half-parsed .proto
      would generate a half-correct unit. }
    function Parse: TProtoFileNode;
  end;

{ Convenience: parse a file from disk. Caller owns the result. }
function ParseProtoFile(const AFileName: string): TProtoFileNode;

implementation

// ── EProtoParseError ────────────────────────────────────────────────────────

constructor EProtoParseError.CreateAt(ALine, AColumn: Integer;
  const AConstruct, AMsg: string);
begin
  inherited CreateFmt('(%d:%d) %s', [ALine, AColumn, AMsg]);
  Line      := ALine;
  Column    := AColumn;
  Construct := AConstruct;
end;

// ── TProtoParser ────────────────────────────────────────────────────────────

constructor TProtoParser.Create(const AText, AFileName: string);
begin
  inherited Create;
  FLexer    := TProtoLexer.Create(AText);
  FFileName := AFileName;
end;

destructor TProtoParser.Destroy;
begin
  FLexer.Free;
  inherited Destroy;
end;

function TProtoParser.Tok: TProtoToken;
begin
  Result := FLexer.Current;
end;

procedure TProtoParser.NextTok;
begin
  FLexer.Next;
end;

function TProtoParser.IsSymbol(const AValue: string): Boolean;
begin
  Result := (Tok.Kind = ptSymbol) and (Tok.Value = AValue);
end;

function TProtoParser.IsIdent(const AValue: string): Boolean;
begin
  Result := (Tok.Kind = ptIdent) and (Tok.Value = AValue);
end;

procedure TProtoParser.Fail(const AMsg: string);
begin
  raise EProtoParseError.CreateAt(Tok.Line, Tok.Column, Tok.Value, AMsg);
end;

procedure TProtoParser.Refuse(const AConstruct, AReason: string);
begin
  { BLOCKED-BY: invalid-proto3 }
  RefuseAt(Tok.Line, Tok.Column, AConstruct, AReason);
end;

procedure TProtoParser.RefuseAt(ALine, ACol: Integer;
  const AConstruct, AReason: string);
begin
  raise EProtoParseError.CreateAt(ALine, ACol, AConstruct,
    Format('%s is not supported. %s', [AConstruct, AReason]));
end;

procedure TProtoParser.ExpectSymbol(const AValue: string);
begin
  if not IsSymbol(AValue) then
    Fail(Format('expected %s but found %s',
      [QuotedStr(AValue), QuotedStr(Tok.Value)]));
  NextTok;
end;

procedure TProtoParser.ExpectIdentValue(const AValue: string);
begin
  if not IsIdent(AValue) then
    Fail(Format('expected %s but found %s',
      [QuotedStr(AValue), QuotedStr(Tok.Value)]));
  NextTok;
end;

function TProtoParser.ExpectIdent: string;
begin
  if Tok.Kind <> ptIdent then
    Fail(Format('expected an identifier but found %s', [QuotedStr(Tok.Value)]));
  Result := Tok.Value;
  NextTok;
end;

function TProtoParser.ExpectQualifiedIdent: string;
begin
  Result := ExpectIdent;
  // A qualified TYPE name may be WRAPPED across lines, which googleapis does
  // routinely because its enum paths are long:
  //
  //   google.ads.searchads360.v0.enums.SomeStatusEnum
  //       .SomeStatus status = 1;
  //
  // Whitespace terminates an identifier token, so the tail arrives as a
  // SEPARATE token. Left unstitched, the parser takes the tail as the field
  // NAME and then finds the real name where '=' should be — reporting
  // "expected '=' but found 'status'", which names the field and hides the
  // cause. 37 files failed exactly that way in a googleapis run.
  //
  // Both wrap positions are handled: a trailing dot on the head
  // ("Foo.<newline>Bar") and a leading dot on the tail ("Foo<newline>.Bar").
  while (Tok.Kind = ptIdent)
        and ( ((Length(Result) > 0) and (Result[Length(Result)] = '.'))
              or ((Length(Tok.Value) > 0) and (Tok.Value[1] = '.')) ) do
  begin
    Result := Result + Tok.Value;
    NextTok;
  end;
end;

function TProtoParser.ExpectNumber: Integer;
var
  LCode: Integer;
begin
  if Tok.Kind <> ptNumber then
    Fail(Format('expected a number but found %s', [QuotedStr(Tok.Value)]));
  Val(Tok.Value, Result, LCode);
  if LCode <> 0 then
    Fail(Format('%s is not a valid integer', [QuotedStr(Tok.Value)]));
  NextTok;
end;

// ── Feature gates ───────────────────────────────────────────────────────────

procedure TProtoParser.CheckScalarSupported(AScalar: TProtoScalar;
  const AFieldName: string; ALine, ACol: Integer);
begin
  case AScalar of
    psSInt32, psSInt64:
      { BLOCKED-BY: no-wire-form-selector }
      RefuseAt(ALine, ACol, ScalarName(AScalar),
        Format('Field %s uses zigzag encoding, which cannot be requested: ' +
               'TProtoMemberAttribute carries only a tag, so a property has ' +
               'no way to select a wire form. The codec DOES implement ' +
               'zigzag — the gap is in the attribute. Use int32/int64 if ' +
               'negative values are rare, or wait for the attribute overload.',
               [QuotedStr(AFieldName)]));

    psFixed32, psFixed64, psSFixed32, psSFixed64:
      { BLOCKED-BY: no-wire-form-selector }
      RefuseAt(ALine, ACol, ScalarName(AScalar),
        Format('Field %s uses a fixed-width wire type, which cannot be ' +
               'requested: TProtoMemberAttribute carries only a tag. The ' +
               'codec implements fixed32/fixed64 — the gap is in the ' +
               'attribute. Use int32/int64/uint32/uint64 instead.',
               [QuotedStr(AFieldName)]));
  else
    { Everything else is supported, INCLUDING psUInt32/psUInt64 since
      FIX-PROTO-UINT32-1. psNone lands here too — a message or enum
      reference, which this function has no opinion about.
      An explicit else rather than a bare `end`: FPC warns that the case is
      non-exhaustive otherwise, and silencing that by listing every supported
      scalar would mean editing this whenever a scalar is added. }
  end;
end;

procedure TProtoParser.CheckTypeNameSupported(const ATypeName: string;
  const AFieldName: string; ALine, ACol: Integer);
begin
  { Well-known types arrive as qualified names because the lexer keeps dots in
    an identifier. The plain ones are now bundled in
    Nghttp2.Protobuf.WellKnown — Timestamp, Duration, FieldMask, Empty and the
    wrappers — because they were never a codec limitation, only missing Pascal.
    WellKnownPascalClass is the single list both this check and the emitter
    read. The rest are refused BY NAME, with the actual obstacle stated, so the
    message never reads as "unknown message type" and sends someone hunting for
    a typo in their own schema. }
  if (Pos('google.protobuf.', ATypeName) = 1)
     or (Pos('.google.protobuf.', ATypeName) = 1) then
  begin
    if WellKnownPascalClass(ATypeName) <> '' then
      Exit;   // bundled — nothing to refuse

    { BLOCKED-BY: wkt-not-bundled }
    RefuseAt(ALine, ACol, ATypeName,
      Format('Field %s refers to a well-known type that is not bundled. Api, ' +
             'Type and DescriptorProto are protobuf''s own reflection ' +
             'machinery - they describe .proto files rather than carrying ' +
             'user data, and a program that needs them wants a descriptor ' +
             'library. Everything else IS supported: Timestamp, Duration, ' +
             'FieldMask, Empty, the scalar wrappers, Struct, Value, ' +
             'ListValue, NullValue and Any.',
             [QuotedStr(AFieldName)]));
  end;
end;

// ── Statements ──────────────────────────────────────────────────────────────

procedure TProtoParser.ParseSyntax;
var
  LLine, LCol: Integer;
begin
  ExpectIdentValue('syntax');
  ExpectSymbol('=');
  if Tok.Kind <> ptString then
    Fail('expected a quoted syntax level, e.g. syntax = "proto3";');
  LLine := Tok.Line;
  LCol  := Tok.Column;
  FFile.Syntax := Tok.Value;
  NextTok;
  ExpectSymbol(';');

  if FFile.Syntax <> 'proto3' then
    { BLOCKED-BY: out-of-scope-proto2 }
    RefuseAt(LLine, LCol, Format('syntax = "%s"', [FFile.Syntax]),
      'Only proto3 is supported. proto2 adds required/optional presence, ' +
      'groups and extensions, none of which the RTTI serializer models.');
end;

procedure TProtoParser.ParsePackage;
begin
  ExpectIdentValue('package');
  FFile.PackageName := ExpectIdent;
  ExpectSymbol(';');
end;

procedure TProtoParser.ParseImport;
begin
  ExpectIdentValue('import');
  // `import public` / `import weak` — accepted and ignored, the path is what
  // matters. C2 does not follow imports yet; it is recorded for later.
  if IsIdent('public') or IsIdent('weak') then
    NextTok;
  if Tok.Kind <> ptString then
    Fail('expected a quoted path after import');
  FFile.Imports.Add(Tok.Value);
  NextTok;
  ExpectSymbol(';');
end;

procedure TProtoParser.SkipOptionStatement;
var
  LDepth: Integer;
begin
  { File- and message-level options do not affect what is emitted, so they are
    skipped rather than rejected. If one ever DOES affect output, it must
    become an explicit refusal here — silently ignoring an option that changes
    semantics is the failure mode this whole parser exists to avoid. }
  ExpectIdentValue('option');
  // Depth-aware for the same reason as the rpc body above: the value may be an
  // aggregate, and a ';' inside one does not end the statement. Cheap
  // insurance — the same desync, one level up.
  LDepth := 0;
  while Tok.Kind <> ptEof do
  begin
    if IsSymbol('{') then Inc(LDepth)
    else if IsSymbol('}') then Dec(LDepth)
    else if IsSymbol(';') and (LDepth <= 0) then Break;
    NextTok;
  end;
  ExpectSymbol(';');
end;

procedure TProtoParser.SkipFieldOptions;
var
  LDepth: Integer;
begin
  // [ ... ] after a field. Same reasoning as SkipOptionStatement.
  LDepth := 0;
  repeat
    if IsSymbol('[') then Inc(LDepth)
    else if IsSymbol(']') then Dec(LDepth)
    else if Tok.Kind = ptEof then
      Fail('unterminated field option block');
    NextTok;
  until LDepth = 0;
end;

procedure TProtoParser.SkipReserved;
begin
  // `reserved 2, 15, 9 to 11;` / `reserved "foo";` — a constraint on future
  // edits, with no effect on generated code.
  ExpectIdentValue('reserved');
  while not (IsSymbol(';') or (Tok.Kind = ptEof)) do
    NextTok;
  ExpectSymbol(';');
end;

// ── Messages ────────────────────────────────────────────────────────────────

procedure TProtoParser.ParseMessage(const AParentQualified: string);
var
  LMsg: TProtoMessageNode;
  LLine: Integer;
begin
  LLine := Tok.Line;
  ExpectIdentValue('message');
  LMsg := TProtoMessageNode.Create;
  try
    LMsg.Name := ExpectIdent;
    if AParentQualified = '' then
      LMsg.QualifiedName := LMsg.Name
    else
      LMsg.QualifiedName := AParentQualified + '.' + LMsg.Name;
    LMsg.Line := LLine;
    ExpectSymbol('{');
    { The body may declare more messages and enums, which recurse back here
      and add THEMSELVES to the file's lists. So by the time this returns, any
      children are already hoisted — and they land BEFORE their parent, which
      is harmless: the emitter orders its own output. }
    ParseMessageBody(LMsg);
    ExpectSymbol('}');
  except
    LMsg.Free;
    raise;
  end;
  FFile.Messages.Add(LMsg);
end;

procedure TProtoParser.ParseMessageBody(AMsg: TProtoMessageNode);
var
  LLine, LCol: Integer;
begin
  while not (IsSymbol('}') or (Tok.Kind = ptEof)) do
  begin
    LLine := Tok.Line;
    LCol  := Tok.Column;

    if IsSymbol(';') then          // stray empty statement, legal
    begin
      NextTok;
      Continue;
    end;

    if IsIdent('option')   then begin SkipOptionStatement; Continue; end;
    if IsIdent('reserved') then begin SkipReserved;        Continue; end;

    { ONEOF-1. Was refused until PRESENCE-1 supplied a has-bit. A oneof needs
      no wire support — each member is an ordinary tagged field — so what was
      actually missing was a way to say "this one is set and the others are
      not", which is exactly what a has-bit says. }
    if IsIdent('oneof') then begin ParseOneof(AMsg); Continue; end;

    // MAP-1. Was refused until protogen could synthesise the entry message.
    // A proto3 map IS `repeated <Field>Entry` with key = 1 and value = 2 on
    // the wire, so nothing below the parser needs a map concept.
    if IsIdent('map') then begin ParseMapField(AMsg); Continue; end;

    { `optional` was refused until PRESENCE-1 gave the serializer a has-bit
      ([TProtoHas] on a read-only Boolean). It is now ACCEPTED and handled in
      ParseField, which is also where the two shapes it CANNOT take are
      rejected — `optional repeated` is illegal proto3, and a has-bit on a
      message field is redundant. }

    if IsIdent('required') then
      { BLOCKED-BY: out-of-scope-proto2 }
      Refuse('required',
        'That is proto2. proto3 removed it; every field is optional with ' +
        'implicit presence.');

    if IsIdent('group') then
      { BLOCKED-BY: out-of-scope-proto2 }
      Refuse('group',
        'Groups are a deprecated proto2 construct with no proto3 equivalent. ' +
        'Use a nested message reference.');

    if IsIdent('extend') or IsIdent('extensions') then
      { BLOCKED-BY: out-of-scope-proto2 }
      Refuse(Tok.Value,
        'Extensions are proto2. proto3 has no extension ranges.');

    { ── Nested declarations: HOISTED, not refused ──────────────────────────
      Supported since the C1c corpus run, where nesting was 52% of 7300
      googleapis schemas — far and away the largest gap, and the only large one
      that needed no wire-format change. The child is parsed here and adds
      itself to the file's lists carrying 'Parent.Child' as its QualifiedName;
      Pascal gets a flat set of types with the hierarchy preserved as a name. }
    if IsIdent('message') then
    begin
      ParseMessage(AMsg.QualifiedName);
      Continue;
    end;
    if IsIdent('enum') then
    begin
      ParseEnum(AMsg.QualifiedName);
      Continue;
    end;

    // ── A field ──────────────────────────────────────────────────────────
    if IsIdent('repeated') then
    begin
      NextTok;
      ParseField(AMsg, plRepeated, LLine, LCol);
    end
    else if IsIdent('optional') then
    begin
      NextTok;
      { `optional repeated` is not a thing — proto3 permits exactly one label
        per field. Caught here rather than in ParseField because only this
        point still knows both keywords were written, and in that order. }
      if IsIdent('repeated') then
        { BLOCKED-BY: invalid-proto3 }
        Refuse('optional repeated',
          'proto3 allows one label per field. A repeated field already has ' +
          'no presence to express: empty and absent are the same on the ' +
          'wire, so `optional` adds nothing. Drop `optional`.');
      ParseField(AMsg, plOptional, LLine, LCol);
    end
    else
      ParseField(AMsg, plNone, LLine, LCol);
  end;
end;

{ Upper-cases the first character only, for building `<Field>Entry` from a
  proto field name. Deliberately NOT shared with the emitter's CapFirst: this
  one shapes a proto-level QUALIFIED NAME, the emitter's shapes Pascal
  identifiers, and coupling them would mean a change to Pascal naming silently
  altering the synthesised proto type name. }
function CapitaliseFirst(const S: string): string;
begin
  Result := S;
  if Result <> '' then
    Result[1] := UpCase(Result[1]);
end;

// MAP-1. Parses `map<K, V> name = N;`.
//
// A proto3 map is DEFINED as sugar: the spec says it is equivalent to
//
//     message <Name>Entry { K key = 1; V value = 2; }
//     repeated <Name>Entry <name> = N;
//
// so that is literally what this builds. The entry message is synthesised and
// hoisted to file scope with a qualified name, exactly as a nested message
// already is, and the field is added as an ordinary repeated message field.
//
// Everything downstream therefore needs NO map concept: the codec already
// encodes repeated submessages, the emitter already emits them, and
// PROTOGEN-DTOR already frees them. Only `IsMap` survives, and only so the
// emitter can add dictionary accessors on top of the array.
//
// LINE comments: this text needs to show the entry message's braces, and a
// closing brace inside a { } comment ends it early - Pascal brace comments do
// not nest.
procedure TProtoParser.ParseMapField(AMsg: TProtoMessageNode);
var
  LLine, LCol: Integer;
  LKeyType, LValType, LName: string;
  LKeyScalar, LValScalar: TProtoScalar;
  LEntry: TProtoMessageNode;
  LKeyField, LValField, LMapField: TProtoFieldNode;
  LNumber: Integer;
  LExisting: TProtoFieldNode;
begin
  LLine := Tok.Line;
  LCol  := Tok.Column;
  NextTok;                            // consume 'map'

  ExpectSymbol('<');
  LKeyType := ExpectIdent;
  LKeyScalar := ScalarFromKeyword(LKeyType);
  ExpectSymbol(',');
  LValType := ExpectQualifiedIdent;
  LValScalar := ScalarFromKeyword(LValType);
  ExpectSymbol('>');

  LName := ExpectIdent;
  ExpectSymbol('=');
  LNumber := ExpectNumber;

  { proto3 restricts map KEYS to integral and string types - no float, no
    bytes, no enum, no message. Enforced rather than assumed, because an
    unsupported key would otherwise reach the emitter and produce a Pascal
    comparison that either fails to compile or compares the wrong thing. }
  if not (LKeyScalar in [psInt32, psInt64, psUInt32, psUInt64, psBool,
                         psString]) then
    { BLOCKED-BY: invalid-proto3 }
    RefuseAt(LLine, LCol, 'map key ' + LKeyType,
      Format('Map %s has key type %s. proto3 allows only integral and string '
             + 'map keys - not floating-point, bytes, enum or message types.',
        [QuotedStr(LName), LKeyType]));

  { Group B is refused everywhere else; a map key or value must not be a way
    around that. CheckScalarSupported names the construct and explains. }
  CheckScalarSupported(LKeyScalar, LName + ' (map key)', LLine, LCol);
  CheckScalarSupported(LValScalar, LName + ' (map value)', LLine, LCol);
  if LValScalar = psNone then
    CheckTypeNameSupported(LValType, LName + ' (map value)', LLine, LCol);

  if LNumber <= 0 then
    { BLOCKED-BY: invalid-proto3 }
    RefuseAt(LLine, LCol, IntToStr(LNumber),
      Format('Map %s has number %d. Proto field numbers start at 1.',
        [QuotedStr(LName), LNumber]));
  if (LNumber >= 19000) and (LNumber <= 19999) then
    { BLOCKED-BY: invalid-proto3 }
    RefuseAt(LLine, LCol, IntToStr(LNumber),
      Format('Map %s uses number %d, inside the 19000-19999 range reserved '
             + 'by protobuf itself.', [QuotedStr(LName), LNumber]));

  LExisting := AMsg.FindByNumber(LNumber);
  if LExisting <> nil then
    { BLOCKED-BY: invalid-proto3 }
    RefuseAt(LLine, LCol, IntToStr(LNumber),
      Format('Map %s reuses number %d, already taken by %s on line %d.',
        [QuotedStr(LName), LNumber, QuotedStr(LExisting.Name),
         LExisting.Line]));

  if IsSymbol('[') then
    SkipFieldOptions;
  ExpectSymbol(';');

  { The synthesised entry message. Named <Message>.<Field>Entry and hoisted,
    which is the same shape a nested message gets - so PascalTypeName turns it
    into TMessageFieldEntry with no new naming rule, and two maps in different
    messages cannot collide. }
  LEntry := TProtoMessageNode.Create;
  LEntry.Name          := CapitaliseFirst(LName) + 'Entry';
  LEntry.QualifiedName := AMsg.QualifiedName + '.' + LEntry.Name;
  LEntry.Line          := LLine;

  LKeyField := TProtoFieldNode.Create;
  LKeyField.Name     := 'key';
  LKeyField.TypeName := LKeyType;
  LKeyField.Scalar   := LKeyScalar;
  LKeyField.Number   := 1;
  LKeyField.Line     := LLine;
  LKeyField.Column   := LCol;
  LEntry.Fields.Add(LKeyField);

  LValField := TProtoFieldNode.Create;
  LValField.Name     := 'value';
  LValField.TypeName := LValType;
  LValField.Scalar   := LValScalar;
  LValField.Number   := 2;
  LValField.Line     := LLine;
  LValField.Column   := LCol;
  LEntry.Fields.Add(LValField);

  FFile.Messages.Add(LEntry);

  // The field itself: an ordinary repeated message field, flagged as a map.
  LMapField := TProtoFieldNode.Create;
  LMapField.Name       := LName;
  LMapField.TypeName   := LEntry.QualifiedName;
  LMapField.Scalar     := psNone;
  LMapField.FieldLabel := plRepeated;
  LMapField.Number     := LNumber;
  LMapField.Line       := LLine;
  LMapField.Column     := LCol;
  LMapField.IsMap      := True;
  AMsg.Fields.Add(LMapField);
end;

// ONEOF-1. Parses a `oneof` block, hoisting each member into the message's
// ordinary field list tagged with the group name.
//
// Hoisting rather than nesting is not a shortcut: on the wire a oneof HAS no
// framing, and each member is an ordinary tagged field. Keeping them in the
// normal list is therefore the accurate model, and it is what lets the emitter
// reuse the has-bit machinery unchanged.
//
// LINE comments deliberately: this text wants to show a oneof's braces, and a
// closing brace inside a { } comment ENDS it early - Pascal brace comments do
// not nest. That is exactly how this function failed to compile the first
// time, with the error landing far below on an unrelated line.
procedure TProtoParser.ParseOneof(AMsg: TProtoMessageNode);
var
  LName: string;
  LLine, LCol: Integer;
  LCount: Integer;
begin
  LLine := Tok.Line;
  LCol  := Tok.Column;
  NextTok;                       // consume 'oneof'
  LName  := ExpectIdent;
  LCount := 0;
  ExpectSymbol('{');

  while not (IsSymbol('}') or (Tok.Kind = ptEof)) do
  begin
    if IsSymbol(';') then begin NextTok; Continue; end;
    if IsIdent('option') then begin SkipOptionStatement; Continue; end;

    { A oneof member carries no label. protoc rejects all of these, so
      refusing keeps us aligned with it rather than accepting a schema it
      would not compile - the one oracle cell that counts as a defect. }
    if IsIdent('repeated') then
      { BLOCKED-BY: invalid-proto3 }
      Refuse('repeated inside oneof',
        Format('Field in oneof %s is `repeated`. A oneof member cannot be ' +
               'repeated: a repeated field has no presence, and "which one ' +
               'is set" is the entire content of a oneof. Move it out of ' +
               'the oneof.', [QuotedStr(LName)]));

    if IsIdent('optional') then
      { BLOCKED-BY: invalid-proto3 }
      Refuse('optional inside oneof',
        Format('Field in oneof %s is `optional`. A oneof member already has ' +
               'explicit presence - that is what a oneof IS - so the label ' +
               'is not permitted. Drop it.', [QuotedStr(LName)]));

    if IsIdent('map') then
      { BLOCKED-BY: invalid-proto3 }
      Refuse('map inside oneof',
        Format('Field in oneof %s is a map. proto3 does not allow map fields '
               + 'inside a oneof. Wrap it in a message and use that instead.',
          [QuotedStr(LName)]));

    if IsIdent('oneof') then
      { BLOCKED-BY: invalid-proto3 }
      Refuse('nested oneof',
        Format('oneof %s contains another oneof. proto3 does not allow that.',
          [QuotedStr(LName)]));

    ParseField(AMsg, plNone, Tok.Line, Tok.Column, LName);
    Inc(LCount);
  end;

  ExpectSymbol('}');

  { protoc rejects an empty oneof, so we do too. Refusing is also the safe
    direction when unsure: accepting something protoc rejects is the ONLY
    oracle cell that counts as a defect, since it means emitting Pascal from
    a schema that will not compile anywhere else. }
  if LCount = 0 then
    { BLOCKED-BY: invalid-proto3 }
    RefuseAt(LLine, LCol, 'oneof ' + LName,
      Format('oneof %s is empty. A oneof must declare at least one member.',
        [QuotedStr(LName)]));
end;

{ No `= ''` here: for a method, a default parameter value belongs to the
  DECLARATION only, and repeating it in the implementation is a syntax error. }
procedure TProtoParser.ParseField(AMsg: TProtoMessageNode;
  AFieldLabel: TProtoLabel; ALabelLine, ALabelCol: Integer;
  const AOneofName: string);
var
  LField: TProtoFieldNode;
  LTypeName: string;
  LTypeLine, LTypeCol: Integer;
  LScalar: TProtoScalar;
  LExisting: TProtoFieldNode;
begin
  LTypeLine := Tok.Line;
  LTypeCol  := Tok.Column;

  { MAP-1. A map reaching ParseField means it followed a LABEL — `repeated
    map<...>` or `optional map<...>` — since the body loop routes a leading
    `map` to ParseMapField. Both are illegal proto3: a map is already
    repeated, and it has no presence to add. }
  if IsIdent('map') then
    { BLOCKED-BY: invalid-proto3 }
    Refuse('labelled map',
      'A map field cannot carry `repeated` or `optional`. A map is already a '
      + 'repeated entry list, and has no presence to express. Drop the label.');

  LTypeName := ExpectQualifiedIdent;
  LScalar   := ScalarFromKeyword(LTypeName);

  { The scalar check deliberately waits until the field NAME has been read,
    below. Checking here instead would fire first and leave every zigzag/fixed
    refusal saying `Field '<pending>'`, which is exactly the kind of diagnostic
    that sends someone hunting in the wrong place. }

  LField := TProtoFieldNode.Create;
  try
    LField.TypeName   := LTypeName;
    LField.Scalar     := LScalar;
    LField.FieldLabel := AFieldLabel;
    LField.Line       := ALabelLine;
    LField.Column     := ALabelCol;
    LField.OneofName  := AOneofName;      // ONEOF-1; '' for ordinary fields
    LField.Name       := ExpectIdent;

    { Now that the name is known the refusal can quote it, and the position
      still points at the TYPE token rather than the name — which is where the
      user has to make the edit. }
    CheckScalarSupported(LScalar, LField.Name, LTypeLine, LTypeCol);
    CheckTypeNameSupported(LTypeName, LField.Name, LTypeLine, LTypeCol);

    { PRESENCE-1 note. `optional` on a MESSAGE field is legal proto3 and
      redundant — a message field already has explicit presence, nil meaning
      absent — whereas `optional` on an ENUM is meaningful, since an enum is a
      scalar on the wire and needs a has-bit like any other.

      Both arrive here as psNone, which is only "not a built-in scalar"; the
      parser cannot tell an enum reference from a message reference, and a
      forward reference is not resolvable at this point at all. So the
      distinction is deliberately NOT made here. TMessagesEmitter resolves the
      name against the whole file and refuses the message case there. Refusing
      psNone outright here would have rejected `optional MyEnum`, which is
      valid and which the codec supports. }

    ExpectSymbol('=');
    LField.Number := ExpectNumber;

    if LField.Number <= 0 then
      { BLOCKED-BY: invalid-proto3 }
      RefuseAt(LTypeLine, LTypeCol, IntToStr(LField.Number),
        Format('Field %s has number %d. Proto field numbers start at 1.',
          [QuotedStr(LField.Name), LField.Number]));

    { 19000-19999 is reserved for the protobuf implementation itself.
      Accepting one would produce a schema protoc refuses. }
    if (LField.Number >= 19000) and (LField.Number <= 19999) then
      { BLOCKED-BY: invalid-proto3 }
      RefuseAt(LTypeLine, LTypeCol, IntToStr(LField.Number),
        Format('Field %s uses number %d, inside the 19000-19999 range ' +
               'reserved by protobuf itself.',
          [QuotedStr(LField.Name), LField.Number]));

    LExisting := AMsg.FindByNumber(LField.Number);
    if LExisting <> nil then
      { BLOCKED-BY: invalid-proto3 }
      RefuseAt(LTypeLine, LTypeCol, IntToStr(LField.Number),
        Format('Field %s reuses number %d, already taken by %s on line %d. ' +
               'Duplicate numbers would emit two properties with the same ' +
               '[TProtoMember].',
          [QuotedStr(LField.Name), LField.Number,
           QuotedStr(LExisting.Name), LExisting.Line]));

    if IsSymbol('[') then
      SkipFieldOptions;

    ExpectSymbol(';');
  except
    LField.Free;
    raise;
  end;
  AMsg.Fields.Add(LField);
end;

// ── Enums ───────────────────────────────────────────────────────────────────

procedure TProtoParser.ParseEnum(const AParentQualified: string);
var
  LEnum: TProtoEnumNode;
  LVal: TProtoEnumValueNode;
  LLine: Integer;
begin
  LLine := Tok.Line;
  ExpectIdentValue('enum');
  LEnum := TProtoEnumNode.Create;
  try
    LEnum.Name := ExpectIdent;
    if AParentQualified = '' then
      LEnum.QualifiedName := LEnum.Name
    else
      LEnum.QualifiedName := AParentQualified + '.' + LEnum.Name;
    LEnum.Line := LLine;
    ExpectSymbol('{');

    while not (IsSymbol('}') or (Tok.Kind = ptEof)) do
    begin
      if IsSymbol(';') then begin NextTok; Continue; end;
      if IsIdent('option')   then begin SkipOptionStatement; Continue; end;
      if IsIdent('reserved') then begin SkipReserved;        Continue; end;

      LVal := TProtoEnumValueNode.Create;
      try
        LVal.Line   := Tok.Line;
        LVal.Name   := ExpectIdent;
        ExpectSymbol('=');
        LVal.Number := ExpectNumber;
        if IsSymbol('[') then
          SkipFieldOptions;
        ExpectSymbol(';');
      except
        LVal.Free;
        raise;
      end;
      LEnum.Values.Add(LVal);
    end;

    ExpectSymbol('}');

    { proto3 requires the first enum value to be zero — it is the default for
      every field of this type. A generator that emitted a Pascal enum whose
      first member was not the proto zero would silently shift every ordinal,
      because the serializer maps enums by ORDINAL. }
    if (LEnum.Values.Count > 0) and (LEnum.Values[0].Number <> 0) then
      { BLOCKED-BY: invalid-proto3 }
      RefuseAt(LEnum.Values[0].Line, 1, LEnum.Name,
        Format('proto3 requires the first value of enum %s to be 0, but %s ' +
               'is %d. The serializer maps enums by ordinal, so a non-zero ' +
               'first value would shift every member.',
          [QuotedStr(LEnum.Name), QuotedStr(LEnum.Values[0].Name),
           LEnum.Values[0].Number]));
  except
    LEnum.Free;
    raise;
  end;
  FFile.Enums.Add(LEnum);
end;

// ── Services ────────────────────────────────────────────────────────────────

procedure TProtoParser.ParseService;
var
  LSvc: TProtoServiceNode;
  LLine: Integer;
begin
  LLine := Tok.Line;
  ExpectIdentValue('service');
  LSvc := TProtoServiceNode.Create;
  try
    LSvc.Name := ExpectIdent;
    LSvc.Line := LLine;
    ExpectSymbol('{');

    while not (IsSymbol('}') or (Tok.Kind = ptEof)) do
    begin
      if IsSymbol(';') then begin NextTok; Continue; end;
      if IsIdent('option') then begin SkipOptionStatement; Continue; end;
      if IsIdent('rpc') then
        ParseRpc(LSvc)
      else
        Fail(Format('expected "rpc" inside service %s but found %s',
          [QuotedStr(LSvc.Name), QuotedStr(Tok.Value)]));
    end;

    ExpectSymbol('}');
  except
    LSvc.Free;
    raise;
  end;
  FFile.Services.Add(LSvc);
end;

procedure TProtoParser.ParseRpc(AService: TProtoServiceNode);
var
  LRpc: TProtoRpcNode;
  LDepth: Integer;
begin
  LRpc := TProtoRpcNode.Create;
  try
    LRpc.Line := Tok.Line;
    ExpectIdentValue('rpc');
    LRpc.Name := ExpectIdent;

    ExpectSymbol('(');
    if IsIdent('stream') then
    begin
      LRpc.RequestStream := True;
      NextTok;
    end;
    LRpc.RequestType := ExpectQualifiedIdent;
    ExpectSymbol(')');

    { RPC types were previously unchecked, which mattered little while every
      well-known type was refused at field level anyway. Now that some are
      bundled and some are not, an rpc returning google.protobuf.Any would sail
      through here and produce an interface the emitter cannot honour. Checked
      at the same position the type was read. }
    CheckTypeNameSupported(LRpc.RequestType,
      Format('rpc %s request', [LRpc.Name]), LRpc.Line, 1);

    ExpectIdentValue('returns');

    ExpectSymbol('(');
    if IsIdent('stream') then
    begin
      LRpc.ResponseStream := True;
      NextTok;
    end;
    LRpc.ResponseType := ExpectQualifiedIdent;
    CheckTypeNameSupported(LRpc.ResponseType,
      Format('rpc %s response', [LRpc.Name]), LRpc.Line, 1);
    ExpectSymbol(')');

    // Either a bare `;` or an options block, which must be skipped by BRACE
    // DEPTH rather than by scanning for the first closing brace. An rpc body
    // routinely contains an aggregate option value:
    //
    //   rpc Get(Req) returns (Resp) ...
    //     option (google.api.http) = ... get: "/v1/..." ...
    //
    // and its inner closing brace is not the body's. Stopping at the first one
    // leaves the parser mid-declaration, where it then fails against the NEXT
    // rpc — which is why a googleapis corpus run reported 933 refusals whose
    // "construct" was the word `rpc`, plus 546 bare `}`. One desync, thousands
    // of files.
    if IsSymbol('{') then
    begin
      LDepth := 0;
      repeat
        if IsSymbol('{') then Inc(LDepth)
        else if IsSymbol('}') then Dec(LDepth)
        else if Tok.Kind = ptEof then
          Fail(Format('unterminated body for rpc %s', [QuotedStr(LRpc.Name)]));
        NextTok;
      until LDepth = 0;
      if IsSymbol(';') then NextTok;
    end
    else
      ExpectSymbol(';');
  except
    LRpc.Free;
    raise;
  end;
  AService.Rpcs.Add(LRpc);
end;

// ── Top level ───────────────────────────────────────────────────────────────

procedure TProtoParser.ParseTopLevel;
begin
  while Tok.Kind <> ptEof do
  begin
    if IsSymbol(';') then begin NextTok; Continue; end;

    if IsIdent('package') then begin ParsePackage;        Continue; end;
    if IsIdent('import')  then begin ParseImport;         Continue; end;
    if IsIdent('option')  then begin SkipOptionStatement; Continue; end;
    if IsIdent('message') then begin ParseMessage;        Continue; end;
    if IsIdent('enum')    then begin ParseEnum;           Continue; end;
    if IsIdent('service') then begin ParseService;        Continue; end;

    if IsIdent('syntax') then
      Fail('a second syntax statement — it must appear once, first');

    if IsIdent('extend') or IsIdent('extensions') then
      { BLOCKED-BY: out-of-scope-proto2 }
      Refuse(Tok.Value, 'Extensions are proto2. proto3 has no extension ranges.');

    Fail(Format('unexpected %s at file scope — expected package, import, ' +
                'option, message, enum or service', [QuotedStr(Tok.Value)]));
  end;
end;

function TProtoParser.Parse: TProtoFileNode;
begin
  FFile := TProtoFileNode.Create;
  try
    NextTok;   // prime

    { The syntax statement is mandatory and must come first. Without it protoc
      assumes proto2, so treating a missing one as "probably proto3" would
      accept a file that means something else entirely. }
    if not IsIdent('syntax') then
      Fail('a .proto file must begin with syntax = "proto3";');

    ParseSyntax;
    ParseTopLevel;
  except
    FFile.Free;
    FFile := nil;
    raise;
  end;
  Result := FFile;
  FFile  := nil;   // ownership transferred to the caller
end;

// ── Convenience ─────────────────────────────────────────────────────────────

function ParseProtoFile(const AFileName: string): TProtoFileNode;
var
  LParser: TProtoParser;
begin
  LParser := TProtoParser.Create(LoadProtoFile(AFileName), AFileName);
  try
    Result := LParser.Parse;
  finally
    LParser.Free;
  end;
end;

end.
