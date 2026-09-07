program Protogen;

// =============================================================================
//  Protogen — .proto → Object Pascal code generator.
//  C4 of plans/horse-grpc-codegen.md.
//
//  Usage:
//    protogen -i greeter.proto -o src/ --unit-prefix Sample.Greeter
//    protogen -i greeter.proto -o src/ --unit-prefix Sample.Greeter --dry-run
//    protogen -i a/b.proto -I . -I vendor -o src/ --unit-prefix Demo
//
//  IMPORT-1: the input's imports are followed, and one unit is emitted per
//  .proto in the closure. A unit's name comes from the FILE'S PATH, so
//  google/rpc/status.proto is always <Prefix>.Google.Rpc.Status.Messages —
//  reached as a root or as an import, it is the same unit either way, which is
//  what stops one .proto turning into two incompatible sets of classes.
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
  WriteLn('Usage: protogen -i <proto> -o <dir> --unit-prefix <Prefix>');
  WriteLn('                [-I <dir>]... [--dry-run]');
  WriteLn;
  WriteLn('  -i, --input       input .proto file');
  WriteLn('  -o, --output      output directory (created if absent)');
  WriteLn('  -I, --proto-path  directory to resolve imports against; repeatable,');
  WriteLn('                    searched in order. Defaults to the input''s own');
  WriteLn('                    directory. Import paths are resolved against these');
  WriteLn('                    roots, never relative to the importing file.');
  WriteLn('      --unit-prefix unit prefix (e.g. Sample.Greeter)');
  WriteLn('      --dry-run     show what would be written, write nothing');
  WriteLn('  -h, --help        show this help');
  WriteLn;
  WriteLn('Emits, for EACH .proto in the import closure, a unit group named');
  WriteLn('from that file''s path — b/c.proto under --unit-prefix Demo becomes');
  WriteLn('Demo.B.C:');
  WriteLn('  <Unit>.Messages.pas      — message classes (always regenerated)');
  WriteLn('  <Unit>.Interfaces.pas    — service interfaces (only if it declares one)');
  WriteLn('  <Unit>.Service.pas       — impl skeleton (written once; never overwritten)');
  WriteLn('                             If it exists, the new skeleton goes to');
  WriteLn('                             <Unit>.Service.new.pas instead.');
  WriteLn('  <Unit>.Registration.pas  — registration (only if it declares a service)');
  WriteLn;
  WriteLn('google/protobuf well-known types are supplied by the library, so they');
  WriteLn('are never looked up on an include path and generate no unit.');
end;

var
  I:       Integer;
  S:       string;
  LInput:  string;
  LOutput: string;
  LPrefix: string;
  LDryRun: Boolean;
  LResults: TArray<TProtogenResult>;
  LRoots:  TStringList;
  LLog:    TStringList;
  LCode:   Integer;
begin
  LInput  := '';
  LOutput := '';
  LPrefix := '';
  LDryRun := False;
  LRoots  := TStringList.Create;

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
        LRoots.Free;
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
        LRoots.Free;
        Exit;
      end;
      LOutput := ParamStr(I);
    end
    else if (S = '-I') or (S = '--proto-path') then
    begin
      Inc(I);
      if I > ParamCount then
      begin
        WriteLn('protogen: ', S, ' requires a directory');
        ExitCode := 1;
        LRoots.Free;
        Exit;
      end;
      LRoots.Add(ParamStr(I));
    end
    else if S = '--unit-prefix' then
    begin
      Inc(I);
      if I > ParamCount then
      begin
        WriteLn('protogen: --unit-prefix requires an argument');
        ExitCode := 1;
        LRoots.Free;
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
      LRoots.Free;
      Exit;
    end
    else
    begin
      WriteLn('protogen: unknown option: ', S);
      WriteLn('Run ''protogen --help'' for usage.');
      ExitCode := 1;
      LRoots.Free;
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
    LRoots.Free;
    Exit;
  end;

  LLog := TStringList.Create;
  try
    LCode := TProtogenRunner.RunClosure(LInput, LOutput, LPrefix, LRoots,
      LDryRun, LResults, LLog);
    for I := 0 to LLog.Count - 1 do
      WriteLn(LLog[I]);
    if LCode = 0 then
    begin
      // Say how many files were generated, not just that it worked: with
      // imports followed, "1 file" versus "14 files" is the difference
      // between a resolved closure and a silently unresolved one.
      if Length(LResults) = 1 then
        WriteLn('generated 1 proto file')
      else
        WriteLn('generated ', Length(LResults), ' proto files');
      // The root's unit, named so callers do not have to re-derive the
      // path-to-unit-name rule for themselves and get it subtly different.
      // RunClosure loads the root first, so it is always entry zero.
      if Length(LResults) > 0 then
        WriteLn('root-unit-file: ',
          ExtractFileName(LResults[0].MessagesPath));
      if LDryRun then
        WriteLn('(dry-run complete — no files written)');
    end;
    ExitCode := LCode;
  finally
    LLog.Free;
    LRoots.Free;
  end;
end.
