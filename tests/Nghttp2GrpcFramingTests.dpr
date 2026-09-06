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
  Nghttp2.Grpc.Dispatcher,     // StripGrpcPrefix
  Nghttp2.Grpc.StreamWriter,   // WrapGrpcMessage
  Nghttp2.Grpc.StreamReader;   // TGrpcStreamReader

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

begin
  WriteLn('Nghttp2GrpcFramingTests - gRPC length-prefix framing + reassembly');
  WriteLn('The variable under test is the CHOP PATTERN, not the payload.');

  try
    TestHeaderLayout;
    TestWrapStripRoundTrip;
    TestReassembly;
    TestTruncatedStream;
    TestEmptyStream;
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
