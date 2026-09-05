program ProtogenInterfaceTests;

// ============================================================================
//  ProtogenInterfaceTests — the C3 gate from plans/horse-grpc-codegen.md.
//
//  Tests TInterfacesEmitter and TServiceSkeletonEmitter from
//  Protogen.ServiceEmitter.
//
//  GUID tests: GuidFromServiceName is deterministic, format-correct, and
//  unique across different service names.
//
//  EMIT GATE (greeter interfaces): parses the REAL greeter.proto and compares
//  against the REAL hand-written Sample.Greeter.Interfaces.pas, both read from
//  the sibling horse-provider-nghttp2 checkout. It previously compared against
//  an inlined transcription, which could only prove the emitter agreed with a
//  copy of what someone believed that file said — the same self-referential
//  weakness found in the C2 gate, and in the parser before it.
//
//  The GUID is masked on both sides before comparing. That is required, not a
//  convenience: the hand-written file carries an arbitrary hand-picked GUID
//  and the emitter derives one by hash (§6.3), so the two can never be equal
//  and neither is wrong. Determinism — which is what §6.3 actually requires —
//  is asserted separately, and the emitted GUID is re-checked after masking.
//  Both sides are also asserted to HAVE had a GUID masked, so the comparison
//  cannot pass because neither matched the pattern.
//
//  Missing sibling checkout → SKIP, counted separately, exit code 2 with
//  GATE INCOMPLETE. A skip must never read as a pass.
//
//  Normalization is three steps: strip comments (keeping {$...} directives),
//  collapse whitespace runs, then remove whitespace adjacent to Pascal
//  punctuation. The third exists because the hand-written file column-aligns
//  its method names — `function Echo (const ...)` against `function Greet(` —
//  and CollapseWS reduces runs but never removes a lone space. A generator
//  should not reproduce hand alignment, so that space is formatting, not
//  structure.
//
//  Still compared against inline expectations, because no ground truth file
//  exists for either: the ECHO interfaces (there is no
//  Sample.Echo.Interfaces.pas) and the service SKELETON (the real
//  Sample.Greeter.Service.pas contains implementations, not stubs).
//
//  Build (FPC trunk):
//    fpc -MDelphi -O1 -Fu. ProtogenInterfaceTests.dpr
//  Build (Windows):
//    dcc64 -CC -B -U. ProtogenInterfaceTests.dpr
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
  Protogen.Parser,
  Protogen.Emitter,
  Protogen.ServiceEmitter;

var
  GPass: Integer = 0;
  GFail: Integer = 0;
  GSkip: Integer = 0;

procedure Section(const S: string);
begin
  WriteLn;
  WriteLn('-- ', S);
end;

procedure Check(const AName: string; APassed: Boolean;
  const ADetail: string = '');
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

// A skipped gate is NOT a passed gate — counted separately, printed as SKIP,
// and forces a distinct exit code.
procedure Skip(const AName, AReason: string);
begin
  WriteLn('  SKIP  ', AName, '  [', AReason, ']');
  Inc(GSkip);
end;

// ── Helpers ──────────────────────────────────────────────────────────────────

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

function EmitIface(AFile: TProtoFileNode;
  const AUnitPrefix: string): string;
var
  LE: TInterfacesEmitter;
  LL: TStringList;
begin
  LL := TStringList.Create;
  LE := TInterfacesEmitter.Create;
  try
    LE.Emit(AFile, AUnitPrefix, LL);
    Result := LL.Text;
  finally
    LE.Free;
    LL.Free;
  end;
end;

function EmitReg(AFile: TProtoFileNode;
  const AUnitPrefix: string): string;
var
  LE: TRegistrationEmitter;
  LL: TStringList;
begin
  LL := TStringList.Create;
  LE := TRegistrationEmitter.Create;
  try
    LE.Emit(AFile, AUnitPrefix, LL);
    Result := LL.Text;
  finally
    LE.Free;
    LL.Free;
  end;
end;

function EmitSkel(AFile: TProtoFileNode;
  const AUnitPrefix: string): string;
var
  LE: TServiceSkeletonEmitter;
  LL: TStringList;
begin
  LL := TStringList.Create;
  LE := TServiceSkeletonEmitter.Create;
  try
    LE.Emit(AFile, AUnitPrefix, LL);
    Result := LL.Text;
  finally
    LE.Free;
    LL.Free;
  end;
end;

// Normalize: strip comments then collapse whitespace — same rules as C2 test.
// StripComments: keep {$...} directives, strip { } block comments and
// (* *) star comments and // line comments.

function StripComments(const S: string): string;
var
  I: Integer;
  InLC, InBlock, InStar, InStr: Boolean;
  // LC = line comment; 'InLine' is a Delphi reserved word so we use InLC.
  // InStr tracks Pascal string literals so { } inside 'strings' are not
  // treated as block comments — without this, a GUID literal like
  // '{B8E23A31-...}' would be stripped entirely.
  Ch, Next: Char;
begin
  Result := '';
  I := 1;
  InLC := False; InBlock := False; InStar := False; InStr := False;
  while I <= Length(S) do
  begin
    Ch := S[I];
    if I < Length(S) then Next := S[I + 1] else Next := #0;

    if InStr then
    begin
      // Inside a string literal: pass everything through, but handle
      // '' (escaped quote) and the closing quote.
      if Ch = '''' then
      begin
        if Next = '''' then
        begin
          Result := Result + Ch + Next; // emit both chars of ''
          Inc(I, 2);
        end
        else
        begin
          Result := Result + Ch; // closing quote
          InStr := False;
          Inc(I);
        end;
      end
      else
      begin
        Result := Result + Ch;
        Inc(I);
      end;
    end
    else if InLC then
    begin
      if Ch = #10 then InLC := False;
      Inc(I);
    end
    else if InBlock then
    begin
      if Ch = '}' then InBlock := False;
      Inc(I);
    end
    else if InStar then
    begin
      if (Ch = '*') and (Next = ')') then
      begin
        InStar := False;
        Inc(I, 2);
      end
      else
        Inc(I);
    end
    else if Ch = '''' then
    begin
      // Start of a string literal
      InStr := True;
      Result := Result + Ch;
      Inc(I);
    end
    else if (Ch = '/') and (Next = '/') then
    begin
      InLC := True;
      Inc(I, 2);
    end
    else if (Ch = '(') and (Next = '*') then
    begin
      InStar := True;
      Inc(I, 2);
    end
    else if Ch = '{' then
    begin
      if Next = '$' then
      begin
        // Compiler directive — keep verbatim
        Result := Result + Ch;
        Inc(I);
      end
      else
      begin
        // Block comment — consume to matching '}'
        InBlock := True;
        Inc(I);
      end;
    end
    else
    begin
      Result := Result + Ch;
      Inc(I);
    end;
  end;
end;

function CollapseWS(const S: string): string;
var
  I: Integer;
  WS: Boolean;
  Ch: Char;
begin
  Result := '';
  WS := True; // leading whitespace trimmed
  for I := 1 to Length(S) do
  begin
    Ch := S[I];
    if (Ch = ' ') or (Ch = #9) or (Ch = #10) or (Ch = #13) then
    begin
      if not WS then
      begin
        Result := Result + ' ';
        WS := True;
      end;
    end
    else
    begin
      Result := Result + Ch;
      WS := False;
    end;
  end;
  while (Length(Result) > 0) and (Result[Length(Result)] = ' ') do
    SetLength(Result, Length(Result) - 1);
end;

function IsPascalPunct(C: Char): Boolean;
begin
  case C of
    '(', ')', '[', ']', ':', ';', ',', '.': Result := True;
  else
    Result := False;
  end;
end;

// Removes whitespace immediately adjacent to Pascal punctuation.
//
// CollapseWS reduces whitespace RUNS to a single space but never removes a
// lone one, so a hand-written file's column alignment survives it. The real
// Sample.Greeter.Interfaces.pas aligns its method names:
//
//     function Greet(const ARequest: TGreetRequest): TGreetResponse;
//     function Echo (const ARequest: TEchoRequest):  TEchoResponse;
//
// That single space before '(' is formatting, not structure, and a generator
// should not reproduce hand alignment. The gate's contract is "identical
// modulo comments and whitespace" — this step is what makes the whitespace
// half of that actually true.
//
// It is deliberately blind to string literals, matching CollapseWS's existing
// behaviour. Nothing in a generated unit has a literal whose meaning depends
// on a space beside punctuation, and keeping the two steps consistent is
// worth more here than a precision neither of them currently has.
function TightenPunctuation(const S: string): string;
var
  I: Integer;
  Ch: Char;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    Ch := S[I];
    if Ch = ' ' then
    begin
      if (Length(Result) > 0) and IsPascalPunct(Result[Length(Result)]) then
        Continue;
      if (I < Length(S)) and IsPascalPunct(S[I + 1]) then
        Continue;
    end;
    Result := Result + Ch;
  end;
end;

function Normalize(const S: string): string;
begin
  Result := TightenPunctuation(CollapseWS(StripComments(S)));
end;

// ── Ground truth on disk ─────────────────────────────────────────────────────
//
// Only the GREETER interfaces unit has a hand-written original to compare
// against, and it lives in the sibling horse-provider-nghttp2 checkout:
//   horse-provider-nghttp2/samples/grpc/Sample.Greeter.Interfaces.pas
// Override with PROTOGEN_GREETER_DIR. Missing → SKIP + exit 2, never a pass.
//
// Two comparisons deliberately stay inline, because no ground truth exists:
//   - Echo interfaces: there is no Sample.Echo.Interfaces.pas anywhere.
//   - The service skeleton: the real Sample.Greeter.Service.pas holds actual
//     implementations (ListGreetings builds five messages, ChatGreetings
//     echoes as it reads), so it is not a skeleton and cannot be diffed
//     against one.
// ─────────────────────────────────────────────────────────────────────────────

function ExeDir: string;
begin
  Result := ExtractFilePath(ParamStr(0));
end;

function Join(const A, B: string): string;
begin
  Result := IncludeTrailingPathDelimiter(A) + B;
end;

function GreeterDir: string;
const
  REL = '..' + PathDelim + '..' + PathDelim + '..' + PathDelim +
        'horse-provider-nghttp2' + PathDelim + 'samples' + PathDelim + 'grpc';
var
  LEnv: string;
begin
  LEnv := GetEnvironmentVariable('PROTOGEN_GREETER_DIR');
  if (LEnv <> '') and FileExists(Join(LEnv, 'greeter.proto')) then
    Exit(LEnv);
  if FileExists(Join(Join(ExeDir, REL), 'greeter.proto')) then
    Exit(Join(ExeDir, REL));
  if FileExists(Join(Join(GetCurrentDir, REL), 'greeter.proto')) then
    Exit(Join(GetCurrentDir, REL));
  Result := '';
end;

// Strips a UTF-8 BOM in both its 3-byte (FPC/AnsiString) and single-#$FEFF
// (Delphi/Unicode) forms — invisible in an editor, but it survives Normalize
// and would fail the comparison on its own.
function ReadFileText(const APath: string): string;
var
  LList: TStringList;
begin
  LList := TStringList.Create;
  try
    LList.LoadFromFile(APath);
    Result := LList.Text;
  finally
    LList.Free;
  end;
  if (Length(Result) >= 3) and (Ord(Result[1]) = $EF) and
     (Ord(Result[2]) = $BB) and (Ord(Result[3]) = $BF) then
    Delete(Result, 1, 3)
  else if (Length(Result) >= 1) and (Ord(Result[1]) = $FEFF) then
    Delete(Result, 1, 1);
end;

// Replaces the interface GUID literal with a fixed placeholder.
//
// This is a REQUIRED normalization, not a convenience. The hand-written
// Sample.Greeter.Interfaces.pas carries an arbitrary GUID chosen by hand;
// the emitter derives one deterministically from the service name (§6.3,
// FNV-1a). They will never be equal, and neither is wrong — RTTI dispatch
// only requires that a GUID be present and stable. What §6.3 actually
// demands is determinism, which TestGuidDeterministic asserts directly, and
// TestEmitInterfacesGreeter re-asserts the emitted value below. Masking here
// lets every OTHER difference in the unit surface instead of being buried
// under a diff that can never be resolved.
function MaskGuid(const S: string): string;
var
  LStart, LEnd: Integer;
begin
  Result := S;
  LStart := Pos('[''{', Result);
  if LStart = 0 then
    Exit;
  LEnd := Pos('}'']', Result);
  if (LEnd = 0) or (LEnd < LStart) then
    Exit;
  Result := Copy(Result, 1, LStart - 1) + '[<GUID>]' +
            Copy(Result, LEnd + 3, MaxInt);
end;

// Offset of the first divergence plus a window either side — a raw dump of two
// multi-kilobyte strings does not locate a defect.
function FirstDifference(const AExpected, AGot: string): string;
var
  I, LMin, LFrom: Integer;
begin
  LMin := Length(AExpected);
  if Length(AGot) < LMin then
    LMin := Length(AGot);
  I := 1;
  while (I <= LMin) and (AExpected[I] = AGot[I]) do
    Inc(I);
  if (I > LMin) and (Length(AExpected) = Length(AGot)) then
    Exit('identical');
  LFrom := I - 40;
  if LFrom < 1 then
    LFrom := 1;
  Result := Format('diverges at %d of %d/%d'#10 +
                   '    hand-written: ...%s...'#10 +
                   '    emitted     : ...%s...',
    [I, Length(AExpected), Length(AGot),
     Copy(AExpected, LFrom, 100), Copy(AGot, LFrom, 100)]);
end;

// ── Proto source constants ───────────────────────────────────────────────────

const
  ECHO_PROTO =
    'syntax = "proto3"; package echo;' +
    'message SayRequest { string name = 1; }' +
    'message SayResponse { string message = 1; int32 length = 2; }' +
    'service Echo { rpc Say (SayRequest) returns (SayResponse); }';

  // NOTE: this inline schema carries only the two UNARY rpcs. The real
  // greeter.proto also declares ListGreetings (server-streaming), JoinNames
  // (client-streaming) and ChatGreetings (bidi).
  //
  // TestEmitInterfacesGreeter no longer uses this — it parses the real file,
  // so it genuinely exercises the emitter's skip-streaming behaviour, which
  // this constant never could.
  //
  // TestEmitSkeletonGreeter still uses it, deliberately: the expected
  // skeleton below has no streaming stubs because the emitter does not yet
  // produce any. C5 must switch this test to the real .proto and extend
  // GREETER_SKELETON_NORM with the three streaming signatures at the same
  // time — doing one without the other turns the gate red for the wrong
  // reason.
  GREETER_PROTO =
    'syntax = "proto3"; package greeter;' +
    'service Greeter {' +
    '  rpc Greet (GreetRequest) returns (GreetResponse);' +
    '  rpc Echo  (EchoRequest)  returns (EchoResponse);' +
    '}' +
    'message GreetRequest { string name = 1; }' +
    'message GreetResponse { string message = 1; }' +
    'message EchoRequest  { int32 i32 = 1; int64 i64 = 2; bool b = 3;' +
    '  string s = 4; float f32 = 5; double f64 = 6; }' +
    'message EchoResponse { int32 i32 = 1; int64 i64 = 2; bool b = 3;' +
    '  string s = 4; float f32 = 5; double f64 = 6; }';

// ── Expected normalized output — skeleton (static, no GUIDs) ────────────────

const
  GREETER_SKELETON_NORM =
    'unit Sample.Greeter.Service;' +
    ' {$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}' +
    ' interface' +
    ' uses' +
    ' {$IF DEFINED(FPC)}' +
    ' SysUtils,' +
    ' {$ELSE}' +
    ' System.SysUtils,' +
    ' {$IFEND}' +
    ' Sample.Greeter.Interfaces,' +
    ' Sample.Greeter.Messages;' +
    ' type' +
    ' TGreeterServiceImpl = class(TInterfacedObject, IGreeter)' +
    ' public' +
    ' function Greet(const ARequest: TGreetRequest): TGreetResponse;' +
    ' function Echo(const ARequest: TEchoRequest): TEchoResponse;' +
    ' end;' +
    ' implementation' +
    ' function TGreeterServiceImpl.Greet(const ARequest: TGreetRequest): TGreetResponse;' +
    ' begin raise ENotImplemented.Create(''TGreeterServiceImpl.Greet''); end;' +
    ' function TGreeterServiceImpl.Echo(const ARequest: TEchoRequest): TEchoResponse;' +
    ' begin raise ENotImplemented.Create(''TGreeterServiceImpl.Echo''); end;' +
    ' end.';

// ── Tests ─────────────────────────────────────────────────────────────────────

procedure TestGuidFormat;
var
  G: string;
  OK: Boolean;
begin
  Section('GuidFromServiceName: format');
  G := TInterfacesEmitter.GuidFromServiceName('greeter.Greeter');
  Check('length = 38',       Length(G) = 38);
  Check('starts with {',     (Length(G) > 0) and (G[1] = '{'));
  Check('ends with }',       (Length(G) > 0) and (G[Length(G)] = '}'));
  // dashes at positions 10, 15, 20, 25 (1-based)
  OK := (Length(G) >= 25) and (G[10] = '-') and (G[15] = '-')
    and (G[20] = '-') and (G[25] = '-');
  Check('dashes in GUID positions', OK);
end;

procedure TestGuidDeterministic;
var
  G1, G2: string;
begin
  Section('GuidFromServiceName: determinism and uniqueness');
  G1 := TInterfacesEmitter.GuidFromServiceName('greeter.Greeter');
  G2 := TInterfacesEmitter.GuidFromServiceName('greeter.Greeter');
  Check('same input -> same output', G1 = G2);
  G2 := TInterfacesEmitter.GuidFromServiceName('echo.Echo');
  Check('different services -> different GUIDs', G1 <> G2);
  G2 := TInterfacesEmitter.GuidFromServiceName('Greeter');
  Check('package prefix is significant', G1 <> G2);
end;

procedure TestNaming;
begin
  Section('InterfaceName / ImplClassName');
  Check('InterfaceName Greeter',  TInterfacesEmitter.InterfaceName('Greeter')  = 'IGreeter');
  Check('InterfaceName Echo',     TInterfacesEmitter.InterfaceName('Echo')     = 'IEcho');
  Check('ImplClassName Greeter',  TInterfacesEmitter.ImplClassName('Greeter')  = 'TGreeterServiceImpl');
  Check('ImplClassName Echo',     TInterfacesEmitter.ImplClassName('Echo')     = 'TEchoServiceImpl');
end;

procedure TestEmitInterfacesEcho;
var
  LFile: TProtoFileNode;
  LGot, LGuid, LExpected: string;
begin
  Section('Emit: echo.proto interfaces');
  LFile := nil;
  try
    LFile := Parse(ECHO_PROTO);
    Check('echo parse ok', LFile <> nil);
    if LFile = nil then Exit;
    LGuid := TInterfacesEmitter.GuidFromServiceName('echo.Echo');
    LExpected :=
      'unit Sample.Echo.Interfaces;' +
      ' {$M+}' +
      ' {$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}' +
      ' interface' +
      ' {$IF DEFINED(FPC)}' +
      ' {$RTTI EXPLICIT PROPERTIES([vcPublished]) FIELDS([vcPublic]) METHODS([vcPublic])}' +
      ' {$ENDIF}' +
      ' uses' +
      ' Nghttp2.Grpc.Attributes,' +
      ' Sample.Echo.Messages;' +
      ' type' +
      ' [TGrpcService(''echo.Echo'')]' +
      ' IEcho = interface(IInvokable)' +
      ' [''' + LGuid + ''']' +
      ' function Say(const ARequest: TSayRequest): TSayResponse;' +
      ' end;' +
      ' implementation' +
      ' end.';
    LGot := Normalize(EmitIface(LFile, 'Sample.Echo'));
    // The inline expectation is written for human legibility, so it carries
    // spaces beside punctuation that Normalize now removes from the emitted
    // side. Put it through the same step rather than un-spacing the literal.
    Check('echo interfaces normalize match',
      LGot = TightenPunctuation(LExpected), LGot);
  finally
    LFile.Free;
  end;
end;

// The C3 gate proper: parse the REAL greeter.proto and compare the emitted
// interfaces unit against the REAL hand-written Sample.Greeter.Interfaces.pas.
//
// This previously compared against an inlined transcription of that file,
// which could only prove the emitter agreed with a copy of what someone
// believed the file said — the same self-referential weakness found in the C2
// gate on 2026-09-05, and in the parser before that.
procedure TestEmitInterfacesGreeter;
var
  LFile: TProtoFileNode;
  LDir, LProtoPath, LPasPath, LGot, LWant, LGuid: string;
begin
  Section('Emit gate: greeter.proto interfaces');

  LDir := GreeterDir;
  if LDir = '' then
  begin
    Skip('greeter interfaces', 'sibling checkout not found; set PROTOGEN_GREETER_DIR');
    Exit;
  end;

  LProtoPath := Join(LDir, 'greeter.proto');
  LPasPath   := Join(LDir, 'Sample.Greeter.Interfaces.pas');
  WriteLn('  proto: ', LProtoPath);
  WriteLn('  pas  : ', LPasPath);

  if not FileExists(LPasPath) then
  begin
    Skip('greeter interfaces', 'Sample.Greeter.Interfaces.pas missing at ' + LPasPath);
    Exit;
  end;

  LFile := nil;
  try
    LFile := Parse(ReadFileText(LProtoPath));
    Check('greeter parse ok', LFile <> nil);
    if LFile = nil then Exit;

    LGot  := MaskGuid(Normalize(EmitIface(LFile, 'Sample.Greeter')));
    LWant := MaskGuid(Normalize(ReadFileText(LPasPath)));

    // Both sides must actually have had a GUID masked, or the comparison is
    // passing for the wrong reason — two strings that both failed to match
    // the pattern would compare equal on that point while proving nothing.
    Check('emitted unit carries a GUID literal', Pos('[<GUID>]', LGot) > 0);
    Check('hand-written unit carries a GUID literal', Pos('[<GUID>]', LWant) > 0);

    Check('greeter interfaces match hand-written Sample.Greeter.Interfaces.pas',
      LGot = LWant, FirstDifference(LWant, LGot));

    // §6.3: the emitted GUID must be the deterministic one. Masking above
    // removes it from the diff, so assert it here rather than losing it.
    LGuid := TInterfacesEmitter.GuidFromServiceName('greeter.Greeter');
    Check('emitted GUID is the deterministic one',
      Pos(LGuid, Normalize(EmitIface(LFile, 'Sample.Greeter'))) > 0, LGuid);
  finally
    LFile.Free;
  end;
end;

procedure TestEmitSkeletonGreeter;
var
  LFile: TProtoFileNode;
  LGot: string;
begin
  Section('Emit: greeter.proto skeleton');
  LFile := nil;
  try
    LFile := Parse(GREETER_PROTO);
    Check('greeter parse ok (skeleton)', LFile <> nil);
    if LFile = nil then Exit;
    LGot := Normalize(EmitSkel(LFile, 'Sample.Greeter'));
    Check('greeter skeleton normalize match',
      LGot = TightenPunctuation(GREETER_SKELETON_NORM), LGot);
  finally
    LFile.Free;
  end;
end;

// ── C5: streaming ────────────────────────────────────────────────────────────
//
// The skeleton and registration units have NO hand-written original to diff
// against — the real Sample.Greeter.Service.pas holds implementations, and no
// Registration unit has ever been written by hand. Rather than invent a
// transcription and compare generated output against a copy of itself (the
// weakness removed from the C2 and C3 gates), these assert the properties that
// actually matter: the exact signatures the registry's handler types demand,
// and the exact paths the dispatcher will route on.

// Asserts a normalized haystack contains a needle, tightening the needle the
// same way so it can be written readably here.
procedure CheckHas(const AName, AHaystack, ANeedle: string);
begin
  Check(AName, Pos(TightenPunctuation(ANeedle), AHaystack) > 0, ANeedle);
end;

procedure TestStreamingEmitters;
var
  LFile: TProtoFileNode;
  LDir, LSkel, LReg, LRegRaw: string;
begin
  Section('C5: streaming skeleton + registration (real greeter.proto)');

  LDir := GreeterDir;
  if LDir = '' then
  begin
    Skip('C5 streaming', 'sibling checkout not found; set PROTOGEN_GREETER_DIR');
    Exit;
  end;

  LFile := nil;
  try
    LFile := Parse(ReadFileText(Join(LDir, 'greeter.proto')));
    Check('greeter parse ok (streaming)', LFile <> nil);
    if LFile = nil then Exit;

    LSkel   := Normalize(EmitSkel(LFile, 'Sample.Greeter'));
    LRegRaw := EmitReg(LFile, 'Sample.Greeter');
    LReg    := Normalize(LRegRaw);

    // -- skeleton: signatures must match the registry handler types exactly.
    // The message parameters are TObject, NOT the concrete class: the method
    // pointer has to be assignment-compatible with TGrpcServerStreamHandler
    // and friends, and the dispatcher casts internally.
    CheckHas('skeleton: server-stream signature', LSkel,
      'procedure ListGreetings(const ARequest: TObject; const AWriter: IGrpcStreamWriter);');
    CheckHas('skeleton: client-stream signature', LSkel,
      'procedure JoinNames(const AReader: IGrpcStreamReader; const AResponse: TObject);');
    CheckHas('skeleton: bidi signature', LSkel,
      'procedure ChatGreetings(const AReader: IGrpcStreamReader; const AWriter: IGrpcStreamWriter);');

    // Unary methods keep their typed shape alongside the streaming ones.
    CheckHas('skeleton: unary still typed', LSkel,
      'function Greet(const ARequest: TGreetRequest): TGreetResponse;');

    // The stream interfaces live in Nghttp2.Grpc.Registry, so the unit must
    // pull it in — otherwise the skeleton does not compile.
    CheckHas('skeleton: uses Nghttp2.Grpc.Registry', LSkel,
      'Nghttp2.Grpc.Registry;');

    // Bodies are emitted for streaming methods too; a declared-but-unimplemented
    // method is a link error, which is the failure this guards against.
    CheckHas('skeleton: server-stream body', LSkel,
      'procedure TGreeterServiceImpl.ListGreetings(const ARequest: TObject; const AWriter: IGrpcStreamWriter);');
    CheckHas('skeleton: bidi body', LSkel,
      'procedure TGreeterServiceImpl.ChatGreetings(const AReader: IGrpcStreamReader; const AWriter: IGrpcStreamWriter);');

    // -- registration unit
    CheckHas('registration: unit name', LReg, 'unit Sample.Greeter.Registration;');
    // Checked against the RAW text, not the normalized text: this is a header
    // COMMENT, and Normalize strips comments. Asserting it through the
    // normalizer could never pass. It is worth asserting at all because it is
    // the warning that stops someone editing a file the next run overwrites.
    Check('registration: always-regenerated warning present',
      Pos('ALWAYS regenerated', LRegRaw) > 0);
    CheckHas('registration: proc signature', LReg,
      'procedure RegisterGreeter(const AImpl: TGreeterServiceImpl);');

    // Unary methods go through the interface in ONE call.
    CheckHas('registration: RegisterService for unary', LReg,
      'TGrpcRegistry.RegisterService<IGreeter>(AImpl);');

    // Streaming registered explicitly, with the dispatcher's exact paths.
    CheckHas('registration: server-stream call', LReg,
      'TGrpcRegistry.RegisterServerStream(''/greeter.Greeter/ListGreetings'', TGreetRequest, TGreetResponse, AImpl.ListGreetings);');
    CheckHas('registration: client-stream call', LReg,
      'TGrpcRegistry.RegisterClientStream(''/greeter.Greeter/JoinNames'', TGreetRequest, TGreetResponse, AImpl.JoinNames);');
    CheckHas('registration: bidi call', LReg,
      'TGrpcRegistry.RegisterBidiStream(''/greeter.Greeter/ChatGreetings'', TGreetRequest, TGreetResponse, AImpl.ChatGreetings);');

    // Streaming rpcs must NOT reach the interface — the dispatcher requires
    // function(const T): TResponse and a stream has no such shape.
    Check('interface excludes streaming rpcs',
      (Pos('ListGreetings', Normalize(EmitIface(LFile, 'Sample.Greeter'))) = 0) and
      (Pos('ChatGreetings', Normalize(EmitIface(LFile, 'Sample.Greeter'))) = 0));
  finally
    LFile.Free;
  end;
end;

// ── Main ──────────────────────────────────────────────────────────────────────

begin
  WriteLn('ProtogenInterfaceTests (C3 gate)');
  TestGuidFormat;
  TestGuidDeterministic;
  TestNaming;
  TestEmitInterfacesEcho;
  TestEmitInterfacesGreeter;
  TestEmitSkeletonGreeter;
  TestStreamingEmitters;
  WriteLn;
  WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed, ', GSkip, ' skipped');
  if GFail > 0 then
    ExitCode := 1
  else if GSkip > 0 then
  begin
    // Exit 2, not 0: it ran without failures but did not run every gate, so
    // it has not demonstrated what it exists to demonstrate.
    WriteLn('GATE INCOMPLETE - ', GSkip,
            ' comparison(s) skipped; this is not a pass.');
    ExitCode := 2;
  end
  else
    WriteLn('C3 gate complete: interfaces match the hand-written sample.');
end.
