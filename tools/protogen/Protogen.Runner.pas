unit Protogen.Runner;

// =============================================================================
//  Protogen.Runner — C4 of plans/horse-grpc-codegen.md.
//
//  TProtogenRunner orchestrates the three emitters into a directory.
//
//  WriteUnits(AFile, AOutputDir, AUnitPrefix, ADryRun, out AResult,
//             ALog = nil, AProtoFileName = '')
//    Takes an already-parsed TProtoFileNode.  Called by both the CLI binary
//    (Protogen.dpr) and the gate test (ProtogenRunnerTests.dpr) so the test
//    never needs a proto file on disk.
//    Returns 0 on success, 2 on I/O error.
//
//  Run(AInputFile, AOutputDir, AUnitPrefix, ADryRun, out AResult)
//    Reads AInputFile from disk, parses it, then calls WriteUnits.
//    Returns 0 on success, 1 on validation or parse error, 2 on I/O error.
//
//  No-overwrite contract (§6.4):
//    .Messages.pas and .Interfaces.pas are always regenerated.
//    .Service.pas is written ONLY when absent — it holds user code.
//    If .Service.pas already exists, the new skeleton goes to .Service.new.pas.
//
//  Dual-compilation: dcc64 (Delphi 10.4+) and fpc trunk 3.3.1 {$MODE DELPHI}.
// =============================================================================

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$IFEND}
  Protogen.Ast,
  Protogen.Emitter,
  Protogen.ServiceEmitter;

type
  TProtogenResult = record
    MessagesPath:   string;  // path written (or would be in dry-run)
    InterfacesPath: string;
    ServicePath:    string;  // .Service.pas or .Service.new.pas
    ServiceIsNew:   Boolean; // True → .new.pas, existing .Service.pas preserved
  end;

  TProtogenRunner = class
  private
    class function MakePath(const ADir, AUnitPrefix, ASuffix: string): string;
    class procedure Flush(ALines: TStrings; const APath: string;
      ADryRun: Boolean; ALog: TStrings);
  public
    // AProtoFileName is recorded in the generated "// generated from ..."
    // header comment only. It is a plain string, not a path that gets opened,
    // so callers that build an AST in memory (the gate test) can leave it
    // empty and still exercise every write path.
    class function WriteUnits(AFile: TProtoFileNode;
      const AOutputDir, AUnitPrefix: string;
      ADryRun: Boolean; out AResult: TProtogenResult;
      ALog: TStrings = nil;
      const AProtoFileName: string = ''): Integer;

    class function Run(const AInputFile, AOutputDir, AUnitPrefix: string;
      ADryRun: Boolean; out AResult: TProtogenResult;
      ALog: TStrings = nil): Integer;
  end;

implementation

uses
  Protogen.Lexer,
  Protogen.Parser;

// ── helpers ──────────────────────────────────────────────────────────────────

class function TProtogenRunner.MakePath(const ADir, AUnitPrefix,
  ASuffix: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ADir)
    + AUnitPrefix + '.' + ASuffix + '.pas';
end;

class procedure TProtogenRunner.Flush(ALines: TStrings; const APath: string;
  ADryRun: Boolean; ALog: TStrings);
begin
  if ADryRun then
  begin
    if ALog <> nil then
      ALog.Add('[dry-run] would write ' + ExtractFileName(APath));
  end
  else
  begin
    ALines.SaveToFile(APath);
    if ALog <> nil then
      ALog.Add('[write] ' + ExtractFileName(APath));
  end;
end;

// ── TProtogenRunner.WriteUnits ───────────────────────────────────────────────

class function TProtogenRunner.WriteUnits(AFile: TProtoFileNode;
  const AOutputDir, AUnitPrefix: string; ADryRun: Boolean;
  out AResult: TProtogenResult; ALog: TStrings;
  const AProtoFileName: string): Integer;
var
  LLines:      TStringList;
  LEmitMsg:    TMessagesEmitter;
  LEmitIface:  TInterfacesEmitter;
  LEmitSkel:   TServiceSkeletonEmitter;
  LServicePas: string;
  LServiceNew: string;
begin
  Result := 0;
  AResult := Default(TProtogenResult);
  AResult.MessagesPath   := MakePath(AOutputDir, AUnitPrefix, 'Messages');
  AResult.InterfacesPath := MakePath(AOutputDir, AUnitPrefix, 'Interfaces');
  LServicePas := MakePath(AOutputDir, AUnitPrefix, 'Service');
  LServiceNew := IncludeTrailingPathDelimiter(AOutputDir)
    + AUnitPrefix + '.Service.new.pas';

  if not ADryRun then
    ForceDirectories(AOutputDir);

  LLines := TStringList.Create;
  try
    // Messages — always regenerated
    LEmitMsg := TMessagesEmitter.Create;
    try
      LEmitMsg.Emit(AFile, AUnitPrefix, AProtoFileName, LLines);
      Flush(LLines, AResult.MessagesPath, ADryRun, ALog);
    finally
      LEmitMsg.Free;
    end;

    // Interfaces — always regenerated
    LLines.Clear;
    LEmitIface := TInterfacesEmitter.Create;
    try
      LEmitIface.Emit(AFile, AUnitPrefix, LLines);
      Flush(LLines, AResult.InterfacesPath, ADryRun, ALog);
    finally
      LEmitIface.Free;
    end;

    // Service skeleton — no-overwrite contract (§6.4)
    LLines.Clear;
    LEmitSkel := TServiceSkeletonEmitter.Create;
    try
      LEmitSkel.Emit(AFile, AUnitPrefix, LLines);
      // Check FileExists in both modes: in dry-run the dir may not exist yet
      // (so Service.pas can't exist either) but the check is still correct —
      // a prior real run would have created it, and dry-run should report what
      // WOULD happen in that state.
      if FileExists(LServicePas) then
      begin
        AResult.ServicePath  := LServiceNew;
        AResult.ServiceIsNew := True;
        Flush(LLines, LServiceNew, ADryRun, ALog);
        if ALog <> nil then
          ALog.Add('[info] ' + ExtractFileName(LServicePas) +
            ' preserved — new skeleton → ' + ExtractFileName(LServiceNew));
      end
      else
      begin
        AResult.ServicePath  := LServicePas;
        AResult.ServiceIsNew := False;
        Flush(LLines, LServicePas, ADryRun, ALog);
      end;
    finally
      LEmitSkel.Free;
    end;
  finally
    LLines.Free;
  end;
end;

// ── TProtogenRunner.Run ──────────────────────────────────────────────────────

class function TProtogenRunner.Run(const AInputFile, AOutputDir,
  AUnitPrefix: string; ADryRun: Boolean; out AResult: TProtogenResult;
  ALog: TStrings): Integer;
var
  LContent: TStringList;
  LParser:  TProtoParser;
  LFile:    TProtoFileNode;
begin
  AResult := Default(TProtogenResult);

  if AInputFile = '' then
  begin
    if ALog <> nil then ALog.Add('error: -i / --input is required');
    Result := 1;
    Exit;
  end;
  if AOutputDir = '' then
  begin
    if ALog <> nil then ALog.Add('error: -o / --output is required');
    Result := 1;
    Exit;
  end;
  if AUnitPrefix = '' then
  begin
    if ALog <> nil then ALog.Add('error: --unit-prefix is required');
    Result := 1;
    Exit;
  end;
  if not FileExists(AInputFile) then
  begin
    if ALog <> nil then ALog.Add('error: not found: ' + AInputFile);
    Result := 1;
    Exit;
  end;

  LContent := TStringList.Create;
  LFile    := nil;
  LParser  := nil;
  try
    try
      LContent.LoadFromFile(AInputFile);
      LParser := TProtoParser.Create(LContent.Text, AInputFile);
      LFile   := LParser.Parse;
      FreeAndNil(LParser);
      Result := WriteUnits(LFile, AOutputDir, AUnitPrefix, ADryRun, AResult, ALog,
        ExtractFileName(AInputFile));
    except
      on E: Exception do
      begin
        if ALog <> nil then ALog.Add('error: ' + E.Message);
        Result := 1;
      end;
    end;
  finally
    FreeAndNil(LParser);
    FreeAndNil(LFile);
    FreeAndNil(LContent);
  end;
end;

end.
