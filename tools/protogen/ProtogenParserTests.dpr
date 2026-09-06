program ProtogenParserTests;

// ============================================================================
//  ProtogenParserTests — the C1 gate from plans/horse-grpc-codegen.md.
//
//  Two halves, and the second is the one that matters.
//
//  POSITIVE: parse the two real .proto files in this repo and assert the AST
//  matches them field for field. They are the files the hand-written samples
//  were built from, so getting them right is the precondition for C2.
//
//  NEGATIVE: every unsupported proto3 feature must be refused, AND the refusal
//  must name a reason. Per project-protobuf-security-audit, a negative test
//  that only asserts "it raised" passes for the wrong reason — the first F2
//  test did exactly that, because EAccessViolation is an Exception too. So
//  each case here checks the exception TYPE, that the message mentions the
//  construct, and that it explains rather than merely restates.
//
//  Build (FPC trunk):
//    fpc -MDelphi -O1 -Fu. ProtogenParserTests.dpr
//  Build (Windows):
//    dcc32 -CC -B ProtogenParserTests.dpr
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$IFEND}
  Protogen.Ast,
  Protogen.Lexer,
  Protogen.Parser;

var
  GPass: Integer = 0;
  GFail: Integer = 0;

procedure Section(const S: string);
begin
  WriteLn;
  WriteLn('-- ', S);
end;

procedure Check(const AName: string; APassed: Boolean; const ADetail: string = '');
begin
  if APassed then
  begin
    WriteLn('  PASS  ', AName);
    Inc(GPass);
  end
  else
  begin
    if ADetail = '' then
      WriteLn('  FAIL  ', AName)
    else
      WriteLn('  FAIL  ', AName, '  [', ADetail, ']');
    Inc(GFail);
  end;
end;

function Parse(const ASource: string): TProtoFileNode;
var
  LParser: TProtoParser;
begin
  LParser := TProtoParser.Create(ASource, '<test>');
  try
    Result := LParser.Parse;
  finally
    LParser.Free;
  end;
end;

{ Asserts that ASource is REFUSED, and refused for the right reason.

  Three separate assertions, because each catches a different way of being
  wrong: the wrong exception type means we crashed rather than refused; a
  message that omits the construct sends the user hunting; a message no longer
  than the construct itself is a restatement, not an explanation. }
procedure ExpectRefusal(const ACaseName, ASource, AMustMention: string);
var
  LFile: TProtoFileNode;
  LRaised: Boolean;
  LMsg: string;
begin
  LRaised := False;
  LMsg    := '';
  LFile   := nil;
  try
    try
      LFile := Parse(ASource);
    except
      on E: EProtoParseError do
      begin
        LRaised := True;
        LMsg    := E.Message;
      end;
      on E: EProtoLexError do
      begin
        LRaised := True;
        LMsg    := E.Message;
      end;
      on E: Exception do
      begin
        // Explicitly NOT counted as a refusal: an AV or a range error means
        // the parser fell over, which is a defect wearing a refusal's clothes.
        Check(ACaseName + ' - refused with EProtoParseError', False,
          'got ' + E.ClassName + ': ' + E.Message);
        Exit;
      end;
    end;
  finally
    LFile.Free;
  end;

  Check(ACaseName + ' - refused', LRaised);
  if not LRaised then Exit;

  Check(ACaseName + ' - names ' + QuotedStr(AMustMention),
    Pos(LowerCase(AMustMention), LowerCase(LMsg)) > 0, LMsg);

  Check(ACaseName + ' - explains, not just restates',
    Length(LMsg) > Length(AMustMention) + 40, LMsg);
end;

// ── The two real .proto files, inline ───────────────────────────────────────
// Inline rather than read from disk so the gate cannot silently pass by
// finding no file. Kept byte-faithful to samples/grpc/greeter.proto and
// samples/grpc-server/echo.proto.

const
  GREETER_PROTO =
    'syntax = "proto3";'#10 +
    ''#10 +
    'package greeter;'#10 +
    ''#10 +
    'service Greeter {'#10 +
    '  rpc Greet (GreetRequest) returns (GreetResponse);'#10 +
    '  rpc Echo  (EchoRequest)  returns (EchoResponse);'#10 +
    '  // M6a - server-streaming.'#10 +
    '  rpc ListGreetings (GreetRequest) returns (stream GreetResponse);'#10 +
    '  rpc JoinNames     (stream GreetRequest) returns (GreetResponse);'#10 +
    '  rpc ChatGreetings (stream GreetRequest) returns (stream GreetResponse);'#10 +
    '}'#10 +
    ''#10 +
    'message GreetRequest {'#10 +
    '  string name = 1;'#10 +
    '}'#10 +
    ''#10 +
    'message GreetResponse {'#10 +
    '  string message = 1;'#10 +
    '}'#10 +
    ''#10 +
    'message EchoRequest {'#10 +
    '  int32  i32 = 1;'#10 +
    '  int64  i64 = 2;'#10 +
    '  bool   b   = 3;'#10 +
    '  string s   = 4;'#10 +
    '  float  f32 = 5;'#10 +
    '  double f64 = 6;'#10 +
    '}'#10 +
    ''#10 +
    'message EchoResponse {'#10 +
    '  int32  i32 = 1;'#10 +
    '  int64  i64 = 2;'#10 +
    '  bool   b   = 3;'#10 +
    '  string s   = 4;'#10 +
    '  float  f32 = 5;'#10 +
    '  double f64 = 6;'#10 +
    '}'#10;

  ECHO_PROTO =
    'syntax = "proto3";'#10 +
    'package echo;'#10 +
    '/* block comment, and it must not swallow the message below */'#10 +
    'message SayRequest {'#10 +
    '  string name = 1;'#10 +
    '}'#10 +
    'message SayResponse {'#10 +
    '  string message = 1;   // Pascal: TSayResponse.text'#10 +
    '  int32  length  = 2;'#10 +
    '}'#10 +
    'service Echo {'#10 +
    '  rpc Say   (SayRequest) returns (SayResponse);'#10 +
    '  rpc Upper (SayRequest) returns (SayResponse);'#10 +
    '}'#10;

// ── 01 · greeter.proto ──────────────────────────────────────────────────────

procedure TestGreeter;
var
  F: TProtoFileNode;
  M: TProtoMessageNode;
  S: TProtoServiceNode;
begin
  Section('01  greeter.proto - the four RPC shapes');
  F := Parse(GREETER_PROTO);
  try
    Check('syntax = proto3',  F.Syntax = 'proto3', F.Syntax);
    Check('package = greeter', F.PackageName = 'greeter', F.PackageName);
    Check('4 messages', F.Messages.Count = 4, IntToStr(F.Messages.Count));
    Check('1 service',  F.Services.Count = 1, IntToStr(F.Services.Count));

    M := F.FindMessage('GreetRequest');
    Check('GreetRequest found', M <> nil);
    if M <> nil then
    begin
      Check('GreetRequest has 1 field', M.Fields.Count = 1);
      Check('  name : string = 1',
        (M.Fields[0].Name = 'name') and (M.Fields[0].Scalar = psString)
        and (M.Fields[0].Number = 1));
    end;

    M := F.FindMessage('EchoRequest');
    Check('EchoRequest found', M <> nil);
    if M <> nil then
    begin
      Check('EchoRequest has 6 fields', M.Fields.Count = 6,
        IntToStr(M.Fields.Count));
      Check('  i32 : int32  = 1',
        (M.Fields[0].Scalar = psInt32)  and (M.Fields[0].Number = 1));
      Check('  i64 : int64  = 2',
        (M.Fields[1].Scalar = psInt64)  and (M.Fields[1].Number = 2));
      Check('  b   : bool   = 3',
        (M.Fields[2].Scalar = psBool)   and (M.Fields[2].Number = 3));
      Check('  f32 : float  = 5',
        (M.Fields[4].Scalar = psFloat)  and (M.Fields[4].Number = 5));
      Check('  f64 : double = 6',
        (M.Fields[5].Scalar = psDouble) and (M.Fields[5].Number = 6));
    end;

    { `message` is a proto field name here and a Pascal keyword. The parser
      must NOT special-case it — renaming belongs to C2. }
    M := F.FindMessage('GreetResponse');
    Check('GreetResponse.message kept verbatim (renaming is C2''s job)',
      (M <> nil) and (M.Fields.Count = 1) and (M.Fields[0].Name = 'message'));

    S := F.Services[0];
    Check('service Greeter', S.Name = 'Greeter', S.Name);
    Check('5 rpcs', S.Rpcs.Count = 5, IntToStr(S.Rpcs.Count));

    Check('Greet: unary',
      (S.Rpcs[0].Name = 'Greet')
      and (not S.Rpcs[0].RequestStream) and (not S.Rpcs[0].ResponseStream));
    Check('ListGreetings: server-streaming',
      (S.Rpcs[2].Name = 'ListGreetings')
      and (not S.Rpcs[2].RequestStream) and S.Rpcs[2].ResponseStream);
    Check('JoinNames: client-streaming',
      (S.Rpcs[3].Name = 'JoinNames')
      and S.Rpcs[3].RequestStream and (not S.Rpcs[3].ResponseStream));
    Check('ChatGreetings: bidi',
      (S.Rpcs[4].Name = 'ChatGreetings')
      and S.Rpcs[4].RequestStream and S.Rpcs[4].ResponseStream);
    Check('Greet request/response types',
      (S.Rpcs[0].RequestType = 'GreetRequest')
      and (S.Rpcs[0].ResponseType = 'GreetResponse'));
  finally
    F.Free;
  end;
end;

// ── 02 · echo.proto ─────────────────────────────────────────────────────────

procedure TestEcho;
var
  F: TProtoFileNode;
  M: TProtoMessageNode;
begin
  Section('02  echo.proto - comments, two services shapes');
  F := Parse(ECHO_PROTO);
  try
    Check('package = echo', F.PackageName = 'echo', F.PackageName);
    Check('2 messages', F.Messages.Count = 2, IntToStr(F.Messages.Count));
    Check('1 service',  F.Services.Count = 1);

    M := F.FindMessage('SayResponse');
    Check('SayResponse found', M <> nil);
    if M <> nil then
    begin
      Check('2 fields', M.Fields.Count = 2, IntToStr(M.Fields.Count));
      Check('  message : string = 1',
        (M.Fields[0].Name = 'message') and (M.Fields[0].Number = 1));
      Check('  length  : int32  = 2  (trailing // comment consumed)',
        (M.Fields[1].Name = 'length') and (M.Fields[1].Scalar = psInt32)
        and (M.Fields[1].Number = 2));
    end;

    Check('2 rpcs', F.Services[0].Rpcs.Count = 2);
  finally
    F.Free;
  end;
end;

// ── 03 · supported constructs that are easy to break ────────────────────────

procedure TestSupportedExtras;
var
  F: TProtoFileNode;
  M: TProtoMessageNode;
begin
  Section('03  repeated, enum, bytes, uint32/uint64');

  F := Parse(
    'syntax = "proto3";'#10 +
    'package t;'#10 +
    'enum Status { STATUS_NONE = 0; STATUS_OK = 1; }'#10 +
    'message M {'#10 +
    '  repeated int32 ids = 1;'#10 +
    '  bytes  blob = 2;'#10 +
    '  uint32 u32  = 3;'#10 +
    '  uint64 u64  = 4;'#10 +
    '  Status st   = 5;'#10 +
    '  repeated M children = 6;'#10 +
    '  int32 opt = 7 [deprecated = true];'#10 +
    '  reserved 90, 91;'#10 +
    '}'#10);
  try
    Check('enum parsed', F.Enums.Count = 1);
    Check('  first value is 0', (F.Enums.Count = 1)
      and (F.Enums[0].Values.Count = 2) and (F.Enums[0].Values[0].Number = 0));

    M := F.FindMessage('M');
    Check('message M found', M <> nil);
    if M <> nil then
    begin
      Check('7 fields (reserved is not a field)', M.Fields.Count = 7,
        IntToStr(M.Fields.Count));
      Check('repeated int32 ids',
        M.Fields[0].IsRepeated and (M.Fields[0].Scalar = psInt32));
      Check('bytes blob', M.Fields[1].Scalar = psBytes);
      { uint32/uint64 are SUPPORTED as of FIX-PROTO-UINT32-1. If these ever
        start being refused, someone has re-added them to the wrong group. }
      Check('uint32 accepted (FIX-PROTO-UINT32-1)',
        M.Fields[2].Scalar = psUInt32);
      Check('uint64 accepted (FIX-PROTO-UINT32-1)',
        M.Fields[3].Scalar = psUInt64);
      Check('message-typed field is psNone with TypeName kept',
        (M.Fields[4].Scalar = psNone) and (M.Fields[4].TypeName = 'Status'));
      Check('repeated message field',
        M.Fields[5].IsRepeated and (M.Fields[5].TypeName = 'M'));
      Check('field options skipped, field still parsed',
        (M.Fields[6].Name = 'opt') and (M.Fields[6].Number = 7));
    end;
  finally
    F.Free;
  end;
end;

// ── 04 · nested declarations are hoisted, not refused ───────────────────────
// The 52% gap from the C1c googleapis run. Pascal has no nested class scope,
// so hierarchy is preserved as a NAME and the types are flattened to file
// scope. What they are finally CALLED in Pascal is the emitter's decision -
// this only fixes the identity.

procedure TestNesting;
var
  F: TProtoFileNode;
  M: TProtoMessageNode;
  E: TProtoEnumNode;
begin
  Section('04  nested message / enum are hoisted with a qualified name');

  F := Parse(
    'syntax = "proto3";'#10 +
    'package t;'#10 +
    'message Outer {'#10 +
    '  enum Status { STATUS_NONE = 0; STATUS_OK = 1; }'#10 +
    '  message Inner {'#10 +
    '    message Deep { int32 d = 1; }'#10 +
    '    Deep deep = 1;'#10 +
    '  }'#10 +
    '  Status st = 1;'#10 +
    '  Inner  in = 2;'#10 +
    '}'#10 +
    'message Sibling { int32 s = 1; }'#10);
  try
    { 4 messages: Outer, Outer.Inner, Outer.Inner.Deep, Sibling — all at file
      scope now, none nested inside another node. }
    Check('4 messages hoisted to file scope', F.Messages.Count = 4,
      IntToStr(F.Messages.Count));
    Check('1 enum hoisted', F.Enums.Count = 1, IntToStr(F.Enums.Count));

    M := F.FindMessage('Outer');
    Check('Outer found', M <> nil);
    Check('  Outer.QualifiedName = "Outer"',
      (M <> nil) and (M.QualifiedName = 'Outer'),
      'got ' + M.QualifiedName);
    Check('  Outer keeps its own 2 fields, not its children''s',
      (M <> nil) and (M.Fields.Count = 2), IntToStr(M.Fields.Count));

    M := F.FindMessage('Outer.Inner');
    Check('Outer.Inner found by qualified name', M <> nil);
    Check('  simple Name is still "Inner"',
      (M <> nil) and (M.Name = 'Inner'));

    { Two levels deep — the qualifier has to accumulate, not just record the
      immediate parent. }
    M := F.FindMessage('Outer.Inner.Deep');
    Check('Outer.Inner.Deep found - qualifier accumulates', M <> nil);
    Check('  its field survived the hoist',
      (M <> nil) and (M.Fields.Count = 1) and (M.Fields[0].Name = 'd'));

    E := F.FindEnum('Outer.Status');
    Check('Outer.Status enum found by qualified name', E <> nil);
    Check('  2 values', (E <> nil) and (E.Values.Count = 2));

    M := F.FindMessage('Sibling');
    Check('file-scope message unqualified',
      (M <> nil) and (M.QualifiedName = 'Sibling'));
  finally
    F.Free;
  end;
end;

// ── 05 · bundled well-known types ───────────────────────────────────────────
// 1395 of 7300 googleapis files wanted one of these. They were never a codec
// limitation — Timestamp is int64+int32, FieldMask is a repeated string — and
// now Nghttp2.Protobuf.WellKnown supplies the Pascal.

procedure TestWellKnown;
var
  F: TProtoFileNode;
  M: TProtoMessageNode;
begin
  Section('05  bundled well-known types are accepted');

  F := Parse(
    'syntax = "proto3";'#10 +
    'package t;'#10 +
    'import "google/protobuf/timestamp.proto";'#10 +
    'message M {'#10 +
    '  google.protobuf.Timestamp   created = 1;'#10 +
    '  google.protobuf.Duration    ttl     = 2;'#10 +
    '  google.protobuf.FieldMask   mask    = 3;'#10 +
    '  google.protobuf.StringValue note    = 4;'#10 +
    '  google.protobuf.Int32Value  count   = 5;'#10 +
    '  google.protobuf.BoolValue   flag    = 6;'#10 +
    '  .google.protobuf.Timestamp  updated = 7;'#10 +
    '}'#10 +
    'service S {'#10 +
    '  rpc Wipe (M) returns (google.protobuf.Empty);'#10 +
    '}'#10);
  try
    M := F.FindMessage('M');
    Check('message with 7 well-known fields parsed', M <> nil);
    if M <> nil then
    begin
      Check('7 fields', M.Fields.Count = 7, IntToStr(M.Fields.Count));
      Check('Timestamp kept as a type reference, not a scalar',
        (M.Fields[0].Scalar = psNone)
        and (M.Fields[0].TypeName = 'google.protobuf.Timestamp'));
      { The leading-dot spelling is the same type — a schema uses it to escape
        package-relative lookup, and the lookup must not care. }
      Check('leading-dot spelling accepted too',
        M.Fields[6].TypeName = '.google.protobuf.Timestamp',
        M.Fields[6].TypeName);
    end;

    Check('Empty accepted as an rpc response',
      (F.Services.Count = 1) and (F.Services[0].Rpcs.Count = 1)
      and (F.Services[0].Rpcs[0].ResponseType = 'google.protobuf.Empty'));
  finally
    F.Free;
  end;

  { The mapping is the contract shared with the emitter, so assert it directly
    rather than only through the parser's accept/refuse behaviour. }
  Check('Timestamp maps to TProtobufTimestamp',
    WellKnownPascalClass('google.protobuf.Timestamp') = 'TProtobufTimestamp');
  Check('leading dot maps identically',
    WellKnownPascalClass('.google.protobuf.FieldMask') = 'TProtobufFieldMask');
  { STRUCT-1 flipped these four. The assertion is kept rather than deleted,
    inverted, because "Struct is NOT bundled" was true for a reason and a
    future reader should see that it CHANGED rather than that it vanished. }
  Check('Struct now maps to TProtobufStruct',
    WellKnownPascalClass('google.protobuf.Struct') = 'TProtobufStruct');
  Check('Value maps to TProtobufValue',
    WellKnownPascalClass('google.protobuf.Value') = 'TProtobufValue');
  Check('ListValue maps to TProtobufListValue',
    WellKnownPascalClass('google.protobuf.ListValue') = 'TProtobufListValue');
  Check('NullValue maps to TProtobufNullValue',
    WellKnownPascalClass('google.protobuf.NullValue') = 'TProtobufNullValue');

  { The distinction the emitter's destructor depends on. Treated as a message,
    NullValue would be emitted into a destructor and freed - and it is an enum
    value, not an instance. }
  Check('NullValue is flagged as an ENUM', WellKnownIsEnum('google.protobuf.NullValue'));
  Check('  and the leading-dot spelling too', WellKnownIsEnum('.google.protobuf.NullValue'));
  Check('Struct is NOT flagged as an enum', not WellKnownIsEnum('google.protobuf.Struct'));
  Check('Timestamp is NOT flagged as an enum', not WellKnownIsEnum('google.protobuf.Timestamp'));
  Check('a user type is not flagged as an enum', not WellKnownIsEnum('myapp.NullValue'));

  { Any stays refused, and it is the control for the whole table: without a
    still-unbundled entry, "the table is right" would be indistinguishable
    from "the table accepts everything". }
  Check('Any is STILL not bundled',
    WellKnownPascalClass('google.protobuf.Any') = '');
  Check('a user type is not mistaken for well-known',
    WellKnownPascalClass('myapp.Timestamp') = '');

  { And through the parser, not only the table. }
  F := Parse(
    'syntax = "proto3";'#10 +
    'package t;'#10 +
    'import "google/protobuf/struct.proto";'#10 +
    'message M {'#10 +
    '  google.protobuf.Struct    s = 1;'#10 +
    '  google.protobuf.Value     v = 2;'#10 +
    '  google.protobuf.ListValue l = 3;'#10 +
    '  google.protobuf.NullValue n = 4;'#10 +
    '}'#10);
  try
    M := F.FindMessage('M');
    Check('the Struct family parses as fields', (M <> nil) and (M.Fields.Count = 4));
    if M <> nil then
      Check('  each kept as a type reference, not a scalar',
        (M.Fields[0].Scalar = psNone) and (M.Fields[3].Scalar = psNone));
  finally
    F.Free;
  end;
end;

// ── 06 · the refusal corpus ─────────────────────────────────────────────────

procedure TestRefusals;
const
  HDR = 'syntax = "proto3";'#10'package t;'#10;
begin
  Section('06  unsupported features must be refused, WITH a reason');

  ExpectRefusal('sint32',
    HDR + 'message M { sint32 v = 1; }', 'sint32');
  ExpectRefusal('sint64',
    HDR + 'message M { sint64 v = 1; }', 'sint64');
  ExpectRefusal('fixed32',
    HDR + 'message M { fixed32 v = 1; }', 'fixed32');
  ExpectRefusal('fixed64',
    HDR + 'message M { fixed64 v = 1; }', 'fixed64');
  ExpectRefusal('sfixed32',
    HDR + 'message M { sfixed32 v = 1; }', 'sfixed32');
  ExpectRefusal('sfixed64',
    HDR + 'message M { sfixed64 v = 1; }', 'sfixed64');

  { `map` itself is now ACCEPTED (MAP-1, section 09). What stays refused are
    the shapes proto3 does not allow. }
  ExpectRefusal('labelled map',
    HDR + 'message M { repeated map<string, int32> m = 1; }', 'map');
  ExpectRefusal('map with a float key',
    HDR + 'message M { map<double, int32> m = 1; }', 'map key');
  ExpectRefusal('map with a bytes key',
    HDR + 'message M { map<bytes, int32> m = 1; }', 'map key');
  { `oneof` itself is now ACCEPTED (ONEOF-1, section 08). What stays refused
    are the shapes proto3 does not allow inside one, plus the message-member
    case the generator cannot represent. }
  ExpectRefusal('repeated inside oneof',
    HDR + 'message M { oneof pick { repeated int32 a = 1; } }', 'repeated');
  ExpectRefusal('optional inside oneof',
    HDR + 'message M { oneof pick { optional int32 a = 1; } }', 'optional');
  ExpectRefusal('nested oneof',
    HDR + 'message M { oneof p { oneof q { int32 a = 1; } } }', 'oneof');
  ExpectRefusal('empty oneof',
    HDR + 'message M { oneof pick { } }', 'empty');
  { `optional` USED to be refused here. PRESENCE-1 gave the serializer a
    has-bit, so it is now accepted — see section 07. What remains refused is
    `optional repeated`, which is not legal proto3 in the first place. }
  ExpectRefusal('optional repeated',
    HDR + 'message M { optional repeated int32 v = 1; }', 'optional repeated');

  ExpectRefusal('required (proto2)',
    HDR + 'message M { required int32 v = 1; }', 'required');
  ExpectRefusal('group (proto2)',
    HDR + 'message M { group G = 1 { int32 a = 1; } }', 'group');

  ExpectRefusal('proto2 syntax',
    'syntax = "proto2";'#10'package t;'#10, 'proto2');

  { Only the UNBUNDLED well-known types are refused now. STRUCT-1 moved Struct
    OUT of this list - it used to be the example here - so Api takes its place
    as the cheapest one to state. The bundled ones are asserted accepted in
    TestWellKnown, and both halves matter: a table like this fails silently in
    either direction. }
  ExpectRefusal('well-known type (not bundled)',
    HDR + 'message M { google.protobuf.Api a = 1; }',
    'google.protobuf.Api');

  ExpectRefusal('well-known Any (dynamic typing)',
    HDR + 'message M { google.protobuf.Any a = 1; }',
    'google.protobuf.Any');

  { The rpc-type check, which did not exist before the well-known split. }
  ExpectRefusal('unbundled well-known type as an rpc response',
    HDR + 'message Q { int32 a = 1; }'#10 +
    'service S { rpc Go (Q) returns (google.protobuf.Any); }',
    'google.protobuf.Any');

  { Nested declarations are no longer refused — see TestNesting. Left as a
    comment rather than deleted so the change is visible to anyone diffing
    this corpus against the plan's 6.1 table. }

  ExpectRefusal('duplicate field number',
    HDR + 'message M { int32 a = 1; int32 b = 1; }', '1');

  ExpectRefusal('field number 0',
    HDR + 'message M { int32 a = 0; }', '0');

  ExpectRefusal('reserved 19000 range',
    HDR + 'message M { int32 a = 19500; }', '19500');

  ExpectRefusal('enum first value not zero',
    HDR + 'enum E { E_ONE = 1; }', 'E');

  ExpectRefusal('missing syntax statement',
    'package t;'#10'message M { int32 a = 1; }', 'syntax');
end;

// ── 07  proto3 `optional` is now ACCEPTED (PRESENCE-1) ──────────────────────

procedure TestOptionalAccepted;
const
  { TestRefusals declares its own HDR as a LOCAL const, so it is not visible
    here. Duplicated rather than hoisted to file scope: the two procedures are
    independent, and a shared header would let an edit for one silently change
    what the other is parsing. }
  HDR = 'syntax = "proto3";'#10'package t;'#10;
var
  LFile: TProtoFileNode;
  LMsg: TProtoMessageNode;
begin
  Section('07  `optional` accepted and labelled (PRESENCE-1)');

  LFile := Parse(HDR +
    'enum Colour { C_UNSET = 0; C_RED = 1; }'#10 +
    'message Inner { int32 id = 1; }'#10 +
    'message M {'#10 +
    '  int32 plain = 1;'#10 +
    '  optional int32 opt = 2;'#10 +
    '  optional string s = 3;'#10 +
    '  optional Colour col = 4;'#10 +
    '  repeated int32 ids = 5;'#10 +
    '  Inner inner = 6;'#10 +
    '}');
  try
    LMsg := LFile.FindMessage('M');
    Check('message M parsed', LMsg <> nil);
    if LMsg = nil then Exit;

    Check('6 fields', LMsg.Fields.Count = 6,
      IntToStr(LMsg.Fields.Count));

    { The label is the whole point - a parser that accepted the keyword and
      then dropped it on the floor would pass a bare "it parsed" check while
      generating a field with no presence at all. }
    Check('plain is plNone',    LMsg.Fields[0].FieldLabel = plNone);
    Check('opt is plOptional',  LMsg.Fields[1].FieldLabel = plOptional);
    Check('s is plOptional',    LMsg.Fields[2].FieldLabel = plOptional);
    Check('col is plOptional',  LMsg.Fields[3].FieldLabel = plOptional);
    Check('ids is plRepeated',  LMsg.Fields[4].FieldLabel = plRepeated);
    Check('inner is plNone',    LMsg.Fields[5].FieldLabel = plNone);

    Check('optional did not disturb the field number',
      LMsg.Fields[1].Number = 2);
    Check('optional did not disturb the type',
      LMsg.Fields[1].Scalar = psInt32);
  finally
    LFile.Free;
  end;

  { An `optional` MESSAGE field parses fine here on purpose: psNone means only
    "not a built-in scalar", and the parser cannot tell a message reference
    from an enum one - nor resolve a forward reference at all. The emitter
    makes that distinction, with the whole file in hand. Refusing it here
    would also have rejected `optional Colour`, which is valid. }
  LFile := Parse(HDR +
    'message Inner { int32 id = 1; }'#10 +
    'message M { optional Inner inner = 1; }');
  try
    Check('`optional <message>` parses (emitter refuses it, not the parser)',
      LFile.FindMessage('M') <> nil);
  finally
    LFile.Free;
  end;
end;

// ── 08  proto3 `oneof` is ACCEPTED and members are grouped (ONEOF-1) ────────

procedure TestOneofAccepted;
const
  HDR = 'syntax = "proto3";'#10'package t;'#10;
var
  LFile: TProtoFileNode;
  LMsg: TProtoMessageNode;
begin
  Section('08  `oneof` accepted, members hoisted and grouped (ONEOF-1)');

  LFile := Parse(HDR +
    'message M {'#10 +
    '  int32 plain = 1;'#10 +
    '  oneof pick {'#10 +
    '    int32  a = 2;'#10 +
    '    string b = 3;'#10 +
    '  }'#10 +
    '  int32 after = 4;'#10 +
    '}');
  try
    LMsg := LFile.FindMessage('M');
    Check('message M parsed', LMsg <> nil);
    if LMsg = nil then Exit;

    { Members are HOISTED into the ordinary field list, because that is what
      they are on the wire - a oneof has no framing of its own. }
    Check('4 fields, members hoisted alongside ordinary ones',
      LMsg.Fields.Count = 4, IntToStr(LMsg.Fields.Count));

    Check('plain is not in a oneof',  not LMsg.Fields[0].InOneof);
    Check('a is in oneof "pick"',     LMsg.Fields[1].OneofName = 'pick');
    Check('b is in oneof "pick"',     LMsg.Fields[2].OneofName = 'pick');
    Check('after is not in a oneof',  not LMsg.Fields[3].InOneof);

    { Field numbers and types must survive the grouping untouched - a member
      is an ordinary field that happens to carry a group name. }
    Check('member keeps its field number', LMsg.Fields[1].Number = 2);
    Check('member keeps its type',         LMsg.Fields[1].Scalar = psInt32);
    Check('field after the oneof keeps its number',
      LMsg.Fields[3].Number = 4);

    { A oneof member carries no label: plNone, not plOptional. The presence
      comes from being in a oneof, not from a keyword. }
    Check('member label is plNone', LMsg.Fields[1].FieldLabel = plNone);
  finally
    LFile.Free;
  end;

  // two independent groups in one message
  LFile := Parse(HDR +
    'message M {'#10 +
    '  oneof first  { int32 a = 1; }'#10 +
    '  oneof second { int32 b = 2; }'#10 +
    '}');
  try
    LMsg := LFile.FindMessage('M');
    Check('two oneof groups parse', LMsg <> nil);
    if LMsg <> nil then
    begin
      Check('first group name',  LMsg.Fields[0].OneofName = 'first');
      Check('second group name', LMsg.Fields[1].OneofName = 'second');
    end;
  finally
    LFile.Free;
  end;
end;

// ── 09  proto3 `map` synthesises an entry message (MAP-1) ───────────────────

procedure TestMapAccepted;
const
  HDR = 'syntax = "proto3";'#10'package t;'#10;
var
  LFile: TProtoFileNode;
  LMsg, LEntry: TProtoMessageNode;
begin
  Section('09  `map` accepted, entry message synthesised (MAP-1)');

  LFile := Parse(HDR +
    'message M {'#10 +
    '  int32 before = 1;'#10 +
    '  map<string, int32> labels = 2;'#10 +
    '  int32 after = 3;'#10 +
    '}');
  try
    LMsg := LFile.FindMessage('M');
    Check('message M parsed', LMsg <> nil);
    if LMsg = nil then Exit;

    { The map became an ORDINARY repeated message field - which is what a
      proto3 map is on the wire, so nothing below the parser needs to know. }
    Check('3 fields', LMsg.Fields.Count = 3, IntToStr(LMsg.Fields.Count));
    Check('the map field is repeated',   LMsg.Fields[1].IsRepeated);
    Check('the map field is flagged',    LMsg.Fields[1].IsMap);
    Check('a plain field is not flagged', not LMsg.Fields[0].IsMap);
    Check('the map keeps its number',    LMsg.Fields[1].Number = 2);
    Check('fields after it keep theirs', LMsg.Fields[2].Number = 3);

    { The synthesised entry, hoisted to file scope with a qualified name -
      the same shape a nested message gets, so no new naming rule is needed
      and two maps in different messages cannot collide. }
    LEntry := LFile.FindMessage('M.LabelsEntry');
    Check('entry message synthesised and hoisted', LEntry <> nil);
    Check('the field names the entry type',
      LMsg.Fields[1].TypeName = 'M.LabelsEntry', LMsg.Fields[1].TypeName);
    if LEntry <> nil then
    begin
      Check('entry has exactly key and value', LEntry.Fields.Count = 2);
      Check('key is field 1',
        (LEntry.Fields[0].Name = 'key') and (LEntry.Fields[0].Number = 1)
        and (LEntry.Fields[0].Scalar = psString));
      Check('value is field 2',
        (LEntry.Fields[1].Name = 'value') and (LEntry.Fields[1].Number = 2)
        and (LEntry.Fields[1].Scalar = psInt32));
    end;
  finally
    LFile.Free;
  end;

  // a message-valued map, and two maps in one message
  LFile := Parse(HDR +
    'message Inner { int32 id = 1; }'#10 +
    'message M {'#10 +
    '  map<string, Inner> a = 1;'#10 +
    '  map<int32,  string> b = 2;'#10 +
    '}');
  try
    LMsg := LFile.FindMessage('M');
    Check('two maps in one message parse', LMsg <> nil);
    Check('both entries synthesised',
      (LFile.FindMessage('M.AEntry') <> nil)
      and (LFile.FindMessage('M.BEntry') <> nil));
    LEntry := LFile.FindMessage('M.AEntry');
    if LEntry <> nil then
      Check('a message-valued map keeps the value type reference',
        LEntry.Fields[1].TypeName = 'Inner', LEntry.Fields[1].TypeName);
  finally
    LFile.Free;
  end;
end;

// ── main ────────────────────────────────────────────────────────────────────

begin
  try
    WriteLn('ProtogenParserTests - C1 gate (plans/horse-grpc-codegen.md)');

    TestGreeter;
    TestEcho;
    TestSupportedExtras;
    TestNesting;
    TestWellKnown;
    TestRefusals;
    TestOptionalAccepted;
    TestOneofAccepted;
    TestMapAccepted;

    WriteLn;
    WriteLn(Format('[Protogen] %d passed, %d failed', [GPass, GFail]));
    if GFail > 0 then
    begin
      WriteLn('[Protogen] Some tests FAILED.');
      ExitCode := 1;
    end
    else
      WriteLn('[Protogen] All tests PASSED.');
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, 'FATAL: ', E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;

  WriteLn;
  Write('Press ENTER to exit...');
  ReadLn;
end.
