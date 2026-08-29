unit Protogen.Lexer;

// ============================================================================
//  Protogen.Lexer — tokeniser for the proto3 subset.
//
//  C1 of plans/horse-grpc-codegen.md.
//
//  Every token carries Line and Column, and that is not decoration: the whole
//  value of this generator is that it REFUSES unsupported proto3 features by
//  name, and a refusal that cannot say where it is looking is barely better
//  than silence. Positions are 1-based, as every editor reports them.
//
//  Deliberately NOT handled, because the parser rejects the constructs that
//  need them and would rather fail on the construct than on its syntax:
//    - string escapes beyond \" and \\  (only import/option paths are strings)
//    - octal / hex / float literals     (field numbers are plain decimals)
//  If C2 or later needs option values, extend here rather than in the parser.
// ============================================================================

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes;
{$ELSE}
  System.SysUtils, System.Classes;
{$IFEND}

type
  TProtoTokenKind = (
    ptEof,
    ptIdent,      // identifier or keyword — the parser decides which
    ptNumber,     // decimal integer literal
    ptString,     // quoted, Value holds the UNQUOTED text
    ptSymbol      // one of  { } ( ) [ ] < > = ; , .
  );

  TProtoToken = record
    Kind:   TProtoTokenKind;
    Value:  string;
    Line:   Integer;
    Column: Integer;
  end;

  EProtoLexError = class(Exception)
  public
    Line:   Integer;
    Column: Integer;
    constructor CreateAt(ALine, AColumn: Integer; const AMsg: string);
  end;

  TProtoLexer = class
  private
    FText:   string;
    FPos:    Integer;   // 1-based index into FText
    FLine:   Integer;
    FCol:    Integer;
    FCurrent: TProtoToken;
    function  Peek(AOffset: Integer = 0): Char;
    procedure Advance;
    procedure SkipWhitespaceAndComments;
    function  ReadIdent: TProtoToken;
    function  ReadNumber: TProtoToken;
    function  ReadString: TProtoToken;
    function  MakeToken(AKind: TProtoTokenKind; const AValue: string;
                        ALine, ACol: Integer): TProtoToken;
  public
    constructor Create(const AText: string);
    { Reads the next token into Current and returns it. At end of input it
      returns ptEof indefinitely rather than raising — the parser decides
      whether an EOF is unexpected, because only the parser knows what it was
      in the middle of. }
    function Next: TProtoToken;
    property Current: TProtoToken read FCurrent;
  end;

{ Loads a file as text. Strips a UTF-8 BOM if present: a BOM left in place
  becomes part of the first token and turns `syntax` into something that
  matches nothing, with an error pointing at column 1 of a line that looks
  perfectly correct. }
function LoadProtoFile(const AFileName: string): string;

implementation

// ── EProtoLexError ──────────────────────────────────────────────────────────

constructor EProtoLexError.CreateAt(ALine, AColumn: Integer; const AMsg: string);
begin
  inherited CreateFmt('(%d:%d) %s', [ALine, AColumn, AMsg]);
  Line   := ALine;
  Column := AColumn;
end;

// ── TProtoLexer ─────────────────────────────────────────────────────────────

constructor TProtoLexer.Create(const AText: string);
begin
  inherited Create;
  FText := AText;
  FPos  := 1;
  FLine := 1;
  FCol  := 1;
  FCurrent.Kind := ptEof;
end;

function TProtoLexer.Peek(AOffset: Integer): Char;
var
  LIdx: Integer;
begin
  LIdx := FPos + AOffset;
  if (LIdx < 1) or (LIdx > Length(FText)) then
    Result := #0
  else
    Result := FText[LIdx];
end;

procedure TProtoLexer.Advance;
begin
  if FPos > Length(FText) then Exit;
  if FText[FPos] = #10 then
  begin
    Inc(FLine);
    FCol := 1;
  end
  else if FText[FPos] <> #13 then
    Inc(FCol);
  Inc(FPos);
end;

procedure TProtoLexer.SkipWhitespaceAndComments;
var
  LStartLine, LStartCol: Integer;
begin
  while FPos <= Length(FText) do
  begin
    if CharInSet(Peek, [#9, #10, #13, ' ']) then
    begin
      Advance;
      Continue;
    end;

    // Line comment
    if (Peek = '/') and (Peek(1) = '/') then
    begin
      while (FPos <= Length(FText)) and (Peek <> #10) do
        Advance;
      Continue;
    end;

    // Block comment. Not nested — proto3 follows C here, so the FIRST */
    // closes, and a nested /* is just text.
    if (Peek = '/') and (Peek(1) = '*') then
    begin
      LStartLine := FLine;
      LStartCol  := FCol;
      Advance; Advance;
      while True do
      begin
        if FPos > Length(FText) then
          raise EProtoLexError.CreateAt(LStartLine, LStartCol,
            'unterminated block comment — no closing */ before end of file');
        if (Peek = '*') and (Peek(1) = '/') then
        begin
          Advance; Advance;
          Break;
        end;
        Advance;
      end;
      Continue;
    end;

    Break;
  end;
end;

function TProtoLexer.MakeToken(AKind: TProtoTokenKind; const AValue: string;
  ALine, ACol: Integer): TProtoToken;
begin
  Result.Kind   := AKind;
  Result.Value  := AValue;
  Result.Line   := ALine;
  Result.Column := ACol;
end;

function TProtoLexer.ReadIdent: TProtoToken;
var
  LStart, LLine, LCol: Integer;
begin
  LStart := FPos;
  LLine  := FLine;
  LCol   := FCol;
  { Dots are consumed as part of the identifier so that qualified names —
    `google.protobuf.Timestamp`, or a package-qualified message reference —
    arrive as ONE token. The parser needs the whole name to reject a
    well-known type by its full spelling. }
  while CharInSet(Peek, ['A'..'Z', 'a'..'z', '0'..'9', '_', '.']) do
    Advance;
  Result := MakeToken(ptIdent, Copy(FText, LStart, FPos - LStart), LLine, LCol);
end;

function TProtoLexer.ReadNumber: TProtoToken;
var
  LStart, LLine, LCol: Integer;
begin
  LStart := FPos;
  LLine  := FLine;
  LCol   := FCol;
  if CharInSet(Peek, ['-', '+']) then Advance;
  while CharInSet(Peek, ['0'..'9']) do
    Advance;
  Result := MakeToken(ptNumber, Copy(FText, LStart, FPos - LStart), LLine, LCol);
end;

function TProtoLexer.ReadString: TProtoToken;
var
  LQuote: Char;
  LLine, LCol: Integer;
  LBuf: string;
begin
  LLine  := FLine;
  LCol   := FCol;
  LQuote := Peek;
  Advance;
  LBuf := '';
  while True do
  begin
    if FPos > Length(FText) then
      raise EProtoLexError.CreateAt(LLine, LCol,
        'unterminated string literal');
    if Peek = LQuote then
    begin
      Advance;
      Break;
    end;
    if Peek = '\' then
    begin
      Advance;
      if FPos > Length(FText) then
        raise EProtoLexError.CreateAt(LLine, LCol,
          'unterminated escape at end of file');
      LBuf := LBuf + Peek;
      Advance;
      Continue;
    end;
    LBuf := LBuf + Peek;
    Advance;
  end;
  Result := MakeToken(ptString, LBuf, LLine, LCol);
end;

function TProtoLexer.Next: TProtoToken;
var
  LLine, LCol: Integer;
  LCh: Char;
begin
  SkipWhitespaceAndComments;

  if FPos > Length(FText) then
  begin
    FCurrent := MakeToken(ptEof, '', FLine, FCol);
    Exit(FCurrent);
  end;

  LLine := FLine;
  LCol  := FCol;
  LCh   := Peek;

  if CharInSet(LCh, ['A'..'Z', 'a'..'z', '_']) then
    FCurrent := ReadIdent
  else if CharInSet(LCh, ['0'..'9']) or
          (CharInSet(LCh, ['-', '+']) and CharInSet(Peek(1), ['0'..'9'])) then
    FCurrent := ReadNumber
  else if CharInSet(LCh, ['"', '''']) then
    FCurrent := ReadString
  else if CharInSet(LCh, ['{', '}', '(', ')', '[', ']', '<', '>', '=', ';', ',', '.']) then
  begin
    Advance;
    FCurrent := MakeToken(ptSymbol, LCh, LLine, LCol);
  end
  else
    raise EProtoLexError.CreateAt(LLine, LCol,
      Format('unexpected character %s in .proto source', [QuotedStr(LCh)]));

  Result := FCurrent;
end;

// ── File loading ────────────────────────────────────────────────────────────

function LoadProtoFile(const AFileName: string): string;
var
  LStrings: TStringList;
begin
  LStrings := TStringList.Create;
  try
    LStrings.LoadFromFile(AFileName);
    Result := LStrings.Text;
  finally
    LStrings.Free;
  end;

  { Strip a UTF-8 BOM, in BOTH the forms it can reach us in. On Delphi the
    loader decodes it to a single U+FEFF; on FPC, where string is AnsiString,
    it survives as the three raw bytes EF BB BF. Handling only one of those
    leaves the BOM glued to the first token on the other compiler, so `syntax`
    matches nothing and the error points at column 1 of a line that looks
    perfectly correct. }
  { Guarded on SizeOf(Char) rather than on the compiler, because that IS the
    discriminator: a 1-byte Char cannot hold $FEFF, so on FPC the first branch
    is provably dead and the compiler says so ("comparison might be always
    false" plus "unreachable code"). Compiling it out keeps the build clean
    without pretending the difference is about Delphi-vs-FPC. }
{$IF SizeOf(Char) > 1}
  if (Length(Result) >= 1) and (Ord(Result[1]) = $FEFF) then
  begin
    Delete(Result, 1, 1);
    Exit;
  end;
{$IFEND}
  if (Length(Result) >= 3)
     and (Ord(Result[1]) = $EF)
     and (Ord(Result[2]) = $BB)
     and (Ord(Result[3]) = $BF) then
    Delete(Result, 1, 3);
end;

end.
