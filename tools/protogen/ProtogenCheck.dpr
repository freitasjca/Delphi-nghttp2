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
//    ProtogenCheck [--emit] <file.proto>
//
//  --emit also runs the EMITTER over the parsed AST and discards the output.
//
//  That flag exists because of what FORWARD-1 exposed on 2026-09-07: this tool
//  used only Protogen.Parser, so the 7301-schema corpus measured PARSE
//  ACCEPTANCE ONLY and had never run the emitter once. "99.5% accepted" was a
//  statement about parsing, and was being read as coverage of generated output.
//  Two emitter defects were sitting behind it - FORWARD-1 and ENUMCOLLIDE-1 -
//  and neither was reachable by any corpus run.
//
//  What --emit CAN catch: an emitter refusal (EEmitError) and an emitter crash.
//  What it CANNOT: output that emits happily and then fails to compile. That is
//  why both defects above were fixed by making the emitter REFUSE rather than
//  by leaving them to a compiler - a refusal is the shape a corpus can count.
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
  Classes,
  Protogen.Ast,
  Protogen.Lexer,
  Protogen.Parser,
  Protogen.Emitter;

var
  LFile: TProtoFileNode;
  LPath: string;
  LEmit: Boolean;
  LOut:  TStringList;
  LEmitter: TMessagesEmitter;
  I: Integer;

begin
  LEmit := False;
  LPath := '';
  for I := 1 to ParamCount do
    if ParamStr(I) = '--emit' then
      LEmit := True
    else if LPath = '' then
      LPath := ParamStr(I)
    else
      LPath := #0;          // a second non-flag argument is a usage error

  if (LPath = '') or (LPath = #0) then
  begin
    WriteLn(ErrOutput, 'usage: ProtogenCheck [--emit] <file.proto>');
    ExitCode := 2;
    Exit;
  end;
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

      { The output is DISCARDED - what is under test is whether emitting
        raises, not what it produced. Checking the text would need an expected
        answer per schema, which a foreign corpus cannot supply. }
      if LEmit then
      begin
        LOut := TStringList.Create;
        try
          LEmitter := TMessagesEmitter.Create;
          try
            LEmitter.Emit(LFile, 'Corpus.Probe', ExtractFileName(LPath), LOut);
          finally
            LEmitter.Free;
          end;
        finally
          LOut.Free;
        end;
      end;

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
      { An EMITTER refusal is still this tool working - the same category as a
        parser refusal, and reported the same way so a corpus tally sees it.
        Bracketed `emit` rather than by construct: the emitter refuses for
        whole-file reasons (an enum-value collision names two enums, not one
        construct), so a per-construct bracket would be a lie. }
      on E: EEmitError do
      begin
        WriteLn(Format('REFUSE  %s  [emit]  %s',
          [ExtractFileName(LPath), E.Message]));
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
