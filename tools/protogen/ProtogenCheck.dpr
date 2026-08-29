program ProtogenCheck;

// ============================================================================
//  ProtogenCheck — parse one .proto and report the verdict. Nothing else.
//
//  C1b of plans/horse-grpc-codegen.md. This exists so protoc-oracle.sh can ask
//  our parser the same yes/no question it asks protoc, and diff the answers.
//  It is NOT the generator CLI — that is C4, and it will want output paths,
//  unit prefixes and a --dry-run. Keeping this one to a single question makes
//  it usable as an oracle input without dragging generator flags into the
//  comparison.
//
//  Usage:
//    ProtogenCheck <file.proto>
//
//  Exit code:
//    0  accepted — the parser built an AST
//    1  refused  — a documented limitation or an invalid schema; the reason
//                  goes to stdout, which is what the oracle diffs
//    2  internal error, bad usage, or unreadable file
//
//  The distinction between 1 and 2 is load-bearing: a refusal is this tool
//  working, an internal error is it failing, and an oracle that conflated them
//  would score a crash as a successful rejection.
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}

uses
{$IF DEFINED(FPC)}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
  Protogen.Ast,
  Protogen.Lexer,
  Protogen.Parser;

var
  LFile: TProtoFileNode;
  LPath: string;

begin
  if ParamCount <> 1 then
  begin
    WriteLn(ErrOutput, 'usage: ProtogenCheck <file.proto>');
    ExitCode := 2;
    Exit;
  end;

  LPath := ParamStr(1);
  if not FileExists(LPath) then
  begin
    WriteLn(ErrOutput, 'ERROR  file not found: ', LPath);
    ExitCode := 2;
    Exit;
  end;

  LFile := nil;
  try
    try
      LFile := ParseProtoFile(LPath);
      WriteLn(Format('ACCEPT  %s  (%d message(s), %d enum(s), %d service(s))',
        [ExtractFileName(LPath), LFile.Messages.Count, LFile.Enums.Count,
         LFile.Services.Count]));
      ExitCode := 0;
    except
      { The two refusal types are the parser doing its job. Everything else is
        the parser falling over, and must not be reported as a refusal. }
      { The construct is printed in [brackets] as its own field so a corpus run
        can tally refusals BY CAUSE without parsing prose. That tally is the
        whole point of C1c: "how many schemas do we turn away" is far less
        actionable than "which feature turned them away". }
      on E: EProtoParseError do
      begin
        WriteLn(Format('REFUSE  %s  [%s]  %s',
          [ExtractFileName(LPath), E.Construct, E.Message]));
        ExitCode := 1;
      end;
      on E: EProtoLexError do
      begin
        // No Construct on a lex error — the input was not well-formed enough
        // to name one. Tagged so a corpus tally can separate malformed input
        // from a deliberate feature refusal.
        WriteLn(Format('REFUSE  %s  [lex]  %s',
          [ExtractFileName(LPath), E.Message]));
        ExitCode := 1;
      end;
      on E: Exception do
      begin
        WriteLn(ErrOutput, Format('ERROR   %s  %s: %s',
          [ExtractFileName(LPath), E.ClassName, E.Message]));
        ExitCode := 2;
      end;
    end;
  finally
    LFile.Free;
  end;
end.
