program Nghttp2GrpcFramingTests;

// ============================================================================
//  Nghttp2GrpcFramingTests - the gRPC length-prefix framing layer, in
//  isolation and under adversarial chunking.
//
//  WHY THIS EXISTS
//  ---------------
//  Nghttp2.Grpc.StreamReader's own header states the failure mode precisely:
//
//      gRPC messages are [flag][4-byte big-endian length][payload], and they
//      have NO relationship to DATA frame boundaries. A single frame may carry
//      three messages and half of a fourth; a single message may span many
//      frames. Decoding per frame - the obvious mistake - works perfectly
//      against a test client that sends one message per frame and corrupts
//      against every real one.
//
//  Until this file, nothing tested that. The reassembly buffer was exercised
//  only end-to-end by the M6a/M6b streaming suites, where the chunk boundaries
//  are whatever the client and the HTTP/2 layer happened to produce - which is
//  exactly the "one message per frame" shape the warning is about. A reader
//  that decoded per chunk would have passed all 24 of those checks.
//
//  So the variable under test here is the CHOP PATTERN, not the payload. The
//  same byte stream is delivered a dozen different ways and must yield the
//  identical message sequence every time.
//
//  WHAT THIS DELIBERATELY DOES NOT CLAIM
//  -------------------------------------
//  This is not a cross-implementation interop check, and pretending otherwise
//  would overstate it. The 5-byte header is a one-line spec (uint8 flag,
//  uint32 big-endian length); a second implementation of it agrees by
//  construction, so "another language produced the same 5 bytes" is weak
//  evidence in a way that google.protobuf agreeing about varints is not.
//  Section 01 still pins the byte layout, because it is nearly free and it
//  catches an endianness or offset regression - but the value of this file is
//  sections 03-05, which need no external reference at all.
//
//  GC0 (lib 1.28.0, B2 client plan) added sections 07-09. The framing moved
//  to Nghttp2.Grpc.Framing so the gRPC client can share it; 07 pins that the
//  server's old names still give the same bytes and the same error TEXTS
//  (literals copied from the pre-GC0 code), 08 tests the shared reassembler
//  directly with the chunk sizes a client's ReadChunk produces, 09 the
//  grpc-message decoder a client needs.
//
//  Malformed input is covered separately by Nghttp2ProtobufNegativeTests
//  section 05 (F1/F3) and is not duplicated here.
//
//  Convention matches the sibling suites: PASS/FAIL per check, ExitCode is the
//  failure count.
//
//  Build (Windows):
//    dcc64 -CC -B -U"..\src" Nghttp2GrpcFramingTests.dpr
//
//  Build (FPC trunk) - see Nghttp2ProtobufNegativeTests.dpr for the full -Fu
//  rationale; -dNGHTTP2_GRPC_NO_FFI applies here for the same reason (nothing
//  in this file dispatches a call, so libffi is not needed).
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}
{$M+}

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$IFEND}
  Nghttp2.Types,
  Nghttp2.Protobuf,
  Nghttp2.Protobuf.Rtti,
  { IGrpcStreamReader is declared in Grpc.Registry, NOT in Grpc.StreamReader -
    the unit named after the reader holds only the CLASS. Registry is also what
    drags in ffi.manager, which is why -dNGHTTP2_GRPC_NO_FFI is required on FPC
    here exactly as it is for Nghttp2ProtobufNegativeTests. }
  Nghttp2.Grpc.Registry,       // IGrpcStreamReader
  Nghttp2.Grpc.Dispatcher,     // StripGrpcPrefix, GrpcPercentEncode
  Nghttp2.Grpc.StreamWriter,   // WrapGrpcMessage
  Nghttp2.Grpc.StreamReader,   // TGrpcStreamReader, GRPC_MAX_MESSAGE_BYTES
  Nghttp2.Grpc.Framing;        // GC0 - the shared framing unit (sections 07-09)

{$IF DEFINED(FPC)}
  {$RTTI EXPLICIT PROPERTIES([vcPublished]) FIELDS([vcPublic]) METHODS([vcPublic])}
{$ENDIF}

type
  { The message the reassembly tests carry. Deliberately tiny and
    variable-length: `text` lets each message in a stream be a different size,
    which is what makes an off-by-one in the length prefix show up as the WRONG
    message rather than as a crash. }
  [TGrpcMessage]
  TFrameMsg = class
  private
    Fid:   Integer;
    Ftext: string;
  published
    [TProtoMember(1)] property id:   Integer read Fid   write Fid;
    [TProtoMember(2)] property text: string  read Ftext write Ftext;
  end;

  { How the fake stream hands bytes to the reader. This is the independent
    variable of the whole file. }
  TChopMode = (
    cmAllAtOnce,      // one giant read - the degenerate easy case
    cmOneByte,        // 1 byte per read - maximum fragmentation
    cmHeaderThenRest, // 5 bytes, then everything - header alone in a read
    cmSplitLength,    // 2 bytes, then everything - splits the length FIELD
    cmSixByte,        // 6 bytes per read - header plus one payload byte
    cmFortyByte,      // 40 bytes per read - spans whole messages + fragments
    cmSevenByte       // 7 bytes per read - lands mid-header and mid-payload
  );

  { A fake INghttp2Stream that serves a fixed byte buffer according to a chop
    mode, then reports end-of-stream.

    Only ReadInbound and IsStreamAlive are reachable from TGrpcStreamReader;
    every other member raises, so a future reader change that starts depending
    on one fails loudly here instead of silently reading a default. That is
    deliberate - a fake returning bland zeros is how a test keeps passing while
    the thing it tests moves out from under it. }
  TFakeInboundStream = class(TInterfacedObject, INghttp2Stream)
  private
    FData:    TBytes;
    FPos:     Integer;
    FMode:    TChopMode;
    FReads:   Integer;
    function NextChunkSize: Integer;
    procedure NotUsed(const AWho: string);
  public
    constructor Create(const AData: TBytes; AMode: TChopMode);
    property Reads: Integer read FReads;

    // -- the two members actually under test --
    function ReadInbound(var ABuffer: TBytes; ACount: Integer;
      ATimeoutMS: Integer): Integer;
    function IsStreamAlive: Boolean;

    // -- everything else: present to satisfy the interface, never called --
    function  GetHeader(const AName: string): string;
    procedure SetHeader(const AName, AValue: string);
    procedure AddHeader(const AName, AValue: string);
    function  GetBody: TStream;
    function  GetConnection: INghttp2Connection;
    procedure PopulateRequestHeadersInto(const ADest: TStrings);
    function  GetStatusCode: Integer;
    procedure SetStatusCode(const AValue: Integer);
    procedure Send(const AData: TBytes);
    procedure SendStream(const ASource: TStream);
    procedure AddTrailer(const AName, AValue: string);
    procedure BeginStreaming;
    procedure PushStreamData(const AData: TBytes);
    procedure EndStreaming;
    function  InboundStreaming: Boolean;
    function  InboundEnded: Boolean;
    procedure BeginAsyncDispatch;
    procedure EndAsyncDispatch;
  end;

var
  GPass: Integer = 0;
  GFail: Integer = 0;

procedure Check(const AName: string; APassed: Boolean; const ADetail: string = '');
begin
  if APassed then
  begin
    Inc(GPass);
    WriteLn('  PASS  ', AName);
  end
  else
  begin
    Inc(GFail);
    if ADetail <> '' then
      WriteLn('  FAIL  ', AName, '  <- ', ADetail)
    else
      WriteLn('  FAIL  ', AName);
  end;
end;

// ── TFakeInboundStream ──────────────────────────────────────────────────────

constructor TFakeInboundStream.Create(const AData: TBytes; AMode: TChopMode);
begin
  inherited Create;
  FData  := AData;
  FPos   := 0;
  FMode  := AMode;
  FReads := 0;
end;

procedure TFakeInboundStream.NotUsed(const AWho: string);
begin
  raise Exception.CreateFmt(
    'TFakeInboundStream.%s was called. This fake implements only ReadInbound ' +
    'and IsStreamAlive; if the reader now needs %s, the fake must model it ' +
    'deliberately rather than return a default.', [AWho, AWho]);
end;

{ The chop policy. Returns how many bytes the NEXT read should hand over. }
function TFakeInboundStream.NextChunkSize: Integer;
begin
  case FMode of
    cmAllAtOnce:      Result := MaxInt;
    cmOneByte:        Result := 1;
    cmHeaderThenRest: if FReads = 0 then Result := 5 else Result := MaxInt;
    cmSplitLength:    if FReads = 0 then Result := 2 else Result := MaxInt;
    cmSixByte:        Result := 6;
    cmFortyByte:      Result := 40;
    cmSevenByte:      Result := 7;
  else
    Result := MaxInt;
  end;
end;

function TFakeInboundStream.ReadInbound(var ABuffer: TBytes; ACount: Integer;
  ATimeoutMS: Integer): Integer;
var
  LWant: Integer;
begin
  if FPos >= Length(FData) then
    Exit(0);                       // end of stream, per the interface contract

  LWant := NextChunkSize;
  if LWant > ACount then LWant := ACount;
  if LWant > Length(FData) - FPos then LWant := Length(FData) - FPos;

  SetLength(ABuffer, LWant);
  Move(FData[FPos], ABuffer[0], LWant);
  Inc(FPos, LWant);
  Inc(FReads);
  Result := LWant;
end;

function TFakeInboundStream.IsStreamAlive: Boolean;
begin
  Result := FPos < Length(FData);
end;

function  TFakeInboundStream.GetHeader(const AName: string): string;
begin NotUsed('GetHeader'); Result := ''; end;
procedure TFakeInboundStream.SetHeader(const AName, AValue: string);
begin NotUsed('SetHeader'); end;
procedure TFakeInboundStream.AddHeader(const AName, AValue: string);
begin NotUsed('AddHeader'); end;
function  TFakeInboundStream.GetBody: TStream;
begin NotUsed('GetBody'); Result := nil; end;
function  TFakeInboundStream.GetConnection: INghttp2Connection;
begin NotUsed('GetConnection'); Result := nil; end;
procedure TFakeInboundStream.PopulateRequestHeadersInto(const ADest: TStrings);
begin NotUsed('PopulateRequestHeadersInto'); end;
function  TFakeInboundStream.GetStatusCode: Integer;
begin NotUsed('GetStatusCode'); Result := 0; end;
procedure TFakeInboundStream.SetStatusCode(const AValue: Integer);
begin NotUsed('SetStatusCode'); end;
procedure TFakeInboundStream.Send(const AData: TBytes);
begin NotUsed('Send'); end;
procedure TFakeInboundStream.SendStream(const ASource: TStream);
begin NotUsed('SendStream'); end;
procedure TFakeInboundStream.AddTrailer(const AName, AValue: string);
begin NotUsed('AddTrailer'); end;
procedure TFakeInboundStream.BeginStreaming;
begin NotUsed('BeginStreaming'); end;
procedure TFakeInboundStream.PushStreamData(const AData: TBytes);
begin NotUsed('PushStreamData'); end;
procedure TFakeInboundStream.EndStreaming;
begin NotUsed('EndStreaming'); end;
function  TFakeInboundStream.InboundStreaming: Boolean;
begin Result := True; end;
function  TFakeInboundStream.InboundEnded: Boolean;
begin Result := FPos >= Length(FData); end;
procedure TFakeInboundStream.BeginAsyncDispatch;
begin NotUsed('BeginAsyncDispatch'); end;
procedure TFakeInboundStream.EndAsyncDispatch;
begin NotUsed('EndAsyncDispatch'); end;

// ── helpers ─────────────────────────────────────────────────────────────────

function BytesEqual(const A, B: TBytes): Boolean;
var
  I: Integer;
begin
  if Length(A) <> Length(B) then Exit(False);
  for I := 0 to High(A) do
    if A[I] <> B[I] then Exit(False);
  Result := True;
end;

function Concat2(const A, B: TBytes): TBytes;
begin
  SetLength(Result, Length(A) + Length(B));
  if Length(A) > 0 then Move(A[0], Result[0], Length(A));
  if Length(B) > 0 then Move(B[0], Result[Length(A)], Length(B));
end;

{ Builds one framed gRPC message carrying (AId, AText). }
function FrameOf(AId: Integer; const AText: string): TBytes;
var
  LMsg: TFrameMsg;
begin
  LMsg := TFrameMsg.Create;
  try
    LMsg.id   := AId;
    LMsg.text := AText;
    Result := WrapGrpcMessage(TProtoSerializer.Serialize(LMsg));
  finally
    LMsg.Free;
  end;
end;

function ModeName(AMode: TChopMode): string;
begin
  case AMode of
    cmAllAtOnce:      Result := 'all-at-once';
    cmOneByte:        Result := 'one-byte';
    cmHeaderThenRest: Result := 'header-then-rest';
    cmSplitLength:    Result := 'split-length';
    cmSixByte:        Result := 'six-byte';
    cmFortyByte:      Result := 'forty-byte';
    cmSevenByte:      Result := 'seven-byte';
  else
    Result := '?';
  end;
end;

// ── 01  header byte layout ──────────────────────────────────────────────────

procedure TestHeaderLayout;
var
  LOut: TBytes;
  LBody: TBytes;
begin
  WriteLn;
  WriteLn('-- 01  WrapGrpcMessage header byte layout');

  SetLength(LBody, 0);
  LOut := WrapGrpcMessage(LBody);
  Check('empty payload is exactly the 5-byte prefix', Length(LOut) = 5);
  Check('empty payload: flag 0, length 0',
        (LOut[0] = 0) and (LOut[1] = 0) and (LOut[2] = 0) and
        (LOut[3] = 0) and (LOut[4] = 0));

  SetLength(LBody, 1);
  LBody[0] := $AB;
  LOut := WrapGrpcMessage(LBody);
  Check('1-byte payload: total 6', Length(LOut) = 6);
  Check('1-byte payload: length field = 1', LOut[4] = 1);
  Check('1-byte payload: body preserved', LOut[5] = $AB);

  { 258 = $0102. Big-endian means byte[3]=$01 and byte[4]=$02; a
    little-endian slip would put $02 before $01 and this is the check that
    sees it. 258 is chosen because both halves are non-zero and unequal. }
  SetLength(LBody, 258);
  FillChar(LBody[0], 258, $5A);
  LOut := WrapGrpcMessage(LBody);
  Check('258-byte payload: total 263', Length(LOut) = 263);
  Check('258-byte payload: big-endian length $00 $00 $01 $02',
        (LOut[1] = $00) and (LOut[2] = $00) and
        (LOut[3] = $01) and (LOut[4] = $02),
        Format('got %.2x %.2x %.2x %.2x', [LOut[1], LOut[2], LOut[3], LOut[4]]));

  { 65793 = $010101 - exercises the third length byte, which a shift-by-8
    error leaves at zero while the other two still look right. }
  SetLength(LBody, 65793);
  FillChar(LBody[0], 65793, $77);
  LOut := WrapGrpcMessage(LBody);
  Check('65793-byte payload: big-endian length $00 $01 $01 $01',
        (LOut[1] = $00) and (LOut[2] = $01) and
        (LOut[3] = $01) and (LOut[4] = $01),
        Format('got %.2x %.2x %.2x %.2x', [LOut[1], LOut[2], LOut[3], LOut[4]]));
end;

// ── 02  Wrap -> Strip round-trip ────────────────────────────────────────────

procedure TestWrapStripRoundTrip;
var
  LBody, LFramed, LBack: TBytes;
  LErr: string;
  I: Integer;
begin
  WriteLn;
  WriteLn('-- 02  WrapGrpcMessage -> StripGrpcPrefix round-trip');

  SetLength(LBody, 0);
  LFramed := WrapGrpcMessage(LBody);
  Check('empty message strips cleanly', StripGrpcPrefix(LFramed, LBack, LErr));
  Check('empty message body length 0', Length(LBack) = 0);

  SetLength(LBody, 300);
  for I := 0 to 299 do
    LBody[I] := Byte(I and $FF);
  LFramed := WrapGrpcMessage(LBody);
  Check('300-byte message strips cleanly', StripGrpcPrefix(LFramed, LBack, LErr), LErr);
  Check('300-byte message body identical', BytesEqual(LBody, LBack));

  { Trailing bytes past the declared length: the unary path is defined to take
    the FIRST message and ignore the remainder. Asserted so that behaviour is
    pinned rather than incidental - a future change to consume-or-reject here
    would alter what a client sending two messages to a unary method sees. }
  LFramed := Concat2(WrapGrpcMessage(LBody), WrapGrpcMessage(LBody));
  Check('two concatenated frames: strip takes the first',
        StripGrpcPrefix(LFramed, LBack, LErr), LErr);
  Check('two concatenated frames: first body intact',
        BytesEqual(LBody, LBack));
end;

// ── 03  reassembly under every chop pattern ─────────────────────────────────

{ The core of the file. One byte stream of five messages of deliberately
  different lengths, delivered seven different ways, must always yield the same
  five messages in the same order. }
procedure TestReassembly;
const
  CTexts: array[0..4] of string =
    ('', 'a', 'hello world', '', 'the quick brown fox jumps over the lazy dog');
var
  LMode: TChopMode;
  LStream: TFakeInboundStream;
  LReader: IGrpcStreamReader;
  LStreamIntf: INghttp2Stream;
  LAll: TBytes;
  LObj: TObject;
  LGot: Integer;
  LOk: Boolean;
  LDetail: string;
  I: Integer;
  LReads: array[TChopMode] of Integer;
begin
  WriteLn;
  WriteLn('-- 03  reassembly: same stream, every chop pattern');

  SetLength(LAll, 0);
  for I := 0 to High(CTexts) do
    LAll := Concat2(LAll, FrameOf(I, CTexts[I]));

  WriteLn(Format('     stream: %d messages, %d bytes total',
                 [Length(CTexts), Length(LAll)]));

  for LMode := Low(TChopMode) to High(TChopMode) do
  begin
    LStream     := TFakeInboundStream.Create(LAll, LMode);
    LStreamIntf := LStream;
    LReader     := TGrpcStreamReader.Create(LStreamIntf, TFrameMsg);

    LGot    := 0;
    LOk     := True;
    LDetail := '';
    try
      while LReader.Next(LObj) do
      begin
        if LGot > High(CTexts) then
        begin
          LOk := False;
          LDetail := 'more messages than were sent';
          Break;
        end;
        if TFrameMsg(LObj).id <> LGot then
        begin
          LOk := False;
          LDetail := Format('message %d has id %d', [LGot, TFrameMsg(LObj).id]);
          Break;
        end;
        if TFrameMsg(LObj).text <> CTexts[LGot] then
        begin
          LOk := False;
          LDetail := Format('message %d text mismatch: got "%s"',
                            [LGot, TFrameMsg(LObj).text]);
          Break;
        end;
        Inc(LGot);
      end;
    except
      on E: Exception do
      begin
        LOk := False;
        LDetail := E.ClassName + ': ' + E.Message;
      end;
    end;

    if LOk and (LGot <> Length(CTexts)) then
    begin
      LOk := False;
      LDetail := Format('recovered %d of %d messages', [LGot, Length(CTexts)]);
    end;

    { Captured BEFORE the interface refs drop - LStream is freed with them. }
    LReads[LMode] := LStream.Reads;

    Check(Format('%-16s -> 5 messages, in order, intact  (%d reads)',
                 [ModeName(LMode), LReads[LMode]]),
          LOk, LDetail);

    LReader     := nil;
    LStreamIntf := nil;
  end;

  { INSTRUMENT CHECK - without this the seven rows above could all be the same
    delivery pattern, and the suite would prove one thing seven times while
    reading as thorough coverage. A test whose instrument cannot be OBSERVED to
    have taken effect is void, not passing: the chop modes must be shown to
    have actually chopped differently.

    one-byte must take one read per byte, and all-at-once exactly one. If those
    two ever converge, NextChunkSize is being ignored - most likely because the
    reader started requesting a fixed ACount that clamps the fake. }
  Check(Format('instrument: one-byte really did %d reads (= stream length)',
               [LReads[cmOneByte]]),
        LReads[cmOneByte] = Length(LAll),
        Format('expected %d, got %d', [Length(LAll), LReads[cmOneByte]]));
  Check('instrument: all-at-once really did 1 read',
        LReads[cmAllAtOnce] = 1,
        Format('got %d', [LReads[cmAllAtOnce]]));
  Check('instrument: the two extremes differ',
        LReads[cmOneByte] > LReads[cmAllAtOnce]);
end;

// ── 04  half-close mid-message is reported, not swallowed ───────────────────

procedure TestTruncatedStream;
var
  LFull, LCut: TBytes;
  LStream: TFakeInboundStream;
  LStreamIntf: INghttp2Stream;
  LReader: IGrpcStreamReader;
  LObj: TObject;
  LRaised: Boolean;
  LMsg: string;
begin
  WriteLn;
  WriteLn('-- 04  peer half-closes mid-message');

  LFull := FrameOf(1, 'this message will be cut in half');
  SetLength(LCut, Length(LFull) - 4);
  Move(LFull[0], LCut[0], Length(LCut));

  LStream     := TFakeInboundStream.Create(LCut, cmAllAtOnce);
  LStreamIntf := LStream;
  LReader     := TGrpcStreamReader.Create(LStreamIntf, TFrameMsg);

  LRaised := False;
  LMsg    := '';
  try
    LReader.Next(LObj);
  except
    on E: Exception do
    begin
      LRaised := True;
      LMsg    := E.Message;
    end;
  end;

  Check('truncated message raises rather than returning False', LRaised);
  Check('the error names the incomplete message',
        LRaised and (Pos('incomplete', LowerCase(LMsg)) > 0), LMsg);

  LReader     := nil;
  LStreamIntf := nil;
end;

// ── 05  a clean stream of zero messages ends without error ──────────────────

procedure TestEmptyStream;
var
  LNone: TBytes;
  LStream: TFakeInboundStream;
  LStreamIntf: INghttp2Stream;
  LReader: IGrpcStreamReader;
  LObj: TObject;
  LOk: Boolean;
begin
  WriteLn;
  WriteLn('-- 05  empty stream');

  SetLength(LNone, 0);
  LStream     := TFakeInboundStream.Create(LNone, cmAllAtOnce);
  LStreamIntf := LStream;
  LReader     := TGrpcStreamReader.Create(LStreamIntf, TFrameMsg);

  LOk := False;
  try
    LOk := not LReader.Next(LObj);
  except
    on E: Exception do
      LOk := False;
  end;
  Check('zero-message stream returns False without raising', LOk);

  LReader     := nil;
  LStreamIntf := nil;
end;

// -- 06  grpc-message percent-encoding (GRPC-ERRMSG-1) -----------------------

{ A string from explicit UTF-8 bytes. The source file is BOM-less ASCII, so a
  non-ASCII literal would be read in whatever codepage the compiler assumes;
  building the text from bytes pins the input on both compilers. }
function Utf8Text(const ABytes: array of Byte): string;
var
  LBytes: TBytes;
  I: Integer;
begin
  SetLength(LBytes, Length(ABytes));
  for I := 0 to High(ABytes) do
    LBytes[I] := ABytes[I];
  Result := TEncoding.UTF8.GetString(LBytes);
end;

procedure ExpectEncoded(const AName, AInput, AExpected: string);
var
  LGot: string;
begin
  LGot := GrpcPercentEncode(AInput);
  Check(AName, LGot = AExpected,
    Format('expected "%s", got "%s"', [AExpected, LGot]));
end;

procedure TestPercentEncode;
begin
  WriteLn;
  WriteLn('-- 06  grpc-message percent-encoding (GRPC-ERRMSG-1)');

  ExpectEncoded('plain ASCII passes through unchanged',
    'method not registered: /greeter.Greeter/DoesNotExist',
    'method not registered: /greeter.Greeter/DoesNotExist');
  ExpectEncoded('space and ~ (0x20, 0x7E, the range ends) pass through',
    'a b~c', 'a b~c');
  ExpectEncoded('a literal % is encoded, or the client would decode it',
    '100%', '100%25');
  ExpectEncoded('an already-encoded-looking %41 is encoded, not trusted',
    'x%41', 'x%2541');
  ExpectEncoded('CR LF are encoded (a header value must not carry them)',
    'a'#13#10'b', 'a%0D%0Ab');
  ExpectEncoded('DEL (0x7F) is encoded', 'a'#127, 'a%7F');
  ExpectEncoded('2-byte UTF-8 (U+00E7) becomes its two bytes',
    Utf8Text([$C3, $A7]), '%C3%A7');
  { U+1F600 is a surrogate PAIR in a Delphi string. Encoding per Char would
    emit the two surrogates separately (invalid UTF-8); encoding the UTF-8
    bytes gives the four bytes a client decodes back to the one character. }
  ExpectEncoded('4-byte UTF-8 (U+1F600) becomes its four bytes',
    Utf8Text([$F0, $9F, $98, $80]), '%F0%9F%98%80');
  ExpectEncoded('upper-case hex digits',
    Utf8Text([$C3, $BF]), '%C3%BF');
  ExpectEncoded('empty stays empty', '', '');
end;

// -- 07  GC0: the server's names keep their bytes and their error texts ------

{ GC0 moved the framing into Nghttp2.Grpc.Framing and left the old names as
  one-line delegations. Comparing old name with new name would be true by
  construction, so the pins here are LITERALS, copied from the pre-GC0
  sources: the exact error texts a client of StripGrpcPrefix, or a peer of
  TGrpcStreamReader, used to receive. If GC0 changed any of them, this fails. }

function ByteArr(const A: array of Byte): TBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I];
end;

{ ACount bytes of a non-repeating-looking pattern, so a shifted or truncated
  copy does not compare equal by accident. }
function PatternBytes(ACount: Integer): TBytes;
var
  I: Integer;
begin
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
    Result[I] := Byte((I * 7 + 3) and $FF);
end;

procedure ExpectStripError(const AName: string; const AData: TBytes;
  const AExpected: string);
var
  LOk:   Boolean;
  LBody: TBytes;
  LErr:  string;
begin
  LOk := StripGrpcPrefix(AData, LBody, LErr);
  Check(AName, (not LOk) and (LErr = AExpected),
    Format('expected "%s", got ok=%s "%s"', [AExpected, BoolToStr(LOk, True), LErr]));
end;

procedure ExpectReaderError(const AName: string; const AData: TBytes;
  const AExpected: string);
var
  LStream:     TFakeInboundStream;
  LStreamIntf: INghttp2Stream;
  LReader:     IGrpcStreamReader;
  LObj:        TObject;
  LMsg:        string;
begin
  LStream     := TFakeInboundStream.Create(AData, cmAllAtOnce);
  LStreamIntf := LStream;
  LReader     := TGrpcStreamReader.Create(LStreamIntf, TFrameMsg);
  LMsg := '(no exception)';
  try
    LReader.Next(LObj);
  except
    on E: Exception do
      LMsg := E.Message;
  end;
  Check(AName, LMsg = AExpected,
    Format('expected "%s", got "%s"', [AExpected, LMsg]));
  LReader     := nil;
  LStreamIntf := nil;
end;

procedure TestCompatibility;
var
  LPayload: TBytes;
  I:        Integer;
  LSizes:   array[0..4] of Integer;
  LOk:      Boolean;
begin
  WriteLn;
  WriteLn('-- 07  GC0 compatibility: old names, same bytes, same texts');

  Check('GRPC_MAX_MESSAGE_BYTES is still 4194304',
    GRPC_MAX_MESSAGE_BYTES = 4194304, IntToStr(GRPC_MAX_MESSAGE_BYTES));
  Check('GRPC_DEFAULT_MAX_MESSAGE_BYTES equals it',
    GRPC_DEFAULT_MAX_MESSAGE_BYTES = GRPC_MAX_MESSAGE_BYTES);

  LSizes[0] := 0; LSizes[1] := 1; LSizes[2] := 255; LSizes[3] := 256;
  LSizes[4] := 65539;
  LOk := True;
  for I := 0 to High(LSizes) do
  begin
    LPayload := PatternBytes(LSizes[I]);
    if not BytesEqual(WrapGrpcMessage(LPayload), GrpcFrameMessage(LPayload)) then
      LOk := False;
  end;
  Check('WrapGrpcMessage = GrpcFrameMessage for 0, 1, 255, 256, 65539 bytes', LOk);

  ExpectStripError('unary: short buffer, same text',
    ByteArr([$00, $00, $00]),
    'gRPC frame too short (< 5-byte prefix)');
  ExpectStripError('unary: compression flag, same text',
    ByteArr([$01, $00, $00, $00, $01, $AA]),
    'gRPC compression flag set (per-message compression not supported in v0.1)');
  ExpectStripError('unary: over the cap, same text',
    ByteArr([$00, $00, $40, $00, $01, $AA]),
    'gRPC message length 4194305 exceeds the 4194304-byte maximum');
  ExpectStripError('unary: length $FFFFFFFF, same text (F1)',
    ByteArr([$00, $FF, $FF, $FF, $FF, $01]),
    'gRPC message length 4294967295 exceeds the 4194304-byte maximum');
  ExpectStripError('unary: truncated, same text',
    ByteArr([$00, $00, $00, $00, $64, $01, $02, $03]),
    'gRPC frame truncated: header says 100 bytes, buffer has 3');

  ExpectReaderError('stream: compression flag, same text',
    ByteArr([$01, $00, $00, $00, $01, $AA]),
    'gRPC stream: per-message compression is not supported');
  { Header only: the cap must fire before any payload arrives. }
  ExpectReaderError('stream: over the cap, same text, judged on the header',
    ByteArr([$00, $00, $40, $00, $01]),
    'gRPC stream: message length 4194305 exceeds the 4194304-byte limit');
  ExpectReaderError('stream: half-close mid-message, same text',
    ByteArr([$00, $00, $00, $00, $0A, $01, $02, $03]),
    'gRPC stream: peer half-closed with 8 bytes of an incomplete message');
end;

// -- 08  TGrpcMessageReassembler, directly ------------------------------------

type
  TPayloadList = array of TBytes;

{ Feeds AData to a fresh reassembler AChunk bytes at a time, draining after
  every append, as a client reading ReadChunk will. Stops at the first error. }
function FeedChopped(const AData: TBytes; AChunk: Integer; out AError: string;
  out ALeftover: Integer): TPayloadList;
var
  R:        TGrpcMessageReassembler;
  LPos:     Integer;
  LTake:    Integer;
  LPiece:   TBytes;
  LPayload: TBytes;
  LRes:     TGrpcFrameResult;
begin
  SetLength(Result, 0);
  AError    := '';
  ALeftover := 0;
  R := TGrpcMessageReassembler.Create;
  try
    LPos := 0;
    LRes := gfrNeedMore;
    while (LPos < Length(AData)) and (LRes <> gfrError) do
    begin
      LTake := AChunk;
      if LTake > Length(AData) - LPos then
        LTake := Length(AData) - LPos;
      SetLength(LPiece, LTake);
      Move(AData[LPos], LPiece[0], LTake);
      Inc(LPos, LTake);
      R.Append(LPiece);
      repeat
        LRes := R.TryNext(LPayload, AError);
        if LRes = gfrMessage then
        begin
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := LPayload;
        end;
      until LRes <> gfrMessage;
    end;
    ALeftover := R.BufferedBytes;
  finally
    R.Free;
  end;
end;

procedure TestReassembler;
const
  CChunks: array[0..6] of Integer = (1, 2, 5, 6, 7, 40, MaxInt);
var
  LParts:   array[0..4] of TBytes;
  LAll:     TBytes;
  LPayload: TBytes;
  LGot:     TPayloadList;
  LErr:     string;
  LLeft:    Integer;
  I, J:     Integer;
  LOk:      Boolean;
  LRaised:  Boolean;
  R:        TGrpcMessageReassembler;
begin
  WriteLn;
  WriteLn('-- 08  TGrpcMessageReassembler (GC0) - shared by client and server');

  { Two empty messages, and one over 64 KB so the length uses three bytes. }
  LParts[0] := PatternBytes(0);
  LParts[1] := PatternBytes(1);
  LParts[2] := PatternBytes(300);
  LParts[3] := PatternBytes(0);
  LParts[4] := PatternBytes(70000);
  SetLength(LAll, 0);
  for I := 0 to 4 do
    LAll := Concat2(LAll, GrpcFrameMessage(LParts[I]));

  for J := 0 to High(CChunks) do
  begin
    LGot := FeedChopped(LAll, CChunks[J], LErr, LLeft);
    LOk := (LErr = '') and (LLeft = 0) and (Length(LGot) = 5);
    if LOk then
      for I := 0 to 4 do
        if not BytesEqual(LGot[I], LParts[I]) then
          LOk := False;
    Check(Format('5 messages in %d-byte chunks: same messages, same order',
      [CChunks[J]]), LOk,
      Format('got %d messages, %d bytes left, error "%s"', [Length(LGot), LLeft, LErr]));
  end;

  R := TGrpcMessageReassembler.Create;
  try
    R.Append(Concat2(GrpcFrameMessage(LParts[2]), GrpcFrameMessage(LParts[1])));
    LOk := (R.TryNext(LPayload, LErr) = gfrMessage) and BytesEqual(LPayload, LParts[2]);
    LOk := LOk and (R.TryNext(LPayload, LErr) = gfrMessage) and BytesEqual(LPayload, LParts[1]);
    LOk := LOk and (R.TryNext(LPayload, LErr) = gfrNeedMore) and (R.BufferedBytes = 0);
    Check('two messages in one append: both, in order, then need-more', LOk);
  finally
    R.Free;
  end;

  R := TGrpcMessageReassembler.Create;
  try
    R.Append(ByteArr([$00, $00, $00]));
    LOk := (R.TryNext(LPayload, LErr) = gfrNeedMore) and (R.BufferedBytes = 3);
    Check('3 header bytes: need-more, 3 buffered', LOk);
    R.Append(ByteArr([$00, $02, $AA]));
    LOk := (R.TryNext(LPayload, LErr) = gfrNeedMore) and (R.BufferedBytes = 6);
    Check('header + 1 of 2 payload bytes: need-more, 6 buffered', LOk);
    R.Append(ByteArr([$BB]));
    LOk := (R.TryNext(LPayload, LErr) = gfrMessage) and
           BytesEqual(LPayload, ByteArr([$AA, $BB])) and (R.BufferedBytes = 0);
    Check('last payload byte: the message, nothing buffered', LOk);
  finally
    R.Free;
  end;

  R := TGrpcMessageReassembler.Create;
  try
    R.Append(ByteArr([$00, $00, $00, $00, $01, $CC, $DD, $EE]), 6);
    LOk := (R.TryNext(LPayload, LErr) = gfrMessage) and
           BytesEqual(LPayload, ByteArr([$CC])) and (R.BufferedBytes = 0);
    Check('Append(chunk, 6) takes 6 bytes, not the whole chunk', LOk);
    R.Append(ByteArr([$00, $00, $00, $00, $00]));
    LOk := (R.TryNext(LPayload, LErr) = gfrMessage) and (Length(LPayload) = 0);
    Check('zero-length message is a message, not need-more', LOk);
  finally
    R.Free;
  end;

  { The cap, at the boundary, with a small maximum so no test allocates 4 MB. }
  R := TGrpcMessageReassembler.Create(16);
  try
    R.Append(ByteArr([$00, $00, $00, $00, $10]));
    Check('length = maximum (16): need-more, not an error',
      R.TryNext(LPayload, LErr) = gfrNeedMore, LErr);
  finally
    R.Free;
  end;
  R := TGrpcMessageReassembler.Create(16);
  try
    R.Append(ByteArr([$00, $00, $00, $00, $11]));
    Check('length = maximum + 1 (17): error on the header alone',
      (R.TryNext(LPayload, LErr) = gfrError) and
      (LErr = 'message length 17 exceeds the 16-byte limit'), LErr);
    R.Append(PatternBytes(17));
    Check('an error is terminal: more bytes do not clear it',
      R.TryNext(LPayload, LErr) = gfrError, LErr);
  finally
    R.Free;
  end;

  R := TGrpcMessageReassembler.Create;
  try
    R.Append(ByteArr([$00, $FF, $FF, $FF, $FF, $01]));
    Check('length $FFFFFFFF: error, no allocation (F1 analogue)',
      R.TryNext(LPayload, LErr) = gfrError, LErr);
  finally
    R.Free;
  end;

  R := TGrpcMessageReassembler.Create;
  try
    R.Append(ByteArr([$01, $00, $00, $00, $01, $AA]));
    Check('compressed flag: error, named',
      (R.TryNext(LPayload, LErr) = gfrError) and
      (LErr = 'per-message compression is not supported'), LErr);
  finally
    R.Free;
  end;

  LRaised := False;
  try
    TGrpcMessageReassembler.Create(0).Free;
  except
    on E: EArgumentException do
      LRaised := True;
  end;
  Check('Create(0) raises EArgumentException', LRaised);

  { The unary parser's new optional maximum, used by a client that wants a
    ceiling other than the 4 MB default. }
  LOk := GrpcUnframeMessage(Concat2(ByteArr([$00, $00, $00, $00, $10]), PatternBytes(16)),
    LPayload, LErr, 16);
  Check('GrpcUnframeMessage: length = its maximum (16) is accepted',
    LOk and BytesEqual(LPayload, PatternBytes(16)), LErr);
  LOk := GrpcUnframeMessage(Concat2(ByteArr([$00, $00, $00, $00, $11]), PatternBytes(17)),
    LPayload, LErr, 16);
  Check('GrpcUnframeMessage: maximum + 1 is refused, naming the maximum',
    (not LOk) and (LErr = 'gRPC message length 17 exceeds the 16-byte maximum'), LErr);
  LOk := GrpcUnframeMessage(ByteArr([$00, $00, $00, $00, $00]), LPayload, LErr, 0);
  Check('GrpcUnframeMessage: a maximum of 0 refuses, never disables the cap',
    not LOk, 'accepted');
end;

// -- 09  grpc-message decoding (GC0, the client side of GRPC-ERRMSG-1) -------

procedure ExpectDecoded(const AName, AInput, AExpected: string);
var
  LGot: string;
begin
  LGot := GrpcDecodeStatusMessage(AInput);
  Check(AName, LGot = AExpected,
    Format('expected "%s", got "%s"', [AExpected, LGot]));
end;

procedure ExpectRoundTrip(const AName, AText: string);
begin
  ExpectDecoded(AName, GrpcEncodeStatusMessage(AText), AText);
end;

procedure TestPercentDecode;
begin
  WriteLn;
  WriteLn('-- 09  grpc-message percent-decoding (GC0)');

  ExpectRoundTrip('round trip: plain ASCII',
    'method not registered: /greeter.Greeter/DoesNotExist');
  ExpectRoundTrip('round trip: a literal %', '100%');
  ExpectRoundTrip('round trip: text that looks encoded', 'x%41');
  ExpectRoundTrip('round trip: CR LF', 'a'#13#10'b');
  ExpectRoundTrip('round trip: DEL', 'a'#127);
  ExpectRoundTrip('round trip: 2-byte UTF-8', Utf8Text([$C3, $A7]));
  ExpectRoundTrip('round trip: 4-byte UTF-8 (a surrogate pair on Delphi)',
    Utf8Text([$F0, $9F, $98, $80]));
  ExpectRoundTrip('round trip: empty', '');

  ExpectDecoded('%20 decodes to a space', 'a%20b', 'a b');
  ExpectDecoded('lower-case hex is accepted', '%c3%a7', Utf8Text([$C3, $A7]));
  ExpectDecoded('lenient: a trailing % is kept', '100%', '100%');
  ExpectDecoded('lenient: % plus one hex digit at the end is kept', 'a%4', 'a%4');
  ExpectDecoded('lenient: % plus a non-hex digit is kept', '%G1x', '%G1x');
end;

begin
  WriteLn('Nghttp2GrpcFramingTests - gRPC length-prefix framing + reassembly');
  WriteLn('The variable under test is the CHOP PATTERN, not the payload.');

  try
    TestHeaderLayout;
    TestWrapStripRoundTrip;
    TestReassembly;
    TestTruncatedStream;
    TestEmptyStream;
    TestPercentEncode;
    TestCompatibility;
    TestReassembler;
    TestPercentDecode;
  except
    on E: Exception do
    begin
      WriteLn;
      WriteLn('UNHANDLED ', E.ClassName, ': ', E.Message);
      Inc(GFail);
    end;
  end;

  WriteLn;
  WriteLn(Format('[Nghttp2GrpcFraming] %d passed, %d failed', [GPass, GFail]));
  if GFail = 0 then
    WriteLn('[Nghttp2GrpcFraming] All tests PASSED.')
  else
    WriteLn('[Nghttp2GrpcFraming] FAILURES.');

  ExitCode := GFail;
end.
