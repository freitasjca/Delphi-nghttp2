program ProtogenRunnerTests;

// =============================================================================
//  ProtogenRunnerTests — C4 gate from plans/horse-grpc-codegen.md.
//
//  Tests TProtogenRunner against a real filesystem (temp directory).
//  Content correctness — that generated units have the right structure — is
//  already covered by C2 (Messages) and C3 (Interfaces / Service).  This gate
//  focuses on:
//
//    WriteUnits: files created with correct names, messages / interfaces / service
//    No-overwrite: second run with existing .Service.pas → .Service.new.pas
//    Dry-run: nothing written to disk
//    Run (high-level): reads proto from disk, validation errors, bad proto
//
//  Build (FPC trunk):
//    fpc -MDelphi -O1 -Fu. ProtogenRunnerTests.dpr
//  Build (Windows):
//    dcc64 -CC -B -U. ProtogenRunnerTests.dpr
// =============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes, System.IOUtils,
{$IFEND}
  Protogen.Ast,
  Protogen.Lexer,
  Protogen.Parser,
  Protogen.Emitter,
  Protogen.ServiceEmitter,
  Protogen.Runner;

var
  GPass:    Integer = 0;
  GFail:    Integer = 0;
  GTestDir: string;

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

function ReadFile(const APath: string): string;
var
  LL: TStringList;
begin
  LL := TStringList.Create;
  try
    LL.LoadFromFile(APath);
    Result := LL.Text;
  finally
    LL.Free;
  end;
end;

procedure WriteFile(const APath, AContent: string);
var
  F: TextFile;
begin
  AssignFile(F, APath);
  Rewrite(F);
  try
    Write(F, AContent);
  finally
    CloseFile(F);
  end;
end;

function SubDir(const AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(GTestDir) + AName;
end;

// Delete known output files so each test starts from a predictable state.
// DeleteFile returns False when the file is absent — that is fine.
procedure CleanOutputs(const ADir, APrefix: string);
var
  D: string;
begin
  D := IncludeTrailingPathDelimiter(ADir);
  DeleteFile(D + APrefix + '.Messages.pas');
  DeleteFile(D + APrefix + '.Interfaces.pas');
  DeleteFile(D + APrefix + '.Service.pas');
  DeleteFile(D + APrefix + '.Service.new.pas');
  DeleteFile(D + APrefix + '.Registration.pas');   // C5
end;

// ── Proto source constants ───────────────────────────────────────────────────

const
  SIMPLE_PROTO =
    'syntax = "proto3"; package greet;' +
    'message HelloRequest { string name = 1; }' +
    'message HelloReply   { string message = 1; }' +
    'service Greeter { rpc SayHello (HelloRequest) returns (HelloReply); }';

  BAD_PROTO =
    'syntax = "proto3"; package x;' +
    'message M { sint32 v = 1; }';

// ── Tests ─────────────────────────────────────────────────────────────────────

procedure TestWriteUnits;
var
  LFile:   TProtoFileNode;
  LResult: TProtogenResult;
  LDir:    string;
  LCode:   Integer;
begin
  Section('WriteUnits: first run (clean directory)');
  LDir  := SubDir('first');
  // Remove output files from any prior run so Service.pas is absent.
  CleanOutputs(LDir, 'T.Greet');
  LFile := nil;
  try
    LFile := Parse(SIMPLE_PROTO);
    Check('parse ok', LFile <> nil);
    if LFile = nil then Exit;

    LCode := TProtogenRunner.WriteUnits(LFile, LDir, 'T.Greet', False, LResult);
    Check('exit code 0',            LCode = 0, IntToStr(LCode));
    Check('messages path set',      LResult.MessagesPath   <> '');
    Check('interfaces path set',    LResult.InterfacesPath <> '');
    Check('service path set',       LResult.ServicePath    <> '');
    Check('service is not new',     not LResult.ServiceIsNew);
    Check('messages file exists',   FileExists(LResult.MessagesPath));
    Check('interfaces file exists', FileExists(LResult.InterfacesPath));
    Check('service file exists',    FileExists(LResult.ServicePath));
    // C5 — the fourth generated unit, always regenerated.
    Check('registration path set',   LResult.RegistrationPath <> '');
    Check('registration file exists', FileExists(LResult.RegistrationPath));
    Check('messages has unit header',
      Pos('unit T.Greet.Messages', ReadFile(LResult.MessagesPath)) > 0);
    Check('interfaces has IGreeter',
      Pos('IGreeter', ReadFile(LResult.InterfacesPath)) > 0);
    Check('service has TGreeterServiceImpl',
      Pos('TGreeterServiceImpl', ReadFile(LResult.ServicePath)) > 0);
    Check('registration has RegisterGreeter',
      Pos('RegisterGreeter', ReadFile(LResult.RegistrationPath)) > 0);
  finally
    LFile.Free;
  end;
end;

procedure TestNoOverwrite;
var
  LFile:       TProtoFileNode;
  LResult:     TProtogenResult;
  LDir:        string;
  LCode:       Integer;
  LServicePas: string;
begin
  Section('WriteUnits: no-overwrite policy');
  LDir  := SubDir('nooverwrite');
  // Remove output files from any prior run so the state is predictable.
  CleanOutputs(LDir, 'T.Greet');
  LFile := nil;
  try
    LFile := Parse(SIMPLE_PROTO);
    Check('parse ok', LFile <> nil);
    if LFile = nil then Exit;

    // First run — writes .Service.pas
    LCode := TProtogenRunner.WriteUnits(LFile, LDir, 'T.Greet', False, LResult);
    Check('first run ok',    LCode = 0);
    LServicePas := LResult.ServicePath;
    Check('service written', FileExists(LServicePas));
    Check('not new on first run', not LResult.ServiceIsNew);

    // Overwrite Service.pas with a user-code marker
    WriteFile(LServicePas, '// my custom implementation' + #10 + 'unit stub;');

    // Second run — .Service.pas exists, so skeleton goes to .Service.new.pas
    LCode := TProtogenRunner.WriteUnits(LFile, LDir, 'T.Greet', False, LResult);
    Check('second run ok',      LCode = 0);
    Check('service is new',     LResult.ServiceIsNew);
    Check('.new.pas exists',    FileExists(LResult.ServicePath));
    Check('.new.pas has Impl',
      Pos('TGreeterServiceImpl', ReadFile(LResult.ServicePath)) > 0);
    Check('original preserved',
      Pos('my custom implementation', ReadFile(LServicePas)) > 0);
  finally
    LFile.Free;
  end;
end;

procedure TestDryRun;
var
  LFile:   TProtoFileNode;
  LResult: TProtogenResult;
  LDir:    string;
  LCode:   Integer;
begin
  Section('WriteUnits: dry-run');
  LDir  := SubDir('dryrun');
  LFile := nil;
  try
    LFile := Parse(SIMPLE_PROTO);
    Check('parse ok', LFile <> nil);
    if LFile = nil then Exit;

    LCode := TProtogenRunner.WriteUnits(LFile, LDir, 'T.Greet', True, LResult);
    Check('dry-run exit code 0',    LCode = 0);
    Check('dry-run: no messages',   not FileExists(LResult.MessagesPath));
    Check('dry-run: no interfaces', not FileExists(LResult.InterfacesPath));
    Check('dry-run: no service',    not FileExists(LResult.ServicePath));
    Check('dry-run: no registration', not FileExists(LResult.RegistrationPath));
  finally
    LFile.Free;
  end;
end;

procedure TestRunApi;
var
  LResult:    TProtogenResult;
  LDir:       string;
  LProtoFile: string;
  LCode:      Integer;
  LLog:       TStringList;
begin
  Section('Run: high-level API (reads proto from disk)');
  LDir       := SubDir('runapi');
  LProtoFile := IncludeTrailingPathDelimiter(LDir) + 'simple.proto';
  LLog       := TStringList.Create;
  try
    ForceDirectories(LDir);
    WriteFile(LProtoFile, SIMPLE_PROTO);

    // Success
    LCode := TProtogenRunner.Run(LProtoFile, LDir, 'T.Greet', False, LResult, LLog);
    Check('run: exit 0',          LCode = 0, IntToStr(LCode));
    Check('run: messages exists', FileExists(LResult.MessagesPath));
    Check('run: log non-empty',   LLog.Count > 0);

    // Validation errors — no ALog, testing just the exit code
    LCode := TProtogenRunner.Run('', LDir, 'T.Greet', False, LResult);
    Check('missing input -> 1',    LCode = 1);
    LCode := TProtogenRunner.Run(LProtoFile, '', 'T.Greet', False, LResult);
    Check('missing output -> 1',   LCode = 1);
    LCode := TProtogenRunner.Run(LProtoFile, LDir, '', False, LResult);
    Check('missing prefix -> 1',   LCode = 1);
    LCode := TProtogenRunner.Run('nonexistent.proto', LDir, 'T.Greet', False, LResult);
    Check('not found -> 1',        LCode = 1);

    // Bad proto
    WriteFile(LProtoFile, BAD_PROTO);
    LCode := TProtogenRunner.Run(LProtoFile, LDir, 'T.Greet', False, LResult);
    Check('bad proto -> 1',        LCode = 1);
  finally
    LLog.Free;
  end;
end;

// ── Main ──────────────────────────────────────────────────────────────────────

begin
{$IF DEFINED(FPC)}
  GTestDir := GetTempDir + 'pgtc4';
{$ELSE}
  GTestDir := TPath.GetTempPath + PathDelim + 'pgtc4';
{$IFEND}
  ForceDirectories(GTestDir);

  WriteLn('ProtogenRunnerTests (C4 gate)');
  TestWriteUnits;
  TestNoOverwrite;
  TestDryRun;
  TestRunApi;

  WriteLn;
  WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed');
  if GFail > 0 then
    ExitCode := 1;
end.
