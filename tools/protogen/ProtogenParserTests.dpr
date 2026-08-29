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
  WriteLn('── ', S);
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
        Check(ACaseName + ' — refused with EProtoParseError', False,
          'got ' + E.ClassName + ': ' + E.Message);
        Exit;
      end;
    end;
  finally
    LFile.Free;
  end;

  Check(ACaseName + ' — refused', LRaised);
  if not LRaised then Exit;

  Check(ACaseName + ' — names ' + QuotedStr(AMustMention),
    Pos(LowerCase(AMustMention), LowerCase(LMsg)) > 0, LMsg);

  Check(ACaseName + ' — explains, not just restates',
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
    '  // M6a — server-streaming.'#10 +
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
  Section('01  greeter.proto — the four RPC shapes');
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
  Section('02  echo.proto — comments, two services shapes');
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

// ── 04 · the refusal corpus ─────────────────────────────────────────────────

procedure TestRefusals;
const
  HDR = 'syntax = "proto3";'#10'package t;'#10;
begin
  Section('04  unsupported features must be refused, WITH a reason');

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

  ExpectRefusal('map',
    HDR + 'message M { map<string, int32> m = 1; }', 'map');
  ExpectRefusal('oneof',
    HDR + 'message M { oneof pick { int32 a = 1; } }', 'oneof');
  ExpectRefusal('optional',
    HDR + 'message M { optional int32 v = 1; }', 'optional');

  ExpectRefusal('required (proto2)',
    HDR + 'message M { required int32 v = 1; }', 'required');
  ExpectRefusal('group (proto2)',
    HDR + 'message M { group G = 1 { int32 a = 1; } }', 'group');

  ExpectRefusal('proto2 syntax',
    'syntax = "proto2";'#10'package t;'#10, 'proto2');

  ExpectRefusal('well-known type',
    HDR + 'message M { google.protobuf.Timestamp t = 1; }',
    'google.protobuf.Timestamp');

  ExpectRefusal('nested message',
    HDR + 'message M { message Inner { int32 a = 1; } }', 'nested');

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

// ── main ────────────────────────────────────────────────────────────────────

begin
  try
    WriteLn('ProtogenParserTests — C1 gate (plans/horse-grpc-codegen.md)');

    TestGreeter;
    TestEcho;
    TestSupportedExtras;
    TestRefusals;

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
