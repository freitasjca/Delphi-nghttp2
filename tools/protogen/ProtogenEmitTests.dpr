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

// ── PRESENCE-1 · proto3 `optional` emission ─────────────────────────────────

{ Emits a schema and returns the generated text, unnormalized.

  Deliberately NOT normalized: these assertions are about the exact shape of
  declarations, and the read-only has-bit is distinguished from a writable one
  ONLY by the absence of ` write `. Collapsing whitespace would still leave
  that visible, but keeping the raw text means the assertions read like the
  Pascal they are checking. }
function EmitSource(const AProto: string): string;
var
  LFile: TProtoFileNode;
begin
  { Built on this file's existing Parse/EmitToString helpers rather than
    re-driving TProtoParser directly - the emitter's own arity trap (C4) came
    from exactly that kind of duplicated call site drifting out of step. }
  LFile := Parse(AProto);
  try
    Result := EmitToString(LFile, 'Sample.Opt', 'opt.proto');
  finally
    LFile.Free;
  end;
end;

function Has(const AHaystack, ANeedle: string): Boolean;
begin
  Result := Pos(LowerCase(ANeedle), LowerCase(AHaystack)) > 0;
end;


// ── FORWARD-1: class forwards for out-of-order message references ───────────

// ── ENUMCOLLIDE-1: enum values share Pascal unit scope ──────────────────────
procedure TestEnumValueCollision;
const
  { LEGAL proto3 - each E is scoped to its message, each X to its enum's
    parent - and protoc compiles it. Pascal cannot: both emit a bare X. }
  CCollide =
    'syntax = "proto3";'#10'package t;'#10 +
    'message A { enum E { X = 0; } E e = 1; }'#10 +
    'message B { enum E { X = 0; } E e = 1; }';
  { The control: two enums whose values are prefixed, as the proto style guide
    recommends. Must still emit. }
  CDistinct =
    'syntax = "proto3";'#10'package t;'#10 +
    'message A { enum E { A_X = 0; } E e = 1; }'#10 +
    'message B { enum E { B_X = 0; } E e = 1; }';
var
  LRaised: Boolean;
  LMsg, LSrc: string;
begin
  WriteLn;
  WriteLn('-- ENUMCOLLIDE-1: enum values share Pascal unit scope');

  LRaised := False;
  LMsg    := '';
  try
    EmitSource(CCollide);
  except
    on E: EEmitError do
    begin
      LRaised := True;
      LMsg    := E.Message;
    end;
  end;
  Check('two enums sharing a value name are REFUSED', LRaised, LMsg);
  Check('  the refusal names both enums',
    Has(LMsg, 'A.E') and Has(LMsg, 'B.E'), LMsg);
  Check('  and the colliding value', Has(LMsg, 'X'), LMsg);
  { A refusal that only restates the problem sends the user hunting. This one
    has to say WHY Pascal cannot do what proto can. }
  Check('  and explains that Pascal enum values share unit scope',
    Has(LMsg, 'unit scope'), LMsg);
  { The suggestion has to RESOLVE the collision. Deriving it from the enum's
    simple name - which is what the proto style guide literally says - gives
    'E_X' for BOTH enums here, because they share the name E. That advice
    collides again, and the first version of this message gave exactly it. }
  Check('  suggests a prefix that actually disambiguates',
    Has(LMsg, 'A_E_X'), LMsg);
  Check('  and not the simple-name prefix, which collides again',
    not Has(LMsg, '(E_X'), LMsg);

  { The control matters as much as the refusal: a check that refused BOTH would
    look identical on the failing case alone. }
  LSrc := EmitSource(CDistinct);
  Check('distinct value names still emit', Has(LSrc, 'A_X = 0'));
  Check('  both enums present', Has(LSrc, 'B_X = 0'));
end;


// ── ONEOF-2: message members in a oneof ─────────────────────────────────────
procedure TestEmitOneofMessageMember;
const
  CProto =
    'syntax = "proto3";'#10'package t;'#10 +
    'message Payload { int32 id = 1; }'#10 +
    'message M {'#10 +
    '  oneof body {'#10 +
    '    Payload a = 1;'#10 +
    '    int32   n = 2;'#10 +
    '  }'#10 +
    '}';
var
  LSrc: string;
begin
  WriteLn;
  WriteLn('-- ONEOF-2: message members in a oneof');

  LSrc := EmitSource(CProto);

  { No has-bit. AttachHasBits REFUSES one on a submessage, so emitting it would
    be rejected at first Serialize - nil is the presence signal. }
  Check('a message member gets NO has-bit backing field',
    not Has(LSrc, 'FHasa'));
  Check('  and no [TProtoHas] attribute for its tag',
    not Has(LSrc, '[TProtoHas(1)]'));
  Check('  while the SCALAR member in the same group still gets one',
    Has(LSrc, '[TProtoHas(2)]'));

  { The setter is the whole mechanism - without it the property writes straight
    to the field and two members end up set at once. }
  Check('the message member writes through its setter',
    Has(LSrc, 'property a: TPayload read Fa write Seta'));

  { DECLARED, not just defined. Emitting the body alone gives "Method
    identifier expected" at the body line, which names the wrong thing - and
    that is exactly what happened on the first run of this change. }
  Check('Cleara is DECLARED in the class',
    Has(LSrc, 'procedure Cleara;'));
  Check('Seta is DECLARED in the class',
    Has(LSrc, 'procedure Seta(const AValue: TPayload);'));

  { Freed, not nilled - the class owns the instance. }
  Check('the group Clear FREES the message member', Has(LSrc, 'Fa.Free'));
  Check('  and nils it afterwards', Has(LSrc, 'Fa := nil'));
  { FreeAndNil would need SysUtils, which a generated unit does not use. }
  Check('  without reaching for FreeAndNil', not Has(LSrc, 'FreeAndNil'));

  { Presence is nil for the message member and a bit for the scalar - the case
    getter has to read each the right way. }
  Check('the case getter tests nil for the message member',
    Has(LSrc, 'if Fa <> nil then'));
  Check('  and the has-bit for the scalar member', Has(LSrc, 'FHasn'));

  { The self-assignment guard: Clear frees this very instance. }
  Check('the setter guards against self-assignment',
    Has(LSrc, 'if Fa = AValue then Exit'));
end;

procedure TestEmitForwardDecls;
const
  { The shape that produced non-compiling Pascal until FORWARD-1. Ordinary
    proto3 - declaration order carries no meaning and protoc accepts it. }
  CForward =
    'syntax = "proto3";'#10'package t;'#10 +
    'message A { B b = 1; }'#10 +
    'message B { int32 id = 1; }';
  { The control. Every existing sample looks like this, which is why the gap
    survived: with no forward reference there is nothing to emit, and the
    byte-for-byte sample comparison keeps meaning what it meant. }
  CInOrder =
    'syntax = "proto3";'#10'package t;'#10 +
    'message B { int32 id = 1; }'#10 +
    'message A { B b = 1; }';
  { A class name is already in scope inside its own declaration. }
  CSelf =
    'syntax = "proto3";'#10'package t;'#10 +
    'message Node { Node next = 1; int32 id = 2; }';
  { A bundled WKT is declared in ANOTHER UNIT - a forward here would be a
    second, conflicting declaration. }
  CWkt =
    'syntax = "proto3";'#10'package t;'#10 +
    'import "google/protobuf/timestamp.proto";'#10 +
    'message M { google.protobuf.Timestamp t = 1; }';
  { Repeated and map-valued references need one too - the reference is through
    TArray<T>, but T still has to exist. }
  CRepeated =
    'syntax = "proto3";'#10'package t;'#10 +
    'message A { repeated B many = 1; }'#10 +
    'message B { int32 id = 1; }';
var
  LSrc, LTail: string;
  LFwd, LDecl: Integer;
begin
  WriteLn;
  WriteLn('-- FORWARD-1: forward declarations for out-of-order references');

  LSrc := EmitSource(CForward);
  Check('out-of-order reference emits a forward', Has(LSrc, 'TB = class;'));

  { Position is the whole point. A forward emitted AFTER the class that needs
    it compiles no better than none at all, and a substring test alone would
    pass either way. }
  LFwd  := Pos('tb = class;', LowerCase(LSrc));
  LDecl := Pos('ta = class', LowerCase(LSrc));
  Check('the forward precedes the class that needs it',
    (LFwd > 0) and (LDecl > 0) and (LFwd < LDecl));

  { And the full declaration must still be emitted - a forward with no body is
    a link error rather than a compile error, which is worse.

    Written as "search the text AFTER the forward" rather than comparing two
    Pos results. The obvious version,

      Pos('tb = class', S) <> Pos('tb = class;', S)

    can NEVER pass: Pos returns the FIRST match and `tb = class` is a PREFIX of
    `tb = class;`, so both land on the forward and the comparison is always
    False. It failed on its first run against correct output - the emitter was
    right and the assertion was impossible. }
  LTail := Copy(LowerCase(LSrc), LFwd + Length('tb = class;'), MaxInt);
  Check('TB is still fully declared after its forward',
    Pos('tb = class', LTail) > 0);

  LSrc := EmitSource(CInOrder);
  Check('an IN-ORDER file emits no forward at all',
    not Has(LSrc, 'TB = class;'));
  Check('  and no forward-declaration comment block',
    not Has(LSrc, 'Forward declarations'));

  LSrc := EmitSource(CSelf);
  Check('a SELF-reference emits no forward', not Has(LSrc, 'TNode = class;'));
  Check('  but the class is still emitted', Has(LSrc, 'TNode = class'));

  LSrc := EmitSource(CWkt);
  Check('a bundled WKT gets no forward',
    not Has(LSrc, 'TProtobufTimestamp = class;'));

  LSrc := EmitSource(CRepeated);
  Check('a REPEATED out-of-order reference emits one too',
    Has(LSrc, 'TB = class;'));
end;


procedure TestEmitOptional;
const
  CProto =
    'syntax = "proto3";'#10'package t;'#10 +
    'enum Colour { C_UNSET = 0; C_RED = 1; }'#10 +
    'message M {'#10 +
    '  int32 plain = 1;'#10 +
    '  optional int32 opt = 2;'#10 +
    '  optional Colour col = 3;'#10 +
    '}';
  CMsgProto =
    'syntax = "proto3";'#10'package t;'#10 +
    'message Inner { int32 id = 1; }'#10 +
    'message M { optional Inner inner = 1; }';
var
  LSrc: string;
  LRaised: Boolean;
  LMsg: string;
begin
  WriteLn;
  WriteLn('-- PRESENCE-1: `optional` emission');

  LSrc := EmitSource(CProto);

  // backing field + has-bit + setter declaration
  Check('emits the has-bit backing field',
    Has(LSrc, 'FHasOpt: Boolean;'), LSrc);
  Check('emits the setter declaration',
    Has(LSrc, 'procedure SetOpt(const AValue: Integer);'));
  Check('emits a Clear method',
    Has(LSrc, 'procedure ClearOpt;'));

  // the property pair
  Check('value property writes through the SETTER, not the field',
    Has(LSrc, 'property opt: Integer read FOpt write SetOpt;'));
  Check('emits [TProtoHas] with the SAME tag as the field',
    Has(LSrc, '[TProtoHas(2)]'));

  { The single most important assertion in this section. A has-bit with a
    writer is refused at discovery, so emitting one would produce generated
    code that compiles and then raises the first time it is used. }
  Check('has-bit property is READ-ONLY (no write clause)',
    Has(LSrc, 'property HasOpt: Boolean read FHasOpt;')
    and not Has(LSrc, 'property HasOpt: Boolean read FHasOpt write'));

  // method bodies
  Check('setter body assigns the value',
    Has(LSrc, 'FOpt := AValue;'));
  Check('setter body RAISES the has-bit',
    Has(LSrc, 'FHasOpt := True;'));
  Check('Clear body lowers the has-bit',
    Has(LSrc, 'FHasOpt := False;'));

  // an enum is a scalar on the wire, so it takes a has-bit too
  Check('optional ENUM also gets a has-bit',
    Has(LSrc, 'FHasCol: Boolean;') and Has(LSrc, '[TProtoHas(3)]'));

  { The regression guard: a non-optional field must be emitted exactly as
    before, writing straight to its backing field. If this ever fails, the
    feature stopped being additive. }
  Check('implicit-presence field is untouched',
    Has(LSrc, 'property plain: Integer read FPlain write FPlain;'));
  Check('implicit-presence field gets NO has-bit',
    not Has(LSrc, 'FHasPlain'));

  // `optional <message>` is the emitter's job to refuse, not the parser's
  LRaised := False;
  LMsg    := '';
  try
    EmitSource(CMsgProto);
  except
    on E: EEmitError do
    begin
      LRaised := True;
      LMsg    := E.Message;
    end;
  end;
  Check('`optional <message>` is refused by the emitter', LRaised, LMsg);
  Check('the refusal explains that nil already means absent',
    LRaised and Has(LMsg, 'nil'), LMsg);
end;

// ── Main ──────────────────────────────────────────────────────────────────────

begin
  WriteLn('ProtogenEmitTests (C2 gate)');
  TestFieldName;
  TestScalarType;
  TestTypeName;
  TestEmitOptional;
  TestEmitForwardDecls;
  TestEnumValueCollision;
  TestEmitOneofMessageMember;
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
