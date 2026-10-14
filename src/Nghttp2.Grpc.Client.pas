unit Nghttp2.Grpc.Client;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Nghttp2.Grpc.Client                                   (GC2, B2 client plan)
//  Calls gRPC methods over TNghttp2Client: unary calls in this step.
//
//    LChannel := TGrpcChannel.Create('127.0.0.1', 50051);
//    try
//      LReply := LChannel.Unary('/pkg.Service/Method', LRequest, TReply) as TReply;
//      try
//        ... use LReply ...
//      finally
//        LReply.Free;                // the CALLER owns the result
//      end;
//    finally
//      LChannel.Free;
//    end;
//
//  ── The one rule ──
//
//  A call either returns a decoded response with grpc-status 0, or raises
//  EGrpcClientError carrying a gRPC status code. Nothing in between: no
//  half-filled object, no "HTTP 200 so it worked". The status is taken from
//  where the protocol puts it and nowhere else -
//
//    a response with a body  -> the trailer section (Response.Trailers, GC1)
//    a headers-only response -> the headers ("Trailers-Only", Response.HeadersOnly)
//
//  and every way of getting that wrong maps to a code instead of a guess:
//
//    transport failure (refused, reset, timed out)      14 UNAVAILABLE
//    HTTP status other than 200                         per the gRPC HTTP
//                                                       mapping (404 -> 12,
//                                                       503 -> 14, ...)
//    content-type not application/grpc*                 13 INTERNAL
//    no grpc-status where the protocol puts it          13 INTERNAL
//    grpc-status not a number                           2  UNKNOWN
//    status 0 but no message / two messages /
//    truncated / compressed / undecodable message       13 INTERNAL
//    request could not be encoded                       13 INTERNAL
//
//  grpc-message is percent-decoded (Nghttp2.Grpc.Framing) before it reaches
//  EGrpcClientError.GrpcMessage.
//
//  ── Not here yet ──
//
//  Deadlines sent as grpc-timeout and call metadata are GC3; server streaming
//  is GC4; client and bidi streaming are deferred (plan decision D1). TLS is
//  the TNghttp2Client's: pass a TTlsClientContext.
//
//  ── Threads ──
//
//  A channel is NOT thread-safe: one channel per thread, exactly like the
//  TNghttp2Client it wraps. A pool of connections is CL5, not this unit.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
  Nghttp2.Client,
  Nghttp2.Tls;

type
  { Every failure of a gRPC call. Status is the gRPC code (GRPC_STATUS_* in
    Nghttp2.Grpc.Framing); GrpcMessage is the decoded grpc-message, or the
    client's own description when the failure happened on this side. }
  EGrpcClientError = class(Exception)
  private
    FStatus:      Integer;
    FGrpcMessage: string;
  public
    constructor CreateStatus(AStatus: Integer; const AGrpcMessage: string);
    property Status:      Integer read FStatus;
    property GrpcMessage: string  read FGrpcMessage;
  end;

  TGrpcChannel = class
  private
    FClient:          TNghttp2Client;
    FHost:            string;
    FPort:            Word;
    FCallTimeoutMS:   Integer;
    FMaxReceiveBytes: Integer;
    procedure EnsureConnected;
  public
    { Connects lazily, on the first call. ATlsContext is BORROWED: the caller
      keeps it alive for the channel's lifetime and frees it afterwards. nil
      means h2c (cleartext HTTP/2 with prior knowledge). }
    constructor Create(const AHost: string; APort: Word;
      ATlsContext: TTlsClientContext = nil);
    destructor Destroy; override;

    { One unary call. ARequest is serialised and NOT freed; the result is a
      new AResponseClass instance that the CALLER owns. Raises
      EGrpcClientError for every failure - see the unit header. }
    function Unary(const APath: string; ARequest: TObject;
      AResponseClass: TClass): TObject;

    { How long one call may wait for its response, in ms. Local only: GC3
      adds the grpc-timeout header that tells the server too. }
    property CallTimeoutMS: Integer read FCallTimeoutMS write FCallTimeoutMS;

    { Ceiling on one received message; defaults to 4 MB like the server. }
    property MaxReceiveMessageBytes: Integer
      read FMaxReceiveBytes write FMaxReceiveBytes;

    { The underlying HTTP/2 client, e.g. for ConnectTimeoutMS. }
    property Client: TNghttp2Client read FClient;
  end;

implementation

uses
  Nghttp2.Grpc.Framing,
  Nghttp2.Protobuf.Rtti;

{ ── EGrpcClientError ────────────────────────────────────────────────────── }

constructor EGrpcClientError.CreateStatus(AStatus: Integer;
  const AGrpcMessage: string);
begin
  inherited CreateFmt('gRPC %s (%d): %s',
    [GrpcStatusName(AStatus), AStatus, AGrpcMessage]);
  FStatus      := AStatus;
  FGrpcMessage := AGrpcMessage;
end;

{ ── helpers ─────────────────────────────────────────────────────────────── }

function FindHeader(const AList: TNghttp2Headers; const AName: string;
  out AValue: string): Boolean;
var
  I: Integer;
begin
  AValue := '';
  for I := 0 to High(AList) do
    if SameText(AList[I].Name, AName) then
    begin
      AValue := AList[I].Value;
      Exit(True);
    end;
  Result := False;
end;

{ grpc/doc/http-grpc-status-mapping.md - used when the HTTP status itself is
  not 200, i.e. something other than a gRPC server answered (a proxy, a load
  balancer, a plain HTTP/2 server). }
function HttpToGrpcStatus(AHttpStatus: Integer): Integer;
begin
  case AHttpStatus of
    400:           Result := GRPC_STATUS_INTERNAL;
    401:           Result := GRPC_STATUS_UNAUTHENTICATED;
    403:           Result := GRPC_STATUS_PERMISSION_DENIED;
    404:           Result := GRPC_STATUS_UNIMPLEMENTED;
    429, 502, 503, 504:
                   Result := GRPC_STATUS_UNAVAILABLE;
  else
    Result := GRPC_STATUS_UNKNOWN;
  end;
end;

procedure Fail(AStatus: Integer; const AMessage: string);
begin
  raise EGrpcClientError.CreateStatus(AStatus, AMessage);
end;

{ ── TGrpcChannel ────────────────────────────────────────────────────────── }

constructor TGrpcChannel.Create(const AHost: string; APort: Word;
  ATlsContext: TTlsClientContext);
begin
  inherited Create;
  FHost            := AHost;
  FPort            := APort;
  FCallTimeoutMS   := DEFAULT_REQUEST_TIMEOUT_MS;
  FMaxReceiveBytes := GRPC_DEFAULT_MAX_MESSAGE_BYTES;
  FClient          := TNghttp2Client.Create;
  FClient.TlsContext := ATlsContext;
end;

destructor TGrpcChannel.Destroy;
begin
  FClient.Free;
  inherited;
end;

{ A GOAWAY means this connection takes no new streams, so the next call gets a
  fresh one. Reconnect also covers a connection the peer has since closed. }
procedure TGrpcChannel.EnsureConnected;
begin
  if not FClient.Connected then
    FClient.Connect(FHost, FPort)
  else if FClient.GoAwayReceived then
    FClient.Reconnect;
end;

function TGrpcChannel.Unary(const APath: string; ARequest: TObject;
  AResponseClass: TClass): TObject;
var
  LHeaders:    TNghttp2Headers;
  LBody:       TBytes;
  LResp:       TNghttp2Response;
  LPayload:    TBytes;
  LValue:      string;
  LStatusList: TNghttp2Headers;
  LStatus:     Integer;
  LError:      string;
  LObj:        TObject;
begin
  Result := nil;
  if ARequest = nil then
    raise EArgumentException.Create('TGrpcChannel.Unary: ARequest is nil');
  if AResponseClass = nil then
    raise EArgumentException.Create('TGrpcChannel.Unary: AResponseClass is nil');

  try
    LBody := GrpcFrameMessage(TProtoSerializer.Serialize(ARequest));
  except
    on E: Exception do
      Fail(GRPC_STATUS_INTERNAL, 'request encode failed: ' + E.Message);
  end;

  { te: trailers is REQUIRED of a gRPC client (gRPC over HTTP/2 spec): it is
    how the server knows the peer will read the trailer section at all. }
  SetLength(LHeaders, 2);
  LHeaders[0].Name  := 'content-type';
  LHeaders[0].Value := 'application/grpc';
  LHeaders[1].Name  := 'te';
  LHeaders[1].Value := 'trailers';

  try
    EnsureConnected;
    LResp := FClient.SubmitRequest('POST', APath, LHeaders, LBody, FCallTimeoutMS);
  except
    on E: Exception do
      Fail(GRPC_STATUS_UNAVAILABLE, E.ClassName + ': ' + E.Message);
  end;

  if LResp.Status <> 200 then
    Fail(HttpToGrpcStatus(LResp.Status),
      Format('HTTP status %d from %s', [LResp.Status, APath]));

  if not FindHeader(LResp.Headers, 'content-type', LValue)
     or not SameText(Copy(LValue, 1, 16), 'application/grpc') then
    Fail(GRPC_STATUS_INTERNAL,
      Format('response content-type is "%s", not application/grpc', [LValue]));

  { GC1: the status lives in the trailers, or in the headers of a
    headers-only response - never anywhere else. Headers also holds the
    trailer fields (kept for compatibility), so it is read only in the
    headers-only case, where no trailer section exists. }
  if LResp.HeadersOnly then
    LStatusList := LResp.Headers
  else
    LStatusList := LResp.Trailers;

  if not FindHeader(LStatusList, 'grpc-status', LValue) then
  begin
    if LResp.HeadersOnly then
      Fail(GRPC_STATUS_INTERNAL, 'headers-only response without grpc-status')
    else
      Fail(GRPC_STATUS_INTERNAL, 'response has no grpc-status trailer');
  end;
  LStatus := StrToIntDef(Trim(LValue), -1);
  if LStatus < 0 then
    Fail(GRPC_STATUS_UNKNOWN, Format('grpc-status "%s" is not a number', [LValue]));

  if LStatus <> GRPC_STATUS_OK then
  begin
    FindHeader(LStatusList, 'grpc-message', LValue);
    Fail(LStatus, GrpcDecodeStatusMessage(LValue));
  end;

  { OK. A unary response carries exactly one message. A zero-LENGTH message
    (all fields at their defaults) is a message; NO message is a violation. }
  if Length(LResp.Body) = 0 then
    Fail(GRPC_STATUS_INTERNAL, 'grpc-status 0 but the response carried no message');
  if not GrpcUnframeMessage(LResp.Body, LPayload, LError, FMaxReceiveBytes) then
    Fail(GRPC_STATUS_INTERNAL, LError);
  if Length(LResp.Body) > GRPC_FRAME_HEADER_BYTES + Length(LPayload) then
    Fail(GRPC_STATUS_INTERNAL, 'a unary response carried more than one message');

  LObj := AResponseClass.Create;
  try
    TProtoSerializer.Deserialize(LPayload, LObj);
  except
    on E: Exception do
    begin
      LObj.Free;
      Fail(GRPC_STATUS_INTERNAL, 'response decode failed: ' + E.Message);
    end;
  end;
  Result := LObj;
end;

end.
