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
//    a message over MaxReceiveMessageBytes              8  RESOURCE_EXHAUSTED
//                                                       (GC4; what grpc-go and
//                                                       grpcio report too)
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
//  ── Server streaming (GC4) ──
//
//    LStream := LChannel.ServerStream('/pkg.Svc/List', LReq, TItem, LOpt);
//    while LStream.MoveNext do
//      Use(LStream.Current as TItem);      // the STREAM owns Current
//
//  Current belongs to the stream and is freed by the next MoveNext (or when
//  the stream is released): copy what you keep. MoveNext returns False only
//  for a stream that ENDED WELL (grpc-status 0). Any other end - a non-zero
//  status after some messages, a missing trailer, a truncated or oversized
//  message, a dropped connection - RAISES EGrpcClientError from MoveNext, and
//  the messages already returned stay returned. Status is never left for the
//  caller to remember to check.
//
//  Deadlines: DeadlineMS bounds the WHOLE stream, connecting included (4).
//  Without one, CallTimeoutMS bounds each wait for the NEXT message - an idle
//  limit, since a healthy stream may run for hours. One call at a time per
//  channel: while a stream is open, Unary and ServerStream on the same
//  channel raise 9 FAILED_PRECONDITION. Releasing a stream before its end
//  drops the connection (the next call opens a fresh one). The stream must
//  not outlive its channel; if it does, MoveNext raises 14.
//
//  ── Not here yet ──
//
//  Client and bidi streaming are deferred (plan decision D1).
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

  { GC5. A client-streaming call in progress: send N messages, receive one.
    Obtain via TGrpcChannel.ClientStream; release when CloseAndReceive returns
    (or when you want to abandon the call). }
  IGrpcClientWriterCall = interface
    ['{A3F72B91-C8D4-4E56-9147-3B6E8A2F0C85}']
    { Serialise ARequest and append it to the outbound stream. Raises
      EGrpcClientError on any transport or encoding failure. ARequest is
      NOT freed; the caller owns it. }
    procedure Send(ARequest: TObject);
    { Half-close the send side, wait for the server's single response, and
      return a decoded instance of AResponseClass. The CALLER owns the result.
      Raises EGrpcClientError for every failure. }
    function CloseAndReceive: TObject;
  end;

  { GC5. A bidirectional-streaming call in progress: send and receive
    interleaved. Send messages with Send; half-close the send side with
    CloseSend. Read server messages with MoveNext / Current, exactly as
    IGrpcClientStream. Obtain via TGrpcChannel.BidiStream. }
  IGrpcBidiStream = interface
    ['{B4E83C07-D951-4F62-A2B5-6C7D9E1F0A34}']
    { Same contract as IGrpcClientWriterCall.Send. }
    procedure Send(ARequest: TObject);
    { Half-close the send side (equiv. to FinishSending on the HTTP/2 stream).
      The receive side continues until MoveNext returns False. }
    procedure CloseSend;
    { True: Current holds the next server message. False: the stream ended
      with grpc-status 0. Every other ending raises EGrpcClientError. }
    function MoveNext: Boolean;
    function GetCurrent: TObject;
    function Received: Integer;
    property Current: TObject read GetCurrent;
  end;

  { GC4. A server-streaming call in progress; see the unit header. }
  IGrpcClientStream = interface
    ['{5E2B7C41-9A3D-4F60-8B17-2C9E4D6A1F03}']
    { True: Current holds the next message. False: the stream ended with
      grpc-status 0. Every other ending raises EGrpcClientError. }
    function MoveNext: Boolean;
    { The message MoveNext just decoded. Owned by the stream: freed by the
      next MoveNext and when the stream is released. nil before the first
      MoveNext and after the last. }
    function GetCurrent: TObject;
    { Messages delivered so far. }
    function Received: Integer;
    property Current: TObject read GetCurrent;
  end;

  TGrpcChannel = class
  private
    FClient:          TNghttp2Client;
    FHost:            string;
    FPort:            Word;
    FCallTimeoutMS:   Integer;
    FMaxReceiveBytes: Integer;
    FOpenStream:      TObject;   // GC4/GC5: TGrpcClientStream or TGrpcBidiStream, not owned
    FOpenWriterCall:  TObject;   // GC5: TGrpcClientWriterCall in progress, not owned
    procedure EnsureConnected;
    procedure RefuseWhileStreaming;
    function  BuildCallHeaders(const AOptions: TGrpcCallOptions;
      out ABudgetMS: Integer): TNghttp2Headers;
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

    { GC4: one server-streaming call. ARequest is serialised and NOT freed;
      AResponseClass is the type of EACH streamed message. Read it with
      MoveNext - see the unit header for ownership, endings and deadlines. }
    function ServerStream(const APath: string; ARequest: TObject;
      AResponseClass: TClass): IGrpcClientStream; overload;
    function ServerStream(const APath: string; ARequest: TObject;
      AResponseClass: TClass; const AOptions: TGrpcCallOptions): IGrpcClientStream; overload;

    { [GC5] Opens a client-streaming call. AResponseClass is the type of
      the single response. Write messages with Send; finish with
      CloseAndReceive. One call at a time per channel. }
    function ClientStream(const APath: string;
      AResponseClass: TClass): IGrpcClientWriterCall; overload;
    function ClientStream(const APath: string;
      AResponseClass: TClass;
      const AOptions: TGrpcCallOptions): IGrpcClientWriterCall; overload;

    { [GC5] Opens a bidirectional-streaming call. AResponseClass is the
      type of each server message. Send with Send; half-close with CloseSend;
      receive with MoveNext. One call at a time per channel. }
    function BidiStream(const APath: string;
      AResponseClass: TClass): IGrpcBidiStream; overload;
    function BidiStream(const APath: string;
      AResponseClass: TClass;
      const AOptions: TGrpcCallOptions): IGrpcBidiStream; overload;

    { How long a call WITHOUT a deadline may wait for its response, in ms.
      Local only - nothing is sent. A call with a deadline uses the deadline.
      For a server stream it is the wait for each NEXT message. }
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

{ :status and content-type - what says a gRPC server answered at all. }
procedure CheckResponseHead(const AResp: TNghttp2Response; const APath: string);
var
  LValue: string;
begin
  if AResp.Status = 0 then
    Fail(GRPC_STATUS_UNAVAILABLE,
      Format('the stream to %s closed before any response headers', [APath]));
  if AResp.Status <> 200 then
    Fail(HttpToGrpcStatus(AResp.Status),
      Format('HTTP status %d from %s', [AResp.Status, APath]));
  if not FindHeader(AResp.Headers, 'content-type', LValue)
     or not SameText(Copy(LValue, 1, 16), 'application/grpc') then
    Fail(GRPC_STATUS_INTERNAL,
      Format('response content-type is "%s", not application/grpc', [LValue]));
end;

{ GC1: the status lives in the trailers, or in the headers of a headers-only
  response - never anywhere else. Headers also holds the trailer fields (kept
  for compatibility), so it is read only in the headers-only case, where no
  trailer section exists. Raises for anything but grpc-status 0. }
procedure CheckGrpcStatus(const AResp: TNghttp2Response);
var
  LStatusList: TNghttp2Headers;
  LValue:      string;
  LStatus:     Integer;
begin
  if AResp.HeadersOnly then
    LStatusList := AResp.Headers
  else
    LStatusList := AResp.Trailers;

  if not FindHeader(LStatusList, 'grpc-status', LValue) then
  begin
    if AResp.HeadersOnly then
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

{ ── TGrpcClientStream (GC4) ──────────────────────────────────────────────── }

type
  TGrpcClientStream = class(TInterfacedObject, IGrpcClientStream)
  private
    FChannel:       TGrpcChannel;   // nil once finished or detached
    FStreamId:      Int32;
    FPath:          string;
    FResponseClass: TClass;
    FDeadlineMS:    Integer;        // 0 = none: CallTimeoutMS per message
    FStart:         TDateTime;
    FReasm:         TGrpcMessageReassembler;
    FCurrent:       TObject;
    FCount:         Integer;
    FHeadChecked:   Boolean;
    FTaken:         Boolean;        // TakeResponse done: the HTTP/2 stream is closed
    FFinished:      Boolean;
    procedure Finish;
    procedure Abandon;
  public
    constructor Create(AChannel: TGrpcChannel; AStreamId: Int32;
      const APath: string; AResponseClass: TClass; ADeadlineMS: Integer;
      AStart: TDateTime);
    destructor Destroy; override;
    function MoveNext: Boolean;
    function GetCurrent: TObject;
    function Received: Integer;
  end;

constructor TGrpcClientStream.Create(AChannel: TGrpcChannel; AStreamId: Int32;
  const APath: string; AResponseClass: TClass; ADeadlineMS: Integer;
  AStart: TDateTime);
begin
  inherited Create;
  FChannel       := AChannel;
  FStreamId      := AStreamId;
  FPath          := APath;
  FResponseClass := AResponseClass;
  FDeadlineMS    := ADeadlineMS;
  FStart         := AStart;
  FReasm         := TGrpcMessageReassembler.Create(AChannel.FMaxReceiveBytes);
end;

destructor TGrpcClientStream.Destroy;
begin
  FreeAndNil(FCurrent);
  if not FFinished then
    Abandon;          // released before its end: the stream is still open
  FReasm.Free;
  inherited;
end;

{ Detach from the channel, leaving the connection as it is. }
procedure TGrpcClientStream.Finish;
begin
  if FChannel <> nil then
  begin
    if FChannel.FOpenStream = Self then
      FChannel.FOpenStream := nil;
    FChannel := nil;
  end;
  FFinished := True;
end;

{ The HTTP/2 stream is still open (or in an unknown state): drop the
  connection, as after a deadline, so the next call starts clean. }
procedure TGrpcClientStream.Abandon;
begin
  if (FChannel <> nil) and not FTaken then
    try
      FChannel.FClient.Disconnect;
    except
    end;
  Finish;
end;

function TGrpcClientStream.GetCurrent: TObject;
begin
  Result := FCurrent;
end;

function TGrpcClientStream.Received: Integer;
begin
  Result := FCount;
end;

function TGrpcClientStream.MoveNext: Boolean;
const
  READ_CHUNK = 65536;
var
  LPayload: TBytes;
  LChunk:   TBytes;
  LError:   string;
  LGot:     Integer;
  LWaitMS:  Int64;
  LObj:     TObject;
  LResp:    TNghttp2Response;
begin
  Result := False;
  FreeAndNil(FCurrent);
  if FFinished then
    Exit;
  if FChannel = nil then
  begin
    FFinished := True;
    Fail(GRPC_STATUS_UNAVAILABLE, 'the channel was freed while this stream was open');
  end;

  try
    repeat
      { Whole messages already buffered go first - one DATA frame may carry
        several, and the end of the stream may arrive with them. }
      case FReasm.TryNext(LPayload, LError) of
        gfrMessage:
          begin
            LObj := FResponseClass.Create;
            try
              TProtoSerializer.Deserialize(LPayload, LObj);
            except
              on E: Exception do
              begin
                LObj.Free;
                Fail(GRPC_STATUS_INTERNAL, Format('message %d decode failed: %s',
                  [FCount + 1, E.Message]));
              end;
            end;
            FCurrent := LObj;
            Inc(FCount);
            Result := True;
            Exit;
          end;
        gfrError:
          if FReasm.TooLarge then
            Fail(GRPC_STATUS_RESOURCE_EXHAUSTED, Format('message %d: %s',
              [FCount + 1, LError]))
          else
            Fail(GRPC_STATUS_INTERNAL, Format('message %d: %s', [FCount + 1, LError]));
        gfrNeedMore:
          ;
      end;

      if FDeadlineMS > 0 then
      begin
        LWaitMS := FDeadlineMS - ElapsedMS(FStart);
        if LWaitMS <= 0 then
          Fail(GRPC_STATUS_DEADLINE_EXCEEDED, Format(
            'deadline of %d ms exceeded after %d message(s)', [FDeadlineMS, FCount]));
      end
      else
        LWaitMS := FChannel.FCallTimeoutMS;

      LGot := FChannel.FClient.ReadChunk(FStreamId, LChunk, READ_CHUNK, Integer(LWaitMS));
      if LGot < 0 then
      begin
        if FDeadlineMS > 0 then
          Continue;     // the check above reports it once the budget is gone
        Fail(GRPC_STATUS_DEADLINE_EXCEEDED, Format(
          'no message within CallTimeoutMS = %d ms after %d message(s)',
          [FChannel.FCallTimeoutMS, FCount]));
      end;

      { The response head is known by now: DATA never precedes it, and an end
        of stream means the whole response is in. Judge it once, before any
        body byte is trusted as a gRPC message. }
      if not FHeadChecked then
      begin
        if FChannel.FClient.PeekResponseHeaders(FStreamId, LResp) then
          CheckResponseHead(LResp, FPath);
        FHeadChecked := True;
      end;

      if LGot > 0 then
        FReasm.Append(LChunk, LGot)
      else
      begin
        { End of stream. TakeResponse raises when the connection died before
          the stream closed - that is a transport failure (14, below). }
        LResp := FChannel.FClient.TakeResponse(FStreamId);
        FTaken := True;
        if not FHeadChecked then
          CheckResponseHead(LResp, FPath);
        CheckGrpcStatus(LResp);
        if FReasm.BufferedBytes > 0 then
          Fail(GRPC_STATUS_INTERNAL, Format(
            'the stream ended inside message %d (%d byte(s) of it received)',
            [FCount + 1, FReasm.BufferedBytes]));
        Finish;
        Exit;   // Result = False: ended with grpc-status 0
      end;
    until False;
  except
    on E: EGrpcClientError do
    begin
      Abandon;
      raise;
    end;
    on E: Exception do
    begin
      Abandon;
      Fail(GRPC_STATUS_UNAVAILABLE, E.ClassName + ': ' + E.Message);
    end;
  end;
end;

{ ── TGrpcClientWriterCall (GC5) ──────────────────────────────────────────── }

type
  TGrpcClientWriterCall = class(TInterfacedObject, IGrpcClientWriterCall)
  private
    FChannel:       TGrpcChannel;   // nil after CloseAndReceive or Abandon
    FStreamId:      Int32;
    FPath:          string;
    FResponseClass: TClass;
    FDeadlineMS:    Integer;
    FStart:         TDateTime;
    FSendClosed:    Boolean;
    procedure Abandon;
  public
    constructor Create(AChannel: TGrpcChannel; AStreamId: Int32;
      const APath: string; AResponseClass: TClass;
      ADeadlineMS: Integer; AStart: TDateTime);
    destructor Destroy; override;
    procedure Send(ARequest: TObject);
    function  CloseAndReceive: TObject;
  end;

constructor TGrpcClientWriterCall.Create(AChannel: TGrpcChannel;
  AStreamId: Int32; const APath: string; AResponseClass: TClass;
  ADeadlineMS: Integer; AStart: TDateTime);
begin
  inherited Create;
  FChannel       := AChannel;
  FStreamId      := AStreamId;
  FPath          := APath;
  FResponseClass := AResponseClass;
  FDeadlineMS    := ADeadlineMS;
  FStart         := AStart;
end;

destructor TGrpcClientWriterCall.Destroy;
begin
  if not FSendClosed then
    Abandon;
  inherited;
end;

procedure TGrpcClientWriterCall.Abandon;
begin
  if (FChannel <> nil) and not FSendClosed then
    try
      FChannel.FClient.Disconnect;
    except
    end;
  if (FChannel <> nil) and (FChannel.FOpenWriterCall = Self) then
    FChannel.FOpenWriterCall := nil;
  FChannel := nil;
  FSendClosed := True;
end;

procedure TGrpcClientWriterCall.Send(ARequest: TObject);
var
  LFramed: TBytes;
begin
  if FSendClosed then
    Fail(GRPC_STATUS_FAILED_PRECONDITION,
      'Send called after CloseAndReceive or Abandon');
  if FChannel = nil then
    Fail(GRPC_STATUS_UNAVAILABLE,
      'the channel was freed while this call was open');
  try
    LFramed := GrpcFrameMessage(TProtoSerializer.Serialize(ARequest));
    FChannel.FClient.SendChunk(FStreamId, LFramed);
  except
    on E: EGrpcClientError do
    begin
      Abandon;
      raise;
    end;
    on E: Exception do
    begin
      Abandon;
      Fail(GRPC_STATUS_UNAVAILABLE, E.ClassName + ': ' + E.Message);
    end;
  end;
end;

function TGrpcClientWriterCall.CloseAndReceive: TObject;
var
  LResp:    TNghttp2Response;
  LPayload: TBytes;
  LError:   string;
  LObj:     TObject;
  LBudget:  Int64;
begin
  Result := nil;
  if FSendClosed then
    Fail(GRPC_STATUS_FAILED_PRECONDITION, 'CloseAndReceive already called');
  if FChannel = nil then
    Fail(GRPC_STATUS_UNAVAILABLE,
      'the channel was freed while this call was open');

  if FDeadlineMS > 0 then
  begin
    LBudget := FDeadlineMS - ElapsedMS(FStart);
    if LBudget <= 0 then
      Fail(GRPC_STATUS_DEADLINE_EXCEEDED, Format(
        'deadline of %d ms exceeded before CloseAndReceive', [FDeadlineMS]));
  end
  else
    LBudget := FChannel.FCallTimeoutMS;

  FSendClosed := True;
  try
    FChannel.FClient.FinishSending(FStreamId);
    FChannel.FClient.PumpAll(Integer(LBudget));
    LResp := FChannel.FClient.TakeResponse(FStreamId);
  except
    on E: ENghttp2Timeout do
    begin
      try FChannel.FClient.Disconnect; except end;
      if FDeadlineMS > 0 then
        Fail(GRPC_STATUS_DEADLINE_EXCEEDED, Format(
          'deadline of %d ms exceeded (%s)', [FDeadlineMS, E.Message]))
      else
        Fail(GRPC_STATUS_DEADLINE_EXCEEDED, Format(
          'no reply within CallTimeoutMS = %d ms (%s)',
          [FChannel.FCallTimeoutMS, E.Message]));
    end;
    on E: EGrpcClientError do
    begin
      Abandon;
      raise;
    end;
    on E: Exception do
    begin
      Abandon;
      Fail(GRPC_STATUS_UNAVAILABLE, E.ClassName + ': ' + E.Message);
    end;
  end;

  if (FChannel <> nil) and (FChannel.FOpenWriterCall = Self) then
    FChannel.FOpenWriterCall := nil;
  FChannel := nil;

  CheckResponseHead(LResp, FPath);
  CheckGrpcStatus(LResp);

  if Length(LResp.Body) = 0 then
    Fail(GRPC_STATUS_INTERNAL,
      'grpc-status 0 but the client-stream response carried no message');
  if GrpcFrameTooLarge(LResp.Body, GRPC_DEFAULT_MAX_MESSAGE_BYTES) then
    Fail(GRPC_STATUS_RESOURCE_EXHAUSTED,
      'the response message exceeds MaxReceiveMessageBytes');
  if not GrpcUnframeMessage(LResp.Body, LPayload, LError,
                            GRPC_DEFAULT_MAX_MESSAGE_BYTES) then
    Fail(GRPC_STATUS_INTERNAL, LError);
  if Length(LResp.Body) > GRPC_FRAME_HEADER_BYTES + Length(LPayload) then
    Fail(GRPC_STATUS_INTERNAL,
      'a client-stream response carried more than one message');

  LObj := FResponseClass.Create;
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

{ ── TGrpcBidiStream (GC5) ──────────────────────────────────────────────── }

type
  TGrpcBidiStream = class(TInterfacedObject, IGrpcBidiStream)
  private
    FChannel:       TGrpcChannel;   // nil once finished or abandoned
    FStreamId:      Int32;
    FPath:          string;
    FResponseClass: TClass;
    FDeadlineMS:    Integer;
    FStart:         TDateTime;
    FReasm:         TGrpcMessageReassembler;
    FCurrent:       TObject;
    FCount:         Integer;
    FHeadChecked:   Boolean;
    FTaken:         Boolean;
    FFinished:      Boolean;
    FSendClosed:    Boolean;
    procedure Finish;
    procedure Abandon;
  public
    constructor Create(AChannel: TGrpcChannel; AStreamId: Int32;
      const APath: string; AResponseClass: TClass;
      ADeadlineMS: Integer; AStart: TDateTime);
    destructor Destroy; override;
    procedure Send(ARequest: TObject);
    procedure CloseSend;
    function  MoveNext: Boolean;
    function  GetCurrent: TObject;
    function  Received: Integer;
  end;

constructor TGrpcBidiStream.Create(AChannel: TGrpcChannel; AStreamId: Int32;
  const APath: string; AResponseClass: TClass; ADeadlineMS: Integer;
  AStart: TDateTime);
begin
  inherited Create;
  FChannel       := AChannel;
  FStreamId      := AStreamId;
  FPath          := APath;
  FResponseClass := AResponseClass;
  FDeadlineMS    := ADeadlineMS;
  FStart         := AStart;
  FReasm         := TGrpcMessageReassembler.Create(AChannel.FMaxReceiveBytes);
end;

destructor TGrpcBidiStream.Destroy;
begin
  FreeAndNil(FCurrent);
  if not FFinished then
    Abandon;
  FReasm.Free;
  inherited;
end;

procedure TGrpcBidiStream.Finish;
begin
  if FChannel <> nil then
  begin
    if FChannel.FOpenStream = Self then
      FChannel.FOpenStream := nil;
    FChannel := nil;
  end;
  FFinished := True;
end;

procedure TGrpcBidiStream.Abandon;
begin
  if (FChannel <> nil) and not FTaken then
    try
      FChannel.FClient.Disconnect;
    except
    end;
  Finish;
end;

function TGrpcBidiStream.GetCurrent: TObject;
begin
  Result := FCurrent;
end;

function TGrpcBidiStream.Received: Integer;
begin
  Result := FCount;
end;

procedure TGrpcBidiStream.Send(ARequest: TObject);
var
  LFramed: TBytes;
begin
  if FSendClosed then
    Fail(GRPC_STATUS_FAILED_PRECONDITION,
      'Send called after CloseSend');
  if FFinished then
    Fail(GRPC_STATUS_FAILED_PRECONDITION,
      'Send called on a finished bidi stream');
  if FChannel = nil then
    Fail(GRPC_STATUS_UNAVAILABLE,
      'the channel was freed while this stream was open');
  try
    LFramed := GrpcFrameMessage(TProtoSerializer.Serialize(ARequest));
    FChannel.FClient.SendChunk(FStreamId, LFramed);
  except
    on E: EGrpcClientError do
    begin
      Abandon;
      raise;
    end;
    on E: Exception do
    begin
      Abandon;
      Fail(GRPC_STATUS_UNAVAILABLE, E.ClassName + ': ' + E.Message);
    end;
  end;
end;

procedure TGrpcBidiStream.CloseSend;
begin
  if FSendClosed or FFinished then
    Exit;
  if FChannel = nil then
    Exit;
  try
    FChannel.FClient.FinishSending(FStreamId);
    FSendClosed := True;
  except
    on E: EGrpcClientError do
    begin
      Abandon;
      raise;
    end;
    on E: Exception do
    begin
      Abandon;
      Fail(GRPC_STATUS_UNAVAILABLE, E.ClassName + ': ' + E.Message);
    end;
  end;
end;

function TGrpcBidiStream.MoveNext: Boolean;
const
  READ_CHUNK = 65536;
var
  LPayload: TBytes;
  LChunk:   TBytes;
  LError:   string;
  LGot:     Integer;
  LWaitMS:  Int64;
  LObj:     TObject;
  LResp:    TNghttp2Response;
begin
  Result := False;
  FreeAndNil(FCurrent);
  if FFinished then
    Exit;
  if FChannel = nil then
  begin
    FFinished := True;
    Fail(GRPC_STATUS_UNAVAILABLE, 'the channel was freed while this stream was open');
  end;

  try
    repeat
      case FReasm.TryNext(LPayload, LError) of
        gfrMessage:
          begin
            LObj := FResponseClass.Create;
            try
              TProtoSerializer.Deserialize(LPayload, LObj);
            except
              on E: Exception do
              begin
                LObj.Free;
                Fail(GRPC_STATUS_INTERNAL, Format('message %d decode failed: %s',
                  [FCount + 1, E.Message]));
              end;
            end;
            FCurrent := LObj;
            Inc(FCount);
            Result := True;
            Exit;
          end;
        gfrError:
          if FReasm.TooLarge then
            Fail(GRPC_STATUS_RESOURCE_EXHAUSTED, Format('message %d: %s',
              [FCount + 1, LError]))
          else
            Fail(GRPC_STATUS_INTERNAL, Format('message %d: %s',
              [FCount + 1, LError]));
        gfrNeedMore:
          ;
      end;

      if FDeadlineMS > 0 then
      begin
        LWaitMS := FDeadlineMS - ElapsedMS(FStart);
        if LWaitMS <= 0 then
          Fail(GRPC_STATUS_DEADLINE_EXCEEDED, Format(
            'deadline of %d ms exceeded after %d message(s)',
            [FDeadlineMS, FCount]));
      end
      else
        LWaitMS := FChannel.FCallTimeoutMS;

      LGot := FChannel.FClient.ReadChunk(FStreamId, LChunk, READ_CHUNK,
        Integer(LWaitMS));
      if LGot < 0 then
      begin
        if FDeadlineMS > 0 then
          Continue;
        Fail(GRPC_STATUS_DEADLINE_EXCEEDED, Format(
          'no message within CallTimeoutMS = %d ms after %d message(s)',
          [FChannel.FCallTimeoutMS, FCount]));
      end;

      if not FHeadChecked then
      begin
        if FChannel.FClient.PeekResponseHeaders(FStreamId, LResp) then
          CheckResponseHead(LResp, FPath);
        FHeadChecked := True;
      end;

      if LGot > 0 then
        FReasm.Append(LChunk, LGot)
      else
      begin
        LResp := FChannel.FClient.TakeResponse(FStreamId);
        FTaken := True;
        if not FHeadChecked then
          CheckResponseHead(LResp, FPath);
        CheckGrpcStatus(LResp);
        if FReasm.BufferedBytes > 0 then
          Fail(GRPC_STATUS_INTERNAL, Format(
            'the stream ended inside message %d (%d byte(s) of it received)',
            [FCount + 1, FReasm.BufferedBytes]));
        Finish;
        Exit;
      end;
    until False;
  except
    on E: EGrpcClientError do
    begin
      Abandon;
      raise;
    end;
    on E: Exception do
    begin
      Abandon;
      Fail(GRPC_STATUS_UNAVAILABLE, E.ClassName + ': ' + E.Message);
    end;
  end;
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
  { A stream still referenced elsewhere must not reach a freed channel:
    detach it, and its next MoveNext / Send / CloseAndReceive raises 14. }
  if FOpenStream <> nil then
  begin
    if FOpenStream is TGrpcBidiStream then
      TGrpcBidiStream(FOpenStream).FChannel := nil
    else
      TGrpcClientStream(FOpenStream).FChannel := nil;
    FOpenStream := nil;
  end;
  if FOpenWriterCall <> nil then
  begin
    TGrpcClientWriterCall(FOpenWriterCall).FChannel := nil;
    FOpenWriterCall := nil;
  end;
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

{ GC4/GC5. One call at a time per channel: TNghttp2Client.PumpAll waits for
  EVERY open stream, so a second call while any streaming call is open would
  block until that call ended. Refusing says so at once. }
procedure TGrpcChannel.RefuseWhileStreaming;
begin
  if (FOpenStream <> nil) or (FOpenWriterCall <> nil) then
    Fail(GRPC_STATUS_FAILED_PRECONDITION, 'a streaming call is still open on ' +
      'this channel - finish it first (one call at a time per channel)');
end;

{ GC3: content-type, te, grpc-timeout, then the metadata, in Call-Definitions
  order. Validates the options first: a bad one is EArgumentException and
  nothing is sent. ABudgetMS: the deadline, or CallTimeoutMS without one. }
function TGrpcChannel.BuildCallHeaders(const AOptions: TGrpcCallOptions;
  out ABudgetMS: Integer): TNghttp2Headers;
var
  I: Integer;
begin
  if AOptions.DeadlineMS < 0 then
    raise EArgumentException.CreateFmt(
      'TGrpcChannel: DeadlineMS is %d - use 0 for no deadline',
      [AOptions.DeadlineMS]);
  ValidateMetadata(AOptions.Metadata);

  { te: trailers is REQUIRED of a gRPC client (gRPC over HTTP/2 spec): it is
    how the server knows the peer will read the trailer section at all. }
  SetLength(Result, 2);
  Result[0].Name  := 'content-type';
  Result[0].Value := 'application/grpc';
  Result[1].Name  := 'te';
  Result[1].Value := 'trailers';
  if AOptions.DeadlineMS > 0 then
  begin
    SetLength(Result, 3);
    Result[2].Name  := 'grpc-timeout';
    Result[2].Value := GrpcTimeoutValue(AOptions.DeadlineMS);
    ABudgetMS := AOptions.DeadlineMS;
  end
  else
    ABudgetMS := FCallTimeoutMS;
  for I := 0 to High(AOptions.Metadata) do
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := AOptions.Metadata[I];
  end;
end;

function TGrpcChannel.Unary(const APath: string; ARequest: TObject;
  AResponseClass: TClass): TObject;
begin
  Result := Unary(APath, ARequest, AResponseClass, TGrpcCallOptions.Default);
end;

function TGrpcChannel.Unary(const APath: string; ARequest: TObject;
  AResponseClass: TClass; const AOptions: TGrpcCallOptions): TObject;
var
  LHeaders:  TNghttp2Headers;
  LBody:     TBytes;
  LResp:     TNghttp2Response;
  LPayload:  TBytes;
  LError:    string;
  LObj:      TObject;
  LBudgetMS: Integer;
  LLeftMS:   Int64;
  LStart:    TDateTime;
begin
  Result := nil;
  if ARequest = nil then
    raise EArgumentException.Create('TGrpcChannel.Unary: ARequest is nil');
  if AResponseClass = nil then
    raise EArgumentException.Create('TGrpcChannel.Unary: AResponseClass is nil');
  LHeaders := BuildCallHeaders(AOptions, LBudgetMS);
  RefuseWhileStreaming;

  try
    LBody := GrpcFrameMessage(TProtoSerializer.Serialize(ARequest));
  except
    on E: Exception do
      Fail(GRPC_STATUS_INTERNAL, 'request encode failed: ' + E.Message);
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

  CheckResponseHead(LResp, APath);
  CheckGrpcStatus(LResp);

  { OK. A unary response carries exactly one message. A zero-LENGTH message
    (all fields at their defaults) is a message; NO message is a violation. }
  if Length(LResp.Body) = 0 then
    Fail(GRPC_STATUS_INTERNAL, 'grpc-status 0 but the response carried no message');
  if GrpcFrameTooLarge(LResp.Body, FMaxReceiveBytes) then
    Fail(GRPC_STATUS_RESOURCE_EXHAUSTED, Format(
      'the response message is over the %d-byte MaxReceiveMessageBytes',
      [FMaxReceiveBytes]));
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

function TGrpcChannel.ServerStream(const APath: string; ARequest: TObject;
  AResponseClass: TClass): IGrpcClientStream;
begin
  Result := ServerStream(APath, ARequest, AResponseClass, TGrpcCallOptions.Default);
end;

function TGrpcChannel.ServerStream(const APath: string; ARequest: TObject;
  AResponseClass: TClass; const AOptions: TGrpcCallOptions): IGrpcClientStream;
var
  LHeaders:  TNghttp2Headers;
  LBody:     TBytes;
  LBudgetMS: Integer;
  LStart:    TDateTime;
  LId:       Int32;
  LStream:   TGrpcClientStream;
begin
  Result := nil;
  if ARequest = nil then
    raise EArgumentException.Create('TGrpcChannel.ServerStream: ARequest is nil');
  if AResponseClass = nil then
    raise EArgumentException.Create('TGrpcChannel.ServerStream: AResponseClass is nil');
  LHeaders := BuildCallHeaders(AOptions, LBudgetMS);
  RefuseWhileStreaming;

  try
    LBody := GrpcFrameMessage(TProtoSerializer.Serialize(ARequest));
  except
    on E: Exception do
      Fail(GRPC_STATUS_INTERNAL, 'request encode failed: ' + E.Message);
  end;

  LStart := Now;
  LId := 0;
  try
    EnsureConnected;
    { AStreamResponse = True: the body goes to ReadChunk as it arrives instead
      of accumulating until END_STREAM. }
    LId := FClient.BeginRequest('POST', APath, LHeaders, LBody, True);
  except
    on E: Exception do
      Fail(GRPC_STATUS_UNAVAILABLE, E.ClassName + ': ' + E.Message);
  end;

  LStream := TGrpcClientStream.Create(Self, LId, APath, AResponseClass,
    AOptions.DeadlineMS, LStart);
  FOpenStream := LStream;
  Result := LStream;
end;

function TGrpcChannel.ClientStream(const APath: string;
  AResponseClass: TClass): IGrpcClientWriterCall;
begin
  Result := ClientStream(APath, AResponseClass, TGrpcCallOptions.Default);
end;

function TGrpcChannel.ClientStream(const APath: string;
  AResponseClass: TClass;
  const AOptions: TGrpcCallOptions): IGrpcClientWriterCall;
var
  LHeaders:  TNghttp2Headers;
  LBudgetMS: Integer;
  LStart:    TDateTime;
  LId:       Int32;
  LCall:     TGrpcClientWriterCall;
begin
  Result := nil;
  if AResponseClass = nil then
    raise EArgumentException.Create('TGrpcChannel.ClientStream: AResponseClass is nil');
  LHeaders := BuildCallHeaders(AOptions, LBudgetMS);
  RefuseWhileStreaming;

  LStart := Now;
  LId := 0;
  try
    EnsureConnected;
    LId := FClient.BeginStreamingRequest('POST', APath, LHeaders, False);
  except
    on E: Exception do
      Fail(GRPC_STATUS_UNAVAILABLE, E.ClassName + ': ' + E.Message);
  end;

  LCall := TGrpcClientWriterCall.Create(Self, LId, APath, AResponseClass,
    AOptions.DeadlineMS, LStart);
  FOpenWriterCall := LCall;
  Result := LCall;
end;

function TGrpcChannel.BidiStream(const APath: string;
  AResponseClass: TClass): IGrpcBidiStream;
begin
  Result := BidiStream(APath, AResponseClass, TGrpcCallOptions.Default);
end;

function TGrpcChannel.BidiStream(const APath: string;
  AResponseClass: TClass;
  const AOptions: TGrpcCallOptions): IGrpcBidiStream;
var
  LHeaders:  TNghttp2Headers;
  LBudgetMS: Integer;
  LStart:    TDateTime;
  LId:       Int32;
  LBidi:     TGrpcBidiStream;
begin
  Result := nil;
  if AResponseClass = nil then
    raise EArgumentException.Create('TGrpcChannel.BidiStream: AResponseClass is nil');
  LHeaders := BuildCallHeaders(AOptions, LBudgetMS);
  RefuseWhileStreaming;

  LStart := Now;
  LId := 0;
  try
    EnsureConnected;
    LId := FClient.BeginStreamingRequest('POST', APath, LHeaders, True);
  except
    on E: Exception do
      Fail(GRPC_STATUS_UNAVAILABLE, E.ClassName + ': ' + E.Message);
  end;

  LBidi := TGrpcBidiStream.Create(Self, LId, APath, AResponseClass,
    AOptions.DeadlineMS, LStart);
  FOpenStream := LBidi;
  Result := LBidi;
end;

end.
