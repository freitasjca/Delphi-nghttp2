program Protogen;

// =============================================================================
//  Protogen — .proto → Object Pascal code generator.
//  C4 of plans/horse-grpc-codegen.md.
//
//  Usage:
//    protogen -i greeter.proto -o src/ --unit-prefix Sample.Greeter
//    protogen -i greeter.proto -o src/ --unit-prefix Sample.Greeter --dry-run
//
//  Exit codes:
//    0  success
//    1  validation or parse error
//    2  I/O error
// =============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$IFEND}
  Protogen.Runner;

procedure PrintUsage;
begin
  WriteLn('Usage: protogen -i <proto> -o <dir> --unit-prefix <Prefix> [--dry-run]');
  WriteLn;
  WriteLn('  -i, --input       input .proto file');
  WriteLn('  -o, --output      output directory (created if absent)');
  WriteLn('      --unit-prefix unit prefix (e.g. Sample.Greeter)');
  WriteLn('      --dry-run     show what would be written, write nothing');
  WriteLn('  -h, --help        show this help');
  WriteLn;
  WriteLn('Emits three units:');
  WriteLn('  <Prefix>.Messages.pas    — message classes (always regenerated)');
  WriteLn('  <Prefix>.Interfaces.pas  — service interfaces (always regenerated)');
  WriteLn('  <Prefix>.Service.pas     — impl skeleton (written once; never overwritten)');
  WriteLn('                             If it exists, the new skeleton goes to');
  WriteLn('                             <Prefix>.Service.new.pas instead.');
end;

var
  I:       Integer;
  S:       string;
  LInput:  string;
  LOutput: string;
  LPrefix: string;
  LDryRun: Boolean;
  LResult: TProtogenResult;
  LLog:    TStringList;
  LCode:   Integer;
begin
  LInput  := '';
  LOutput := '';
  LPrefix := '';
  LDryRun := False;

  I := 1;
  while I <= ParamCount do
  begin
    S := ParamStr(I);
    if (S = '-i') or (S = '--input') then
    begin
      Inc(I);
      if I > ParamCount then
      begin
        WriteLn('protogen: ', S, ' requires an argument');
        ExitCode := 1;
        Exit;
      end;
      LInput := ParamStr(I);
    end
    else if (S = '-o') or (S = '--output') then
    begin
      Inc(I);
      if I > ParamCount then
      begin
        WriteLn('protogen: ', S, ' requires an argument');
        ExitCode := 1;
        Exit;
      end;
      LOutput := ParamStr(I);
    end
    else if S = '--unit-prefix' then
    begin
      Inc(I);
      if I > ParamCount then
      begin
        WriteLn('protogen: --unit-prefix requires an argument');
        ExitCode := 1;
        Exit;
      end;
      LPrefix := ParamStr(I);
    end
    else if S = '--dry-run' then
      LDryRun := True
    else if (S = '-h') or (S = '--help') then
    begin
      PrintUsage;
      ExitCode := 0;
      Exit;
    end
    else
    begin
      WriteLn('protogen: unknown option: ', S);
      WriteLn('Run ''protogen --help'' for usage.');
      ExitCode := 1;
      Exit;
    end;
    Inc(I);
  end;

  if (LInput = '') or (LOutput = '') or (LPrefix = '') then
  begin
    WriteLn('protogen: -i, -o, and --unit-prefix are all required');
    WriteLn;
    PrintUsage;
    ExitCode := 1;
    Exit;
  end;

  LLog := TStringList.Create;
  try
    LCode := TProtogenRunner.Run(LInput, LOutput, LPrefix, LDryRun, LResult, LLog);
    for I := 0 to LLog.Count - 1 do
      WriteLn(LLog[I]);
    if (LCode = 0) and LDryRun then
      WriteLn('(dry-run complete — no files written)');
    ExitCode := LCode;
  finally
    LLog.Free;
  end;
end.
