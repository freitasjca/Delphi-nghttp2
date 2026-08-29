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
    procedure ParseField(AMsg: TProtoMessageNode; AFieldLabel: TProtoLabel;
      ALabelLine, ALabelCol: Integer);
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
      RefuseAt(ALine, ACol, ScalarName(AScalar),
        Format('Field %s uses zigzag encoding, which cannot be requested: ' +
               'TProtoMemberAttribute carries only a tag, so a property has ' +
               'no way to select a wire form. The codec DOES implement ' +
               'zigzag — the gap is in the attribute. Use int32/int64 if ' +
               'negative values are rare, or wait for the attribute overload.',
               [QuotedStr(AFieldName)]));

    psFixed32, psFixed64, psSFixed32, psSFixed64:
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
    an identifier. They need google/protobuf/*.proto imported and a matching
    Pascal class; neither exists here. Named explicitly so the message does not
    read as "unknown message type", which would send the user hunting for a
    typo in their own schema. }
  if (Pos('google.protobuf.', ATypeName) = 1)
     or (Pos('.google.protobuf.', ATypeName) = 1) then
    RefuseAt(ALine, ACol, ATypeName,
      Format('Field %s refers to a protobuf well-known type. Those are not ' +
             'bundled: they need google/protobuf/*.proto and hand-written ' +
             'Pascal equivalents. Declare your own message instead.',
             [QuotedStr(AFieldName)]));
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

    // ── Group C refusals ────────────────────────────────────────────────
    if IsIdent('oneof') then
      Refuse('oneof',
        'A oneof is a tagged union with presence semantics; the RTTI ' +
        'serializer has no way to express which member is set. Model it as ' +
        'separate optional-by-convention fields instead.');

    if IsIdent('map') then
      Refuse('map',
        'A map field is encoded as a repeated entry submessage with key/value ' +
        'fields, which needs a synthesised message type per map. Model it as ' +
        'a repeated message with explicit key and value fields.');

    if IsIdent('optional') then
      Refuse('optional',
        'proto3 explicit presence needs a has-bit, and the serializer has no ' +
        'presence model — it currently emits even default-valued scalars, so ' +
        '"set to zero" and "not set" are indistinguishable on the wire. Drop ' +
        'the keyword: an implicit-presence field is the proto3 default.');

    if IsIdent('required') then
      Refuse('required',
        'That is proto2. proto3 removed it; every field is optional with ' +
        'implicit presence.');

    if IsIdent('group') then
      Refuse('group',
        'Groups are a deprecated proto2 construct with no proto3 equivalent. ' +
        'Use a nested message reference.');

    if IsIdent('extend') or IsIdent('extensions') then
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
    else
      ParseField(AMsg, plNone, LLine, LCol);
  end;
end;

procedure TProtoParser.ParseField(AMsg: TProtoMessageNode;
  AFieldLabel: TProtoLabel; ALabelLine, ALabelCol: Integer);
var
  LField: TProtoFieldNode;
  LTypeName: string;
  LTypeLine, LTypeCol: Integer;
  LScalar: TProtoScalar;
  LExisting: TProtoFieldNode;
begin
  LTypeLine := Tok.Line;
  LTypeCol  := Tok.Column;

  // A map field can also appear as `map<k,v> name = n;` — catch it here too,
  // since the body loop only sees `map` when it is the first token.
  if IsIdent('map') then
    Refuse('map',
      'A map field needs a synthesised entry message per map. Model it as a ' +
      'repeated message with explicit key and value fields.');

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
    LField.Name       := ExpectIdent;

    { Now that the name is known the refusal can quote it, and the position
      still points at the TYPE token rather than the name — which is where the
      user has to make the edit. }
    CheckScalarSupported(LScalar, LField.Name, LTypeLine, LTypeCol);
    CheckTypeNameSupported(LTypeName, LField.Name, LTypeLine, LTypeCol);

    ExpectSymbol('=');
    LField.Number := ExpectNumber;

    if LField.Number <= 0 then
      RefuseAt(LTypeLine, LTypeCol, IntToStr(LField.Number),
        Format('Field %s has number %d. Proto field numbers start at 1.',
          [QuotedStr(LField.Name), LField.Number]));

    { 19000-19999 is reserved for the protobuf implementation itself.
      Accepting one would produce a schema protoc refuses. }
    if (LField.Number >= 19000) and (LField.Number <= 19999) then
      RefuseAt(LTypeLine, LTypeCol, IntToStr(LField.Number),
        Format('Field %s uses number %d, inside the 19000-19999 range ' +
               'reserved by protobuf itself.',
          [QuotedStr(LField.Name), LField.Number]));

    LExisting := AMsg.FindByNumber(LField.Number);
    if LExisting <> nil then
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

    ExpectIdentValue('returns');

    ExpectSymbol('(');
    if IsIdent('stream') then
    begin
      LRpc.ResponseStream := True;
      NextTok;
    end;
    LRpc.ResponseType := ExpectQualifiedIdent;
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
