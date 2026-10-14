unit Nghttp2.Grpc.Framing;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Nghttp2.Grpc.Framing                                  (GC0, B2 client plan)
//  The gRPC message framing, the grpc-message text encoding, and nothing else.
//
//  Every gRPC message, in both directions, is
//      [1-byte compressed flag][4-byte big-endian length][protobuf payload]
//  and messages have NO relationship to HTTP/2 DATA frame boundaries.
//
//  WHY A UNIT OF ITS OWN
//  ---------------------
//  Until 1.28.0 these routines lived inside the SERVER units: the outbound
//  frame in Nghttp2.Grpc.StreamWriter, the unary inbound parse and the
//  grpc-message encoder in Nghttp2.Grpc.Dispatcher, the streaming reassembly in
//  Nghttp2.Grpc.StreamReader. A gRPC CLIENT needs every one of them, mirrored:
//  it frames requests and parses responses. Using them from there would pull
//  the dispatcher, the registry and INghttp2Stream into a client binary, or
//  invite a second copy of the parser - and two copies of one wire format is
//  how FIX-GRPC-LEN-1 happened (the streaming path had the 4 MB cap, the unary
//  path did not).
//
//  So this unit depends on SysUtils alone. The server units keep their public
//  names (WrapGrpcMessage, StripGrpcPrefix, GrpcPercentEncode,
//  GRPC_MAX_MESSAGE_BYTES) and now delegate here, with byte-identical output
//  and identical error texts; Nghttp2GrpcFramingTests section 07 pins that.
//
//  The routines here have their own names rather than the old ones on purpose:
//  a server unit that declared WrapGrpcMessage and called an identically named
//  function would bind the call to ITSELF (a unit's own scope wins) and recurse,
//  and qualifying the call with a dotted unit name is not exercised by any
//  build in this repository on FPC.
//
//  Thread safety: the functions are pure. A TGrpcMessageReassembler instance
//  is NOT thread-safe; one per stream, used by one thread at a time.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils;
{$ELSE}
  System.SysUtils;
{$IFEND}

const
  { The 5-byte prefix in front of every message. }
  GRPC_FRAME_HEADER_BYTES = 5;

  { Default ceiling on one message. Without one, a corrupt or hostile length
    prefix (up to 4 GB) makes the receiver allocate on the peer's say-so before
    a single payload byte has been validated. 4 MB matches gRPC's common
    default max receive size. Nghttp2.Grpc.StreamReader.GRPC_MAX_MESSAGE_BYTES
    is this value under its pre-1.28.0 name. }
  GRPC_DEFAULT_MAX_MESSAGE_BYTES = 4 * 1024 * 1024;

  { GC2. The full gRPC status code table (grpc/doc/statuscodes.md), here so
    the client and the server share one copy. Nghttp2.Grpc.Dispatcher still
    declares the five it has always exported, with the same names and values,
    so existing code that uses them from there is unaffected. }
  GRPC_STATUS_OK                  = 0;
  GRPC_STATUS_CANCELLED           = 1;
  GRPC_STATUS_UNKNOWN             = 2;
  GRPC_STATUS_INVALID_ARGUMENT    = 3;
  GRPC_STATUS_DEADLINE_EXCEEDED   = 4;
  GRPC_STATUS_NOT_FOUND           = 5;
  GRPC_STATUS_ALREADY_EXISTS      = 6;
  GRPC_STATUS_PERMISSION_DENIED   = 7;
  GRPC_STATUS_RESOURCE_EXHAUSTED  = 8;
  GRPC_STATUS_FAILED_PRECONDITION = 9;
  GRPC_STATUS_ABORTED             = 10;
  GRPC_STATUS_OUT_OF_RANGE        = 11;
  GRPC_STATUS_UNIMPLEMENTED       = 12;
  GRPC_STATUS_INTERNAL            = 13;
  GRPC_STATUS_UNAVAILABLE         = 14;
  GRPC_STATUS_DATA_LOSS           = 15;
  GRPC_STATUS_UNAUTHENTICATED     = 16;

type
  { Result of one TGrpcMessageReassembler.TryNext call. }
  TGrpcFrameResult = (
    gfrNeedMore,   // fewer bytes than one whole message: not an error, read more
    gfrMessage,    // APayload holds one complete message, removed from the buffer
    gfrError       // the buffered bytes can never form a valid message; AError says why
  );

  { Turns an arbitrarily chopped byte stream back into whole gRPC messages.

    Append what arrives, then call TryNext until it stops returning gfrMessage.
    One DATA frame may carry several messages and half of the next; one message
    may span many frames. The reassembler does not care: it keeps a rolling
    buffer and hands out a message only once all of it is present.

    The header is judged as soon as its 5 bytes are present, before any payload
    arrives: a compressed flag or a length over the ceiling is an error at once,
    so a peer cannot make the receiver buffer up to the ceiling first.

    gfrError is terminal. The stream is out of sync after it, and every later
    call returns the same error again. }
  TGrpcMessageReassembler = class
  private
    FBuf:         TBytes;
    FBufLen:      Integer;   // valid bytes in FBuf (Length(FBuf) is capacity)
    FMaxMessage:  Integer;
    FError:       string;
  public
    constructor Create(AMaxMessageBytes: Integer = GRPC_DEFAULT_MAX_MESSAGE_BYTES);

    { Appends the first ACount bytes of AChunk. ACount < 0 means all of it. }
    procedure Append(const AChunk: TBytes; ACount: Integer = -1);

    { See TGrpcFrameResult. AError is set only on gfrError and has no
      "gRPC" prefix, so each caller can name its own context in front of it. }
    function TryNext(out APayload: TBytes; out AError: string): TGrpcFrameResult;

    { Bytes received but not yet handed out. Non-zero at end of stream means the
      peer stopped in the middle of a message. }
    function BufferedBytes: Integer;

    property MaxMessageBytes: Integer read FMaxMessage;
  end;

{ Frames one protobuf payload as a gRPC message: flag 0 (uncompressed), the
  length big-endian, then the payload. Formerly WrapGrpcMessage. }
function GrpcFrameMessage(const APayload: TBytes): TBytes;

{ Parses ONE message from the front of a complete buffer - the unary case.
  Returns False with AError set when the buffer is shorter than the prefix,
  the compressed flag is set, the declared length exceeds AMaxMessageBytes, or
  fewer payload bytes are present than declared. Bytes after the first message
  are ignored (the server's unary path is defined that way; a caller that must
  reject them compares Length(AData) with GRPC_FRAME_HEADER_BYTES +
  Length(APayload)). Formerly StripGrpcPrefix, with the same error texts. }
function GrpcUnframeMessage(const AData: TBytes; out APayload: TBytes;
  out AError: string;
  AMaxMessageBytes: Integer = GRPC_DEFAULT_MAX_MESSAGE_BYTES): Boolean;

{ Percent-encodes a grpc-message value as the gRPC spec requires
  (PROTOCOL-HTTP2.md, "grpc-message"): the text is taken as UTF-8, and every
  byte outside 0x20..0x7E, plus '%' itself, becomes %XX (upper-case hex).
  Everything else passes through. Formerly GrpcPercentEncode. }
function GrpcEncodeStatusMessage(const AText: string): string;

{ The inverse, for a received grpc-message. %XX (either hex case) becomes that
  byte and the bytes are read as UTF-8. Lenient by design, as the spec asks of
  receivers: a '%' not followed by two hex digits is kept as a literal '%'
  rather than raising, because an error message that cannot be decoded is
  still better shown than lost. }
function GrpcDecodeStatusMessage(const AText: string): string;

{ GC2. The canonical name of a status code ('NOT_FOUND' for 5), or
  'CODE_<n>' for a number outside 0..16 - a peer may send one, and the
  number must survive into the error rather than be replaced. }
function GrpcStatusName(AStatus: Integer): string;

implementation

{ The single header parser. Every inbound path goes through it, so the length
  is assembled, and the cap tested, in exactly one place.

  FIX-GRPC-LEN-1 ordering, kept from StripGrpcPrefix: the cap is tested on the
  UNSIGNED length before any Integer() cast. 00 FF FF FF FF cast to Integer is
  -1, which once turned a truncation guard into a 4 GB allocation. }
function ReadHeader(const ABuf: TBytes; out ACompressed: Boolean;
  out ALength: UInt32): Boolean;
begin
  Result := Length(ABuf) >= GRPC_FRAME_HEADER_BYTES;
  if not Result then
  begin
    ACompressed := False;
    ALength     := 0;
    Exit;
  end;
  ACompressed := ABuf[0] <> 0;
  ALength := (UInt32(ABuf[1]) shl 24) or
             (UInt32(ABuf[2]) shl 16) or
             (UInt32(ABuf[3]) shl 8)  or
              UInt32(ABuf[4]);
end;

function GrpcFrameMessage(const APayload: TBytes): TBytes;
var
  LLen: UInt32;
begin
  LLen := UInt32(Length(APayload));
  SetLength(Result, GRPC_FRAME_HEADER_BYTES + Integer(LLen));
  Result[0] := 0;                          // compression flag = uncompressed
  Result[1] := Byte((LLen shr 24) and $FF);
  Result[2] := Byte((LLen shr 16) and $FF);
  Result[3] := Byte((LLen shr 8)  and $FF);
  Result[4] := Byte( LLen         and $FF);
  if LLen > 0 then
    Move(APayload[0], Result[GRPC_FRAME_HEADER_BYTES], LLen);
end;

function GrpcUnframeMessage(const AData: TBytes; out APayload: TBytes;
  out AError: string; AMaxMessageBytes: Integer): Boolean;
var
  LCompressed: Boolean;
  LMsgLen:     UInt32;
begin
  Result := False;
  SetLength(APayload, 0);
  AError := '';

  if not ReadHeader(AData, LCompressed, LMsgLen) then
  begin
    AError := 'gRPC frame too short (< 5-byte prefix)';
    Exit;
  end;
  if LCompressed then
  begin
    AError := 'gRPC compression flag set (per-message compression not supported in v0.1)';
    Exit;
  end;
  { A non-positive maximum would wrap to a huge UInt32 and disable the cap, so
    it rejects everything instead. }
  if (AMaxMessageBytes <= 0) or (LMsgLen > UInt32(AMaxMessageBytes)) then
  begin
    AError := Format('gRPC message length %u exceeds the %d-byte maximum',
                     [LMsgLen, AMaxMessageBytes]);
    Exit;
  end;
  // LMsgLen <= AMaxMessageBytes from here, so Integer(LMsgLen) is safe.
  if Length(AData) - GRPC_FRAME_HEADER_BYTES < Integer(LMsgLen) then
  begin
    AError := Format('gRPC frame truncated: header says %u bytes, buffer has %d',
                     [LMsgLen, Length(AData) - GRPC_FRAME_HEADER_BYTES]);
    Exit;
  end;
  SetLength(APayload, LMsgLen);
  if LMsgLen > 0 then
    Move(AData[GRPC_FRAME_HEADER_BYTES], APayload[0], LMsgLen);
  Result := True;
end;

{ ── TGrpcMessageReassembler ─────────────────────────────────────────────── }

constructor TGrpcMessageReassembler.Create(AMaxMessageBytes: Integer);
begin
  inherited Create;
  { The upper bound keeps 5 + length inside Integer in TryNext. }
  if (AMaxMessageBytes <= 0) or
     (AMaxMessageBytes > MaxInt - GRPC_FRAME_HEADER_BYTES) then
    raise EArgumentException.CreateFmt(
      'TGrpcMessageReassembler: AMaxMessageBytes must be 1..%d, got %d',
      [MaxInt - GRPC_FRAME_HEADER_BYTES, AMaxMessageBytes]);
  FMaxMessage := AMaxMessageBytes;
  FBufLen     := 0;
  FError      := '';
end;

procedure TGrpcMessageReassembler.Append(const AChunk: TBytes; ACount: Integer);
var
  LCap: Integer;
begin
  if (ACount < 0) or (ACount > Length(AChunk)) then
    ACount := Length(AChunk);
  if ACount = 0 then
    Exit;
  { Grow geometrically. Growing to the exact size reallocates on every append,
    so a large message delivered in small reads (a client's ReadChunk, a
    1-byte chop in the tests) costs a full copy per read: quadratic. }
  if FBufLen + ACount > Length(FBuf) then
  begin
    LCap := Length(FBuf) * 2;
    if LCap < FBufLen + ACount then
      LCap := FBufLen + ACount;
    SetLength(FBuf, LCap);
  end;
  Move(AChunk[0], FBuf[FBufLen], ACount);
  Inc(FBufLen, ACount);
end;

function TGrpcMessageReassembler.TryNext(out APayload: TBytes;
  out AError: string): TGrpcFrameResult;
var
  LCompressed: Boolean;
  LLen:        UInt32;
  LTotal:      Integer;
  LRest:       Integer;
begin
  SetLength(APayload, 0);
  AError := '';

  if FError <> '' then
  begin
    AError := FError;
    Exit(gfrError);
  end;

  { ReadHeader looks at Length(FBuf), which is capacity, so test the VALID
    byte count first. }
  if (FBufLen < GRPC_FRAME_HEADER_BYTES) or
     not ReadHeader(FBuf, LCompressed, LLen) then
    Exit(gfrNeedMore);

  if LCompressed then
    FError := 'per-message compression is not supported'
  else if LLen > UInt32(FMaxMessage) then
    FError := Format('message length %u exceeds the %d-byte limit',
                     [LLen, FMaxMessage]);
  if FError <> '' then
  begin
    AError := FError;
    Exit(gfrError);
  end;

  LTotal := GRPC_FRAME_HEADER_BYTES + Integer(LLen);
  if FBufLen < LTotal then
    Exit(gfrNeedMore);              // header complete, payload still arriving

  SetLength(APayload, LLen);
  if LLen > 0 then
    Move(FBuf[GRPC_FRAME_HEADER_BYTES], APayload[0], LLen);

  { Shift any trailing bytes - the start of the NEXT message, which arrived in
    the same read - down to the front. Dropping them here is the subtle way to
    lose every second message on a peer that batches. }
  LRest := FBufLen - LTotal;
  if LRest > 0 then
    Move(FBuf[LTotal], FBuf[0], LRest);
  FBufLen := LRest;
  if FBufLen = 0 then
    SetLength(FBuf, 0);             // release a large message's capacity

  Result := gfrMessage;
end;

function TGrpcMessageReassembler.BufferedBytes: Integer;
begin
  Result := FBufLen;
end;

{ ── grpc-message text ──────────────────────────────────────────────────── }

function GrpcEncodeStatusMessage(const AText: string): string;
const
  HEX_DIGITS = '0123456789ABCDEF';
var
  LBytes: TBytes;
  I:      Integer;
  B:      Byte;
begin
  Result := '';
  if AText = '' then
    Exit;
  { UTF-8 bytes on both compilers - the same call Nghttp2.Protobuf uses for
    string fields. Encoding per Char would split a UTF-16 surrogate pair on
    Delphi and treat UTF-8 bytes as characters on FPC. }
  LBytes := TEncoding.UTF8.GetBytes(AText);
  for I := 0 to High(LBytes) do
  begin
    B := LBytes[I];
    if (B >= $20) and (B <= $7E) and (B <> Ord('%')) then
      Result := Result + Char(B)
    else
      Result := Result + '%' + HEX_DIGITS[(B shr 4) + 1] + HEX_DIGITS[(B and $0F) + 1];
  end;
end;

function HexValue(C: Char): Integer;
begin
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    'A'..'F': Result := Ord(C) - Ord('A') + 10;
    'a'..'f': Result := Ord(C) - Ord('a') + 10;
  else
    Result := -1;
  end;
end;

function GrpcDecodeStatusMessage(const AText: string): string;
var
  LBytes: TBytes;
  LCount: Integer;
  I:      Integer;
  LHi:    Integer;
  LLo:    Integer;
  LCode:  Integer;
begin
  Result := '';
  if AText = '' then
    Exit;

  { Collect bytes, then decode them as UTF-8 once: a multi-byte character
    arrives as several %XX groups and is only valid as a whole. The output can
    only be shorter than the input, so one allocation is enough. }
  SetLength(LBytes, Length(AText));
  LCount := 0;
  I := 1;
  while I <= Length(AText) do
  begin
    if (AText[I] = '%') and (I + 2 <= Length(AText)) then
    begin
      LHi := HexValue(AText[I + 1]);
      LLo := HexValue(AText[I + 2]);
      if (LHi >= 0) and (LLo >= 0) then
      begin
        LBytes[LCount] := Byte((LHi shl 4) or LLo);
        Inc(LCount);
        Inc(I, 3);
        Continue;
      end;
    end;
    { A literal character. A conforming sender only puts 0x20..0x7E here;
      anything wider (possible on Delphi, where string is UTF-16) cannot be
      one byte and becomes '?' rather than a silently truncated code unit. }
    LCode := Ord(AText[I]);
    if LCode > $FF then
      LCode := Ord('?');
    LBytes[LCount] := Byte(LCode);
    Inc(LCount);
    Inc(I);
  end;
  SetLength(LBytes, LCount);
  { The inverse of the encoder's TEncoding.UTF8.GetBytes, on both compilers. }
  Result := TEncoding.UTF8.GetString(LBytes);
end;

function GrpcStatusName(AStatus: Integer): string;
const
  NAMES: array[0..16] of string = (
    'OK', 'CANCELLED', 'UNKNOWN', 'INVALID_ARGUMENT', 'DEADLINE_EXCEEDED',
    'NOT_FOUND', 'ALREADY_EXISTS', 'PERMISSION_DENIED', 'RESOURCE_EXHAUSTED',
    'FAILED_PRECONDITION', 'ABORTED', 'OUT_OF_RANGE', 'UNIMPLEMENTED',
    'INTERNAL', 'UNAVAILABLE', 'DATA_LOSS', 'UNAUTHENTICATED');
begin
  if (AStatus >= Low(NAMES)) and (AStatus <= High(NAMES)) then
    Result := NAMES[AStatus]
  else
    Result := 'CODE_' + IntToStr(AStatus);
end;

end.
