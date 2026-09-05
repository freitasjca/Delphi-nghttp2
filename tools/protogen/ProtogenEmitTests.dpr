program ProtogenEmitTests;

// ============================================================================
//  ProtogenEmitTests — the C2 gate from plans/horse-grpc-codegen.md.
//
//  Two purposes:
//
//  UNIT: exercise PascalFieldName / PascalScalarType / PascalTypeName /
//  PascalFieldType in isolation. These are the decision functions; getting
//  them wrong silently poisons every generated file.
//
//  EMIT GATE: parse the REAL echo.proto and greeter.proto, emit with
//  TMessagesEmitter, and compare against the REAL hand-written
//  Sample.Echo.Messages.pas and Sample.Greeter.Messages.pas, all read from
//  disk. A mismatch means generated code would differ from what has been
//  hand-verified against the live gRPC suite.
//
//  Normalization rules — kept IDENTICAL to ProtogenInterfaceTests (C3). If you
//  change one, change both; two gates comparing generated Pascal against
//  hand-written Pascal by different rules is how they start disagreeing about
//  what a difference even is:
//    - Strip '//' line comments (everything to end of line)
//    - Strip '{ }' block comments where the char after '{' is NOT '$'
//      (compiler directives like {$M+} are KEPT)
//    - Strip '(* *)' star comments
//    - Track string literals, so braces inside 'quoted text' are not mistaken
//      for a block comment and silently swallowed
//    - Collapse all whitespace runs to a single space
//    - Remove whitespace adjacent to Pascal punctuation, so a hand-written
//      file's column alignment does not read as a structural difference
//    - Trim leading/trailing whitespace
//
//  Build (FPC trunk):
//    fpc -MDelphi -O1 -Fu. ProtogenEmitTests.dpr
//  Build (Windows):
//    dcc32 -CC -B ProtogenEmitTests.dpr
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
  Protogen.Emitter;

var
  GPass: Integer = 0;
  GFail: Integer = 0;
  GSkip: Integer = 0;

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

// A skipped gate is NOT a passed gate. It is counted separately, printed on
// its own line, and forces a distinct exit code so no caller can mistake an
// unrun comparison for a successful one.
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

function EmitToString(AFile: TProtoFileNode;
  const AUnitPrefix, AProtoFile: string): string;
var
  LE: TMessagesEmitter;
  LL: TStringList;
begin
  LL := TStringList.Create;
  LE := TMessagesEmitter.Create;
  try
    LE.Emit(AFile, AUnitPrefix, AProtoFile, LL);
    Result := LL.Text;
  finally
    LE.Free;
    LL.Free;
  end;
end;

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

// ── Sample locations ─────────────────────────────────────────────────────────
//
// The gate compares against the REAL hand-written samples on disk, not against
// transcriptions of them. An earlier version of this test embedded both the
// .proto source and the expected Pascal as string constants; that made the
// gate self-referential — if a transcription drifted from the file it claimed
// to represent, the test passed while its claim was false. Same lesson the
// googleapis corpus run taught one layer down: a system validated only against
// its own inputs agrees with itself.
//
// The two samples do not live in the same repository:
//   echo.proto    + Sample.Echo.Messages.pas     — this repo, samples/grpc-server/
//   greeter.proto + Sample.Greeter.Messages.pas  — horse-provider-nghttp2, samples/grpc/
//
// Echo is in-repo and its absence is a defect, so a missing Echo file FAILS.
// Greeter depends on a sibling checkout that may legitimately not be present,
// so its absence SKIPS — but loudly, and the process exits 2, because a skip
// must never read as a pass.
//
// Override either directory with an environment variable:
//   PROTOGEN_ECHO_DIR, PROTOGEN_GREETER_DIR
// ─────────────────────────────────────────────────────────────────────────────

function ExeDir: string;
begin
  Result := ExtractFilePath(ParamStr(0));
end;

function Join(const A, B: string): string;
begin
  Result := IncludeTrailingPathDelimiter(A) + B;
end;

// Returns the first directory in which AProbeFile exists, or '' if none do.
function FindSampleDir(const AEnvVar, AProbeFile: string;
  const ACandidates: array of string): string;
var
  I: Integer;
  LEnv: string;
begin
  LEnv := GetEnvironmentVariable(AEnvVar);
  if (LEnv <> '') and FileExists(Join(LEnv, AProbeFile)) then
    Exit(LEnv);
  for I := Low(ACandidates) to High(ACandidates) do
    if FileExists(Join(ACandidates[I], AProbeFile)) then
      Exit(ACandidates[I]);
  Result := '';
end;

function EchoDir: string;
begin
  // Built in place (tools/protogen) or into a scratch dir beside the repo.
  Result := FindSampleDir('PROTOGEN_ECHO_DIR', 'echo.proto',
    [Join(ExeDir, '..' + PathDelim + '..' + PathDelim + 'samples' + PathDelim + 'grpc-server'),
     Join(GetCurrentDir, 'samples' + PathDelim + 'grpc-server'),
     Join(GetCurrentDir, '..' + PathDelim + '..' + PathDelim + 'samples' + PathDelim + 'grpc-server')]);
end;

function GreeterDir: string;
const
  REL = '..' + PathDelim + '..' + PathDelim + '..' + PathDelim +
        'horse-provider-nghttp2' + PathDelim + 'samples' + PathDelim + 'grpc';
begin
  Result := FindSampleDir('PROTOGEN_GREETER_DIR', 'greeter.proto',
    [Join(ExeDir, REL),
     Join(GetCurrentDir, REL)]);
end;

// Reads a text file whole. Strips a UTF-8 BOM if present: a BOM is invisible
// in an editor but would survive Normalize() and fail the comparison on its
// own, which has cost a diagnosis cycle before on a Horse patch.
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
// ── Tests ─────────────────────────────────────────────────────────────────────

procedure TestFieldName;
var
  LResult, LRenamed: string;
begin
  Section('PascalFieldName');
  LResult := TMessagesEmitter.PascalFieldName('name', LRenamed);
  Check('name unchanged',         LResult = 'name');
  Check('name: no rename',        LRenamed = '');

  LResult := TMessagesEmitter.PascalFieldName('message', LRenamed);
  Check('message -> text',        LResult = 'text');
  Check('message: LRenamed set',  LRenamed = 'message');

  LResult := TMessagesEmitter.PascalFieldName('string', LRenamed);
  Check('string -> str',          LResult = 'str');
  Check('string: LRenamed set',   LRenamed = 'string');

  LResult := TMessagesEmitter.PascalFieldName('type', LRenamed);
  Check('type -> type_',          LResult = 'type_');
  Check('type: LRenamed set',     LRenamed = 'type');

  LResult := TMessagesEmitter.PascalFieldName('var', LRenamed);
  Check('var -> var_',            LResult = 'var_');

  LResult := TMessagesEmitter.PascalFieldName('count', LRenamed);
  Check('count unchanged',        LResult = 'count');
  Check('count: no rename',       LRenamed = '');

  LResult := TMessagesEmitter.PascalFieldName('end', LRenamed);
  Check('end -> end_',            LResult = 'end_');
end;

procedure TestScalarType;
var
  LRaised: Boolean;
begin
  Section('PascalScalarType');
  Check('psInt32  -> Integer', TMessagesEmitter.PascalScalarType(psInt32)  = 'Integer');
  Check('psInt64  -> Int64',   TMessagesEmitter.PascalScalarType(psInt64)  = 'Int64');
  Check('psUInt32 -> UInt32',  TMessagesEmitter.PascalScalarType(psUInt32) = 'UInt32');
  Check('psUInt64 -> UInt64',  TMessagesEmitter.PascalScalarType(psUInt64) = 'UInt64');
  Check('psBool   -> Boolean', TMessagesEmitter.PascalScalarType(psBool)   = 'Boolean');
  Check('psString -> string',  TMessagesEmitter.PascalScalarType(psString) = 'string');
  Check('psFloat  -> Single',  TMessagesEmitter.PascalScalarType(psFloat)  = 'Single');
  Check('psDouble -> Double',  TMessagesEmitter.PascalScalarType(psDouble) = 'Double');
  Check('psBytes  -> TBytes',  TMessagesEmitter.PascalScalarType(psBytes)  = 'TBytes');

  // Group B — structural gap; must raise, not silently emit a wrong type
  LRaised := False;
  try
    TMessagesEmitter.PascalScalarType(psSInt32);
  except
    on EEmitError do LRaised := True;
  end;
  Check('psSInt32 raises EEmitError', LRaised);

  LRaised := False;
  try
    TMessagesEmitter.PascalScalarType(psFixed64);
  except
    on EEmitError do LRaised := True;
  end;
  Check('psFixed64 raises EEmitError', LRaised);
end;

procedure TestTypeName;
begin
  Section('PascalTypeName');
  Check('simple',            TMessagesEmitter.PascalTypeName('GreetRequest')    = 'TGreetRequest');
  Check('nested dot',        TMessagesEmitter.PascalTypeName('Outer.Inner')     = 'TOuterInner');
  Check('leading dot',       TMessagesEmitter.PascalTypeName('.Outer.Inner')    = 'TOuterInner');
  Check('three levels',      TMessagesEmitter.PascalTypeName('A.B.C')           = 'TABC');
  Check('single char name',  TMessagesEmitter.PascalTypeName('M')               = 'TM');
end;

// Where the two normalized forms first diverge, as a human-readable excerpt.
// A raw dump of two multi-kilobyte strings is unreadable; the offset plus a
// window either side is what actually locates the defect.
function FirstDifference(const AExpected, AGot: string): string;
var
  I, LMin, LFrom, LLen: Integer;
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
  LLen := 100;
  Result := Format('diverges at %d of %d/%d'#10 +
                   '    expected: ...%s...'#10 +
                   '    emitted : ...%s...',
    [I, Length(AExpected), Length(AGot),
     Copy(AExpected, LFrom, LLen), Copy(AGot, LFrom, LLen)]);
end;

// The C2 gate proper: parse the real .proto, emit, and compare against the
// real hand-written .Messages.pas. Both inputs come off disk.
procedure GateSample(const ALabel, ADir, AProtoFile, APasFile, AUnitPrefix: string;
  ARequired: Boolean);
var
  LFile: TProtoFileNode;
  LProtoPath, LPasPath, LGot, LWant: string;
begin
  Section('Emit gate: ' + ALabel);

  if ADir = '' then
  begin
    if ARequired then
      Check(ALabel + ' sample directory located', False,
        'not found and it is in this repo - expected samples/grpc-server')
    else
      Skip(ALabel, 'sibling checkout not found; set PROTOGEN_GREETER_DIR');
    Exit;
  end;

  LProtoPath := Join(ADir, AProtoFile);
  LPasPath   := Join(ADir, APasFile);
  WriteLn('  proto: ', LProtoPath);
  WriteLn('  pas  : ', LPasPath);

  if not FileExists(LPasPath) then
  begin
    if ARequired then
      Check(APasFile + ' present', False, LPasPath)
    else
      Skip(ALabel, APasFile + ' missing at ' + LPasPath);
    Exit;
  end;

  LFile := nil;
  try
    LFile := Parse(ReadFileText(LProtoPath));
    Check(ALabel + ' parse ok', LFile <> nil);
    if LFile = nil then
      Exit;
    LGot  := Normalize(EmitToString(LFile, AUnitPrefix, AProtoFile));
    LWant := Normalize(ReadFileText(LPasPath));
    Check(ALabel + ' matches hand-written ' + APasFile,
      LGot = LWant, FirstDifference(LWant, LGot));
  finally
    LFile.Free;
  end;
end;

procedure TestEmitEcho;
begin
  GateSample('echo', EchoDir, 'echo.proto', 'Sample.Echo.Messages.pas',
    'Sample.Echo', True);
end;

procedure TestEmitGreeter;
begin
  GateSample('greeter', GreeterDir, 'greeter.proto', 'Sample.Greeter.Messages.pas',
    'Sample.Greeter', False);
end;

// ── Main ──────────────────────────────────────────────────────────────────────

begin
  WriteLn('ProtogenEmitTests (C2 gate)');
  TestFieldName;
  TestScalarType;
  TestTypeName;
  TestEmitEcho;
  TestEmitGreeter;
  WriteLn;
  WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed, ', GSkip, ' skipped');
  if GFail > 0 then
    ExitCode := 1
  else if GSkip > 0 then
  begin
    // Exit 2, not 0: the suite ran without failures but did not run every
    // gate, so it has not demonstrated what it exists to demonstrate.
    WriteLn('GATE INCOMPLETE - ', GSkip,
            ' comparison(s) skipped; this is not a pass.');
    ExitCode := 2;
  end
  else
    WriteLn('C2 gate complete: emitted output matches the hand-written samples.');
end.
