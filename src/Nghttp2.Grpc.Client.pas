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
//  ── Deadlines and metadata (GC3) ──
//
//    LOpt := TGrpcCallOptions.Default;
//    LOpt.DeadlineMS := 500;                     // 0 = no deadline
//    LOpt.AddMetadata('x-request-id', 'abc');    // ASCII metadata
//    LReply := LChannel.Unary(APath, LReq, TReply, LOpt);
//
//  A deadline is SENT (grpc-timeout: 500m) and ENFORCED HERE: when it passes
//  the call raises 4 DEADLINE_EXCEEDED whether or not the server honours the
//  header - our own TGrpcDispatcher does not, today. The time spent
//  connecting counts against it. After a deadline the channel drops its
//  connection (the abandoned stream is still open on it) and the next call
//  opens a fresh one. Without a deadline the call waits at most
//  CallTimeoutMS, and running out of THAT is 4 as well: the call ran out of
//  time either way.
//
//  Metadata names follow the gRPC spec: lowercase a-z 0-9 - _ . only, not
//  grpc-*, content-type or te (the client sends those itself), and values
//  printable ASCII (0x20..0x7E). Binary metadata (-bin) is refused until it
//  is implemented. A bad name or value raises EArgumentException before
//  anything is sent: it is a bug in the caller, not a call status.
//
//  ── Not here yet ──
//
//  Server streaming is GC4; client and bidi streaming are deferred (plan
//  decision D1).
//
//  ── TLS (GC2b) ──
//
//  Pass a TTlsClientContext. It verifies the server by default, against what
//  YOU tell it to trust - nothing until then, so call one of
//
//    LTls.LoadVerifyLocations('ca.pem');   // a private CA, or a bundle file
//    LTls.UseSystemTrustStore;             // OpenSSL's default paths
//
//  and the certificate must also be issued for the host given to Create (a
//  DNS name or an IP literal). mTLS: LTls.SetClientCertificate(cert, key).
//  Every TLS failure - untrusted or wrong-name certificate, a server that
//  wants a client certificate we did not send - is 14 UNAVAILABLE, like any
//  other transport failure; the underlying ENghttp2TlsCertVerify (with its
//  X509_V_* code) is named in GrpcMessage. SetInsecure skips verification:
//  for tests only.
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

  { GC3. Per-call options. Use TGrpcCallOptions.Default, then set fields -
    a record declared without it holds whatever the stack held. }
  TGrpcCallOptions = record
    { ms; 0 = none. Sent as grpc-timeout and enforced locally (4). }
    DeadlineMS: Integer;
    { Sent as request headers, in order. See the unit header for the rules. }
    Metadata:   TNghttp2Headers;
    class function Default: TGrpcCallOptions; static;
    procedure AddMetadata(const AName, AValue: string);
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
      AResponseClass: TClass): TObject; overload;
    { GC3: the same with a deadline and/or metadata. Raises EArgumentException
      for a negative deadline or invalid metadata, before sending anything. }
    function Unary(const APath: string; ARequest: TObject;
      AResponseClass: TClass; const AOptions: TGrpcCallOptions): TObject; overload;

    { How long a call WITHOUT a deadline may wait for its response, in ms.
      Local only - nothing is sent. A call with a deadline uses the deadline. }
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

{ ── GC3 helpers ─────────────────────────────────────────────────────────── }

{ Same arithmetic as TNghttp2Client.MilliSecondsSince, without DateUtils. }
function ElapsedMS(const AStart: TDateTime): Int64;
begin
  Result := Round((Now - AStart) * 86400.0 * 1000.0);
end;

{ grpc-timeout = TimeoutValue TimeoutUnit, the value at most 8 digits. Every
  Integer number of ms fits as seconds; up to 99,999,999 ms it goes out exact.
  Rounding to seconds rounds UP, so the server never sees a shorter deadline
  than the client enforces. }
function GrpcTimeoutValue(AMS: Integer): string;
begin
  if AMS <= 99999999 then
    Result := IntToStr(AMS) + 'm'
  else
    Result := IntToStr((Int64(AMS) + 999) div 1000) + 'S';
end;

procedure ValidateMetadata(const AList: TNghttp2Headers);
var
  I, J: Integer;
  LName, LValue: string;
begin
  for I := 0 to High(AList) do
  begin
    LName  := AList[I].Name;
    LValue := AList[I].Value;
    if LName = '' then
      raise EArgumentException.Create('gRPC metadata: empty name');
    for J := 1 to Length(LName) do
      case LName[J] of
        'a'..'z', '0'..'9', '-', '_', '.': ;
      else
        raise EArgumentException.CreateFmt('gRPC metadata name "%s": only ' +
          'lowercase a-z, 0-9, "-", "_" and "." are allowed (HTTP/2 header ' +
          'names are lowercase; pseudo-headers are set by the client)', [LName]);
      end;
    if (Copy(LName, 1, 5) = 'grpc-') or (LName = 'content-type') or (LName = 'te') then
      raise EArgumentException.CreateFmt('gRPC metadata name "%s" is reserved: ' +
        'the client sets it itself (deadlines go in TGrpcCallOptions.DeadlineMS)',
        [LName]);
    if (Length(LName) > 4) and (Copy(LName, Length(LName) - 3, 4) = '-bin') then
      raise EArgumentException.CreateFmt('gRPC metadata name "%s": binary ' +
        'metadata (-bin) is not supported by this client yet', [LName]);
    for J := 1 to Length(LValue) do
      if (Ord(LValue[J]) < $20) or (Ord(LValue[J]) > $7E) then
        raise EArgumentException.CreateFmt('gRPC metadata "%s": the value must ' +
          'be printable ASCII (0x20..0x7E); character %d is $%.2x', [LName, J,
          Ord(LValue[J])]);
  end;
end;

{ ── TGrpcCallOptions ────────────────────────────────────────────────────── }

class function TGrpcCallOptions.Default: TGrpcCallOptions;
begin
  Result.DeadlineMS := 0;
  Result.Metadata   := nil;
end;

procedure TGrpcCallOptions.AddMetadata(const AName, AValue: string);
var
  LIdx: Integer;
begin
  LIdx := Length(Metadata);
  SetLength(Metadata, LIdx + 1);
  Metadata[LIdx].Name  := AName;
  Metadata[LIdx].Value := AValue;
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
begin
  Result := Unary(APath, ARequest, AResponseClass, TGrpcCallOptions.Default);
end;

function TGrpcChannel.Unary(const APath: string; ARequest: TObject;
  AResponseClass: TClass; const AOptions: TGrpcCallOptions): TObject;
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
  LBudgetMS:   Integer;
  LLeftMS:     Int64;
  LStart:      TDateTime;
  I:           Integer;
begin
  Result := nil;
  if ARequest = nil then
    raise EArgumentException.Create('TGrpcChannel.Unary: ARequest is nil');
  if AResponseClass = nil then
    raise EArgumentException.Create('TGrpcChannel.Unary: AResponseClass is nil');
  if AOptions.DeadlineMS < 0 then
    raise EArgumentException.CreateFmt(
      'TGrpcChannel.Unary: DeadlineMS is %d - use 0 for no deadline',
      [AOptions.DeadlineMS]);
  ValidateMetadata(AOptions.Metadata);

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
  { GC3. Call-Definitions order (gRPC over HTTP/2): grpc-timeout before the
    custom metadata. }
  if AOptions.DeadlineMS > 0 then
  begin
    SetLength(LHeaders, 3);
    LHeaders[2].Name  := 'grpc-timeout';
    LHeaders[2].Value := GrpcTimeoutValue(AOptions.DeadlineMS);
    LBudgetMS := AOptions.DeadlineMS;
  end
  else
    LBudgetMS := FCallTimeoutMS;
  for I := 0 to High(AOptions.Metadata) do
  begin
    SetLength(LHeaders, Length(LHeaders) + 1);
    LHeaders[High(LHeaders)] := AOptions.Metadata[I];
  end;

  LStart := Now;
  try
    EnsureConnected;
    { The deadline covers the whole call, connecting included. }
    LLeftMS := LBudgetMS - ElapsedMS(LStart);
    if LLeftMS <= 0 then
      raise ENghttp2Timeout.CreateFmt('used up while connecting (%d ms)',
        [ElapsedMS(LStart)]);
    LResp := FClient.SubmitRequest('POST', APath, LHeaders, LBody, Integer(LLeftMS));
  except
    on E: ENghttp2Timeout do
    begin
      { The abandoned stream is still open on this connection; a fresh one
        for the next call (FIX-SLOT-RESET-1 makes that safe). }
      try
        FClient.Disconnect;
      except
      end;
      if AOptions.DeadlineMS > 0 then
        Fail(GRPC_STATUS_DEADLINE_EXCEEDED, Format(
          'deadline of %d ms exceeded after %d ms (%s)',
          [AOptions.DeadlineMS, ElapsedMS(LStart), E.Message]))
      else
        Fail(GRPC_STATUS_DEADLINE_EXCEEDED, Format(
          'no reply within CallTimeoutMS = %d ms (%s)', [LBudgetMS, E.Message]));
    end;
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
