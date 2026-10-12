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
//  GC0 (1.28.0): the rolling buffer is now TGrpcMessageReassembler in
//  Nghttp2.Grpc.Framing, shared with the gRPC client. This unit keeps the
//  transport half (ReadInbound, liveness) and its own error texts, which are
//  unchanged: "gRPC stream: " + the reassembler's reason.
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
  Nghttp2.Grpc.Framing,      { GC0 - TGrpcMessageReassembler, the 4 MB default }
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
  GRPC_MAX_MESSAGE_BYTES = GRPC_DEFAULT_MAX_MESSAGE_BYTES;

type
  TGrpcStreamReader = class(TInterfacedObject, IGrpcStreamReader)
  private
    FStream:       INghttp2Stream;
    FRequestClass: TClass;
    FFrames:       TGrpcMessageReassembler;   // GC0 - the rolling buffer
    FCurrent:      TObject;     // reader-owned; freed on next Next / destroy
    FCount:        Integer;
    function TryExtractMessage(out APayload: TBytes): Boolean;
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
  FFrames       := TGrpcMessageReassembler.Create(GRPC_MAX_MESSAGE_BYTES);
  FCurrent      := nil;
  FCount        := 0;
end;

destructor TGrpcStreamReader.Destroy;
begin
  { The last message handed out is still reader-owned — see
    IGrpcStreamReader.Next. Freeing it here is what makes "do not free it"
    correct advice rather than a leak. }
  FCurrent.Free;
  FFrames.Free;
  inherited;
end;

{ Pulls one complete message off the front of the buffer if there is one.

  Returns False when fewer bytes than one whole message are buffered - "not
  yet", not an error. Raises EGrpcRegistry, with the texts this unit has always
  used, when the buffered header can never become a valid message. }
function TGrpcStreamReader.TryExtractMessage(out APayload: TBytes): Boolean;
var
  LError: string;
begin
  case FFrames.TryNext(APayload, LError) of
    gfrMessage:
      Result := True;
    gfrError:
      raise EGrpcRegistry.Create('gRPC stream: ' + LError);
  else
    Result := False;
  end;
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
      if FFrames.BufferedBytes > 0 then
        raise EGrpcRegistry.CreateFmt(
          'gRPC stream: peer half-closed with %d bytes of an incomplete message',
          [FFrames.BufferedBytes]);
      Exit(False);
    end;

    if LRead < 0 then
    begin
      { Timeout, not end — the peer may just be slow. Keep waiting unless the
        connection has actually gone. }
      if not FStream.IsStreamAlive then Exit(False);
      Continue;
    end;

    FFrames.Append(LChunk, LRead);
  end;
end;

function TGrpcStreamReader.Count: Integer;
begin
  Result := FCount;
end;

end.
