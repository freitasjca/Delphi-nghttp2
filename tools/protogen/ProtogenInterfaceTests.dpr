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
//  EMIT GATE (interfaces): parse echo.proto and greeter.proto inline, emit
//  with TInterfacesEmitter, normalize (same rules as ProtogenEmitTests:
//  strip comments + collapse whitespace), and compare against expected
//  strings. GUIDs are substituted at test runtime by calling
//  GuidFromServiceName with the same inputs the emitter uses — the
//  structural comparison validates the whole pipeline, and the separate
//  determinism tests catch any non-determinism in the GUID function.
//
//  EMIT GATE (skeleton): same parse → emit → normalize → compare approach
//  for TServiceSkeletonEmitter. No GUIDs in the skeleton, so the expected
//  constant is static.
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

procedure Section(const S: string);
begin
  WriteLn;
  WriteLn('── ', S);
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

function Normalize(const S: string): string;
begin
  Result := CollapseWS(StripComments(S));
end;

// ── Proto source constants ───────────────────────────────────────────────────

const
  ECHO_PROTO =
    'syntax = "proto3"; package echo;' +
    'message SayRequest { string name = 1; }' +
    'message SayResponse { string message = 1; int32 length = 2; }' +
    'service Echo { rpc Say (SayRequest) returns (SayResponse); }';

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
  Check('same input → same output', G1 = G2);
  G2 := TInterfacesEmitter.GuidFromServiceName('echo.Echo');
  Check('different services → different GUIDs', G1 <> G2);
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
    Check('echo interfaces normalize match', LGot = LExpected, LGot);
  finally
    LFile.Free;
  end;
end;

procedure TestEmitInterfacesGreeter;
var
  LFile: TProtoFileNode;
  LGot, LGuid, LExpected: string;
begin
  Section('Emit: greeter.proto interfaces');
  LFile := nil;
  try
    LFile := Parse(GREETER_PROTO);
    Check('greeter parse ok', LFile <> nil);
    if LFile = nil then Exit;
    LGuid := TInterfacesEmitter.GuidFromServiceName('greeter.Greeter');
    LExpected :=
      'unit Sample.Greeter.Interfaces;' +
      ' {$M+}' +
      ' {$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}' +
      ' interface' +
      ' {$IF DEFINED(FPC)}' +
      ' {$RTTI EXPLICIT PROPERTIES([vcPublished]) FIELDS([vcPublic]) METHODS([vcPublic])}' +
      ' {$ENDIF}' +
      ' uses' +
      ' Nghttp2.Grpc.Attributes,' +
      ' Sample.Greeter.Messages;' +
      ' type' +
      ' [TGrpcService(''greeter.Greeter'')]' +
      ' IGreeter = interface(IInvokable)' +
      ' [''' + LGuid + ''']' +
      ' function Greet(const ARequest: TGreetRequest): TGreetResponse;' +
      ' function Echo(const ARequest: TEchoRequest): TEchoResponse;' +
      ' end;' +
      ' implementation' +
      ' end.';
    LGot := Normalize(EmitIface(LFile, 'Sample.Greeter'));
    Check('greeter interfaces normalize match', LGot = LExpected, LGot);
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
    Check('greeter skeleton normalize match', LGot = GREETER_SKELETON_NORM, LGot);
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
  WriteLn;
  WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed');
  if GFail > 0 then
    ExitCode := 1;
end.
