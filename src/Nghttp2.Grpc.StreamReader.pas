unit Nghttp2.Grpc.StreamReader;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Nghttp2.Grpc.StreamReader                             (M6b)
//  IGrpcStreamReader over one HTTP/2 stream — client-streaming and bidi.
//
//  The transport half is INBOUND-1: ReadInbound hands over whatever DATA has
//  arrived. What this unit adds is REASSEMBLY, and that is the whole reason it
//  is not trivial.
//
//  gRPC messages are `[compressed flag][4-byte big-endian length][payload]`,
//  and they have NO relationship to DATA frame boundaries. A single frame may
//  carry three messages and half of a fourth; a single message may span many
//  frames. Decoding per frame — the obvious mistake — works perfectly against
//  a test client that sends one message per frame and corrupts against every
//  real one.
//
//  So the reader keeps a rolling buffer: append what arrives, extract whole
//  messages while the buffer holds a complete one, and read again when it does
//  not. The buffer compacts once drained, so a long-lived bidi stream does not
//  grow by every byte it ever received.
//
//  Extracted from horse-provider-nghttp2 on 2026-08-23. The layer never
//  depended on Horse — only its unit name did; the sole input here is an
//  INghttp2Stream. Any host that owns one can serve gRPC with it.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$ENDIF}
  Nghttp2.Types,
  Nghttp2.Grpc.Registry;

const
  { How long one Next call waits for more bytes before giving up. A read
    timeout is not the same as end-of-stream: a peer may simply be slow, so
    Next keeps waiting across ticks and only stops when the stream actually
    half-closes or dies. This bounds how often it re-checks liveness. }
  GRPC_READ_TICK_MS = 250;

  { Ceiling on a single message. Without it a corrupt or hostile 4-byte length
    prefix (up to 4 GB) makes the server allocate on the peer's say-so before
    a single payload byte has been validated. 4 MB matches gRPC's common
    default max receive size. }
  GRPC_MAX_MESSAGE_BYTES = 4 * 1024 * 1024;

type
  TGrpcStreamReader = class(TInterfacedObject, IGrpcStreamReader)
  private
    FStream:       INghttp2Stream;
    FRequestClass: TClass;
    FBuf:          TBytes;      // rolling reassembly buffer
    FBufLen:       Integer;     // valid bytes in FBuf (may be < Length(FBuf))
    FCurrent:      TObject;     // reader-owned; freed on next Next / destroy
    FCount:        Integer;
    function TryExtractMessage(out APayload: TBytes): Boolean;
    procedure Compact;
  public
    constructor Create(const AStream: INghttp2Stream; ARequestClass: TClass);
    destructor  Destroy; override;
    function Next(out AMessage: TObject): Boolean;
    function Count: Integer;
  end;

implementation

uses
  Nghttp2.Protobuf.Rtti;

constructor TGrpcStreamReader.Create(const AStream: INghttp2Stream;
  ARequestClass: TClass);
begin
  inherited Create;
  FStream       := AStream;
  FRequestClass := ARequestClass;
  FBufLen       := 0;
  FCurrent      := nil;
  FCount        := 0;
end;

destructor TGrpcStreamReader.Destroy;
begin
  { The last message handed out is still reader-owned — see
    IGrpcStreamReader.Next. Freeing it here is what makes "do not free it"
    correct advice rather than a leak. }
  FCurrent.Free;
  inherited;
end;

{ Drops consumed bytes from the front. Called only when the buffer is fully
  drained, which keeps it O(1) amortised: a partial message stays put until
  the rest of it arrives rather than being memmoved on every read. }
procedure TGrpcStreamReader.Compact;
begin
  FBufLen := 0;
  SetLength(FBuf, 0);
end;

{ Pulls one complete message off the front of FBuf if there is one.

  Returns False when the buffer holds fewer than 5 bytes, or holds a header
  whose payload has not fully arrived — both are "not yet", not errors. }
function TGrpcStreamReader.TryExtractMessage(out APayload: TBytes): Boolean;
var
  LLen:   UInt32;
  LTotal: Integer;
  LRest:  Integer;
begin
  Result := False;
  SetLength(APayload, 0);

  if FBufLen < 5 then Exit;

  if FBuf[0] <> 0 then
    raise EHorseGrpcRegistry.Create(
      'gRPC stream: per-message compression is not supported');

  LLen := (UInt32(FBuf[1]) shl 24) or
          (UInt32(FBuf[2]) shl 16) or
          (UInt32(FBuf[3]) shl 8)  or
           UInt32(FBuf[4]);

  if LLen > GRPC_MAX_MESSAGE_BYTES then
    raise EHorseGrpcRegistry.CreateFmt(
      'gRPC stream: message length %u exceeds the %d-byte limit',
      [LLen, GRPC_MAX_MESSAGE_BYTES]);

  LTotal := 5 + Integer(LLen);
  if FBufLen < LTotal then Exit;    // header complete, payload still arriving

  SetLength(APayload, LLen);
  if LLen > 0 then
    Move(FBuf[5], APayload[0], LLen);

  { Shift any trailing bytes — the start of the NEXT message, which arrived in
    the same read — down to the front. Dropping them here is the subtle way to
    lose every second message on a peer that batches. }
  LRest := FBufLen - LTotal;
  if LRest > 0 then
    Move(FBuf[LTotal], FBuf[0], LRest);
  FBufLen := LRest;
  if FBufLen = 0 then
    Compact;

  Result := True;
end;

function TGrpcStreamReader.Next(out AMessage: TObject): Boolean;
var
  LPayload: TBytes;
  LChunk:   TBytes;
  LRead:    Integer;
  LObj:     TObject;
begin
  AMessage := nil;

  { Release the previous message before producing the next — this is what the
    "valid only until the next call to Next" contract buys the caller. }
  FreeAndNil(FCurrent);

  while True do
  begin
    if TryExtractMessage(LPayload) then
    begin
      LObj := FRequestClass.Create;
      try
        TProtoSerializer.Deserialize(LPayload, LObj);
      except
        LObj.Free;
        raise;
      end;
      FCurrent := LObj;
      Inc(FCount);
      AMessage := LObj;
      Exit(True);
    end;

    LRead := FStream.ReadInbound(LChunk, 16 * 1024, GRPC_READ_TICK_MS);

    if LRead = 0 then
    begin
      { End of stream. A partial message still sitting in the buffer means the
        peer half-closed mid-message — report it rather than silently dropping
        the fragment, which would look like a clean short stream. }
      if FBufLen > 0 then
        raise EHorseGrpcRegistry.CreateFmt(
          'gRPC stream: peer half-closed with %d bytes of an incomplete message',
          [FBufLen]);
      Exit(False);
    end;

    if LRead < 0 then
    begin
      { Timeout, not end — the peer may just be slow. Keep waiting unless the
        connection has actually gone. }
      if not FStream.IsStreamAlive then Exit(False);
      Continue;
    end;

    if FBufLen + LRead > Length(FBuf) then
      SetLength(FBuf, FBufLen + LRead);
    Move(LChunk[0], FBuf[FBufLen], LRead);
    Inc(FBufLen, LRead);
  end;
end;

function TGrpcStreamReader.Count: Integer;
begin
  Result := FCount;
end;

end.
