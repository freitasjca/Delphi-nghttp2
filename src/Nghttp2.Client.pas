unit Nghttp2.Client;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Nghttp2.Client
//  Synchronous HTTP/2 (h2c cleartext, prior knowledge) client for Delphi + FPC.
//
//  Usage:
//    var C: TNghttp2Client;
//    var R: TNghttp2Response;
//    C := TNghttp2Client.Create;
//    try
//      C.Connect('127.0.0.1', 9010);
//      R := C.SubmitRequest('GET', '/ping', nil, nil);
//      WriteLn(R.Status, ' ', TEncoding.UTF8.GetString(R.Body));
//    finally
//      C.Free;
//    end;
//
//  Design constraints:
//    - Synchronous only. SubmitRequest blocks until the target stream closes
//      (END_STREAM from server). One in-flight request per client instance.
//    - Prior-knowledge h2c only. The client sends the HTTP/2 preface
//      (RFC 7540 §3.4) immediately after TCP connect — no h2c Upgrade
//      handshake, no ALPN, no TLS. v1.1 adds TLS.
//    - Thread affinity: NOT thread-safe. One request at a time per client.
//    - Cross-platform: reuses Nghttp2.Socket for all platform I/O — no
//      Winapi.WinSock2 / Posix.* / FPC Sockets references in this unit.
//    - v1 accepts request-body-less requests only (GET, HEAD, DELETE).
//      POST/PUT with body lands in v0.2 (needs data_provider_read_callback
//      wiring to stream the body up-front instead of buffering).
//
//  Wire behaviour (validated against nghttp / curl --http2-prior-knowledge):
//    1. TCP connect
//    2. Submit our SETTINGS frame via nghttp2_submit_settings (queued)
//    3. FlushSession — libnghttp2 automatically prepends the 24-byte client
//       connection preface ("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n") to the first
//       mem_send output. DO NOT send the preface manually — doing so
//       produces two prefaces on the wire and the server responds with
//       GOAWAY(PROTOCOL_ERROR). See Connect() for details.
//    4. Enter recv/send loop until SubmitRequest's target stream closes
//    5. Server's SETTINGS + ACK exchange runs interleaved with the request
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$IFEND}
  Nghttp2.Native,
  Nghttp2.Socket,
  Nghttp2.Tls;   { for optional TTlsClientContext / TTlsClientConnection }

const
  HTTP2_CLIENT_PREFACE: RawByteString = 'PRI * HTTP/2.0'#13#10#13#10'SM'#13#10#13#10;
  //                                    24 bytes total — RFC 7540 §3.4.
  //                                    Not used at runtime — libnghttp2 auto-
  //                                    emits this via mem_send. Kept as a
  //                                    named constant for debugging / docs.

  DEFAULT_RECV_BUFFER_SIZE   = 16 * 1024;
  DEFAULT_REQUEST_TIMEOUT_MS = 30000;

type
  ENghttp2Client = class(Exception);

  { Simple name/value header pair — HTTP/2 pseudo-headers (:method, :path,
    :authority, :scheme) are added automatically by SubmitRequest; callers
    provide only regular headers here. }
  TNghttp2Header = record
    Name:  string;
    Value: string;
  end;
  TNghttp2Headers = array of TNghttp2Header;

  { Complete response captured after the server sent END_STREAM. }
  TNghttp2Response = record
    Status:  Integer;
    Headers: TNghttp2Headers;
    Body:    TBytes;
  end;

  TNghttp2Client = class
  private
    // NOTE: plain `private` (not `strict private`) is required — the FFI
    // callbacks below (OnHeaderCb / OnDataChunkRecvCb / OnStreamCloseCb) are
    // unit-scope C-callable functions, not methods, and they must reach into
    // the client instance via user_data. Delphi's `strict private` forbids
    // that even within the same unit; plain `private` grants unit-level
    // access, which is the standard idiom for FFI callback bridging.
    FSocket:      TSocketHandle;
    FSession:     Pnghttp2_session;
    FCallbacks:   Pnghttp2_session_callbacks;
    FHost:        string;
    FPort:        Word;
    FConnected:   Boolean;
    FRecvBuffer:  TBytes;
    // Optional TLS. Non-owning reference — the caller allocates + configures
    // the TTlsClientContext (SetInsecure, EnableHttp2Alpn) and frees it after
    // this client is done. nil = plain h2c on the socket.
    FTlsContext:  TTlsClientContext;
    // Per-connection TLS wrapper (allocated by Connect when FTlsContext<>nil).
    FTlsConn:     TTlsClientConnection;

    // In-flight response accumulator. Populated by the on_header /
    // on_data_chunk_recv / on_stream_close callbacks. One request at a time,
    // so a stream_id → response map isn't needed for v1.
    FActiveStreamId: Int32;
    FActiveResponse: TNghttp2Response;
    FActiveDone:     Boolean;
    FActiveError:    string;

    // Request body cursor — read by ReadRequestBodyCallback while nghttp2
    // pulls bytes for the outgoing DATA frames of the current stream.
    FActiveRequestBody:    TBytes;
    FActiveRequestBodyPos: Integer;

    procedure SubmitClientSettings;
    procedure FlushSession;
    procedure PumpUntilDone(ATimeoutMS: Integer);

    // Transport-agnostic I/O helpers. Route through TLS if FTlsConn <> nil,
    // otherwise use the plain-socket helpers from Nghttp2.Socket. Same
    // pattern as Nghttp2.Server's connection thread (nested procs there;
    // methods here because the client has methods to call from anyway).
    function DoRead(ABuf: Pointer; ALen: Integer): Integer;
    function DoSendAll(ABuf: Pointer; ALen: Integer): Boolean;

    function MilliSecondsSince(const AStart: TDateTime): Int64;
  public
    constructor Create;
    destructor  Destroy; override;

    procedure Connect(const AHost: string; APort: Word);
    procedure Disconnect;

    // Send one request and block until the response arrives.
    //   AHeaders — regular headers (no pseudo-headers). May be empty.
    //   ABody    — request body. v1 requires nil/empty; POST body support in v0.2.
    function SubmitRequest(
      const AMethod:  string;
      const APath:    string;
      const AHeaders: TNghttp2Headers;
      const ABody:    TBytes;
      ATimeoutMS: Integer = DEFAULT_REQUEST_TIMEOUT_MS): TNghttp2Response;

    property Connected:  Boolean            read FConnected;
    property Host:       string             read FHost;
    property Port:       Word               read FPort;
    // Optional TLS. Assign BEFORE calling Connect. Non-owning: caller
    // creates + configures + frees the TTlsClientContext. Leave nil for
    // cleartext h2c. See Delphi-nghttp2/samples for a full example.
    property TlsContext: TTlsClientContext  read FTlsContext write FTlsContext;
  end;

  // Convenience — one-shot request without holding a TNghttp2Client. Opens,
  // sends, receives, closes. Useful for smoke tests.
  function Nghttp2Get(const AURL: string; ATimeoutMS: Integer = DEFAULT_REQUEST_TIMEOUT_MS): TNghttp2Response;

implementation

// ─── nghttp2 callbacks ────────────────────────────────────────────────────
// All callbacks receive user_data — Self was passed at nghttp2_session_client_new,
// so cast back to TNghttp2Client. Callbacks fire synchronously from inside
// nghttp2_session_mem_recv, so no locking is needed (single-threaded pump).

function OnHeaderCb(
  session: Pnghttp2_session;
  const frame: Pnghttp2_frame;
  const name:  PByte; namelen:  NativeUInt;
  const value: PByte; valuelen: NativeUInt;
  flags: Byte;
  user_data: Pointer): Integer; cdecl;
var
  LClient: TNghttp2Client;
  LName, LValue: AnsiString;
  LHdr: TNghttp2Header;
begin
  LClient := TNghttp2Client(user_data);
  if (LClient = nil) or (frame^.hd.stream_id <> LClient.FActiveStreamId) then
    Exit(0);

  SetString(LName,  PAnsiChar(name),  namelen);
  SetString(LValue, PAnsiChar(value), valuelen);

  if LName = ':status' then
    LClient.FActiveResponse.Status := StrToIntDef(string(LValue), 0)
  else if (Length(LName) = 0) or (LName[1] <> ':') then
  begin
    LHdr.Name  := string(LName);
    LHdr.Value := string(LValue);
    LClient.FActiveResponse.Headers := LClient.FActiveResponse.Headers + [LHdr];
  end;
  Result := 0;
end;

function OnDataChunkRecvCb(
  session: Pnghttp2_session;
  flags: Byte;
  stream_id: Int32;
  const data: PByte; len: NativeUInt;
  user_data: Pointer): Integer; cdecl;
var
  LClient: TNghttp2Client;
  LOldLen: Integer;
begin
  LClient := TNghttp2Client(user_data);
  if (LClient = nil) or (stream_id <> LClient.FActiveStreamId) or (len = 0) then
    Exit(0);

  LOldLen := Length(LClient.FActiveResponse.Body);
  SetLength(LClient.FActiveResponse.Body, LOldLen + Integer(len));
  Move(data^, LClient.FActiveResponse.Body[LOldLen], len);
  Result := 0;
end;

function OnStreamCloseCb(
  session: Pnghttp2_session;
  stream_id: Int32;
  error_code: UInt32;
  user_data: Pointer): Integer; cdecl;
var
  LClient: TNghttp2Client;
begin
  LClient := TNghttp2Client(user_data);
  if (LClient = nil) or (stream_id <> LClient.FActiveStreamId) then
    Exit(0);

  LClient.FActiveDone := True;
  if error_code <> NGHTTP2_NO_ERROR then
    LClient.FActiveError := Format(
      'stream %d closed with nghttp2 error code %d — received status=%d, %d header(s), %d body byte(s) before close',
      [stream_id, error_code,
       LClient.FActiveResponse.Status,
       Length(LClient.FActiveResponse.Headers),
       Length(LClient.FActiveResponse.Body)]);
  Result := 0;
end;

// ─── Request body data provider (POST/PUT/PATCH support) ─────────────────
// Called by nghttp2 to pull request body bytes as it emits DATA frames.
// Reads from FActiveRequestBody at FActiveRequestBodyPos; sets EOF when
// the buffer is exhausted.

function ReadRequestBodyCallback(
  session: Pnghttp2_session;
  stream_id: Int32;
  buf: PByte; length: NativeUInt;
  data_flags: PUInt32;
  source: Pointer;
  user_data: Pointer): NativeInt; cdecl;
var
  LClient:    TNghttp2Client;
  LRemaining: NativeInt;
  LToRead:    NativeInt;
begin
  LClient := TNghttp2Client(user_data);
  if LClient = nil then Exit(0);

  LRemaining := System.Length(LClient.FActiveRequestBody) - LClient.FActiveRequestBodyPos;
  if LRemaining <= 0 then
  begin
    data_flags^ := NGHTTP2_DATA_FLAG_EOF;
    Exit(0);
  end;

  if LRemaining < NativeInt(length) then
    LToRead := LRemaining
  else
    LToRead := NativeInt(length);

  Move(LClient.FActiveRequestBody[LClient.FActiveRequestBodyPos],
       buf^, LToRead);
  Inc(LClient.FActiveRequestBodyPos, LToRead);

  if LClient.FActiveRequestBodyPos >= System.Length(LClient.FActiveRequestBody) then
    data_flags^ := NGHTTP2_DATA_FLAG_EOF;

  Result := LToRead;
end;

// ─── TNghttp2Client ───────────────────────────────────────────────────────

constructor TNghttp2Client.Create;
var
  LRet: Integer;
begin
  inherited Create;

  // Dynamic-load libnghttp2 at first client construction.  Refactored
  // 2026-08-06 to eliminate the -lnghttp2 link-time dependency.  MUST run
  // before any nghttp2_* FFI call — the callback-registration below uses
  // several, so the load hook can't live in Connect.  Idempotent — cached
  // True on repeat.
  if not NghttpLoad then
    raise ENghttp2Client.CreateFmt(
      'libnghttp2 could not be loaded — %s.  Install the nghttp2 runtime ' +
      'library and (Windows) ensure nghttp2.dll is on PATH or next to the .exe.',
      [NghttpLoadError]);

  InitSockets;   // no-op on non-Windows
  SetLength(FRecvBuffer, DEFAULT_RECV_BUFFER_SIZE);
  FSocket := INVALID_SOCKET_HANDLE;
  FSession        := nil;
  FCallbacks      := nil;
  FConnected      := False;
  FActiveStreamId := -1;
  FTlsContext     := nil;   // caller opts in via TlsContext property
  FTlsConn        := nil;

  LRet := nghttp2_session_callbacks_new(FCallbacks);
  if LRet <> 0 then
    raise ENghttp2Client.CreateFmt('nghttp2_session_callbacks_new: %d', [LRet]);

  nghttp2_session_callbacks_set_on_header_callback(FCallbacks, @OnHeaderCb);
  nghttp2_session_callbacks_set_on_data_chunk_recv_callback(FCallbacks, @OnDataChunkRecvCb);
  nghttp2_session_callbacks_set_on_stream_close_callback(FCallbacks, @OnStreamCloseCb);

  // NOTE: on_frame_recv_callback + on_frame_send_callback are intentionally
  // NOT registered. libnghttp2 handles the SETTINGS/PING/GOAWAY exchanges
  // internally, and app-level visibility isn't needed for the request/
  // response flow. If you need wire-level tracing (e.g. investigating a
  // protocol bug), register those callbacks in a wrapper unit — the FFI
  // slots and Tnghttp2_* callback types remain declared in Nghttp2.Native.
end;

destructor TNghttp2Client.Destroy;
begin
  Disconnect;
  if FCallbacks <> nil then
    nghttp2_session_callbacks_del(FCallbacks);
  inherited;
end;

procedure TNghttp2Client.Connect(const AHost: string; APort: Word);
var
  LRet: Integer;
begin
  // NghttpLoad already fired in Create — see comment there.

  if FConnected then
    raise ENghttp2Client.Create('already connected — call Disconnect first');

  FHost := AHost;
  FPort := APort;

  // TCP connect (cross-platform, from Nghttp2.Socket).
  FSocket := ConnectToHost(AHost, APort);

  // ── TLS handshake (optional) ────────────────────────────────────────────
  // If the caller assigned a TTlsClientContext before calling Connect, wrap
  // the socket with TLS: run SSL_connect, verify ALPN selected 'h2'. Any
  // failure closes the socket and re-raises — no fallback to cleartext.
  if FTlsContext <> nil then
  begin
    try
      FTlsConn := TTlsClientConnection.Create(FTlsContext, FSocket);
      FTlsConn.DoHandshake;
      if FTlsConn.NegotiatedProtocol <> 'h2' then
        raise ENghttp2Client.CreateFmt(
          'ALPN negotiation failed — server selected "%s" (expected "h2"). ' +
          'The server may not support HTTP/2 over TLS, or it may require a ' +
          'protocol other than h2 (which this client does not implement).',
          [FTlsConn.NegotiatedProtocol]);
    except
      // On TLS failure, tear down everything and re-raise. The caller sees
      // the ENghttp2Tls / ENghttp2Client with a specific error message.
      if FTlsConn <> nil then
      begin
        FreeAndNil(FTlsConn);
      end;
      CloseSocketHandle(FSocket);
      FSocket := INVALID_SOCKET_HANDLE;
      raise;
    end;
  end;

  // Client session — Self is the user_data returned to all callbacks.
  LRet := nghttp2_session_client_new(FSession, FCallbacks, Self);
  if LRet <> 0 then
  begin
    if FTlsConn <> nil then FreeAndNil(FTlsConn);
    CloseSocketHandle(FSocket);
    FSocket := INVALID_SOCKET_HANDLE;
    raise ENghttp2Client.CreateFmt('nghttp2_session_client_new: %d', [LRet]);
  end;

  // NOTE: DO NOT manually send the client preface here — libnghttp2 emits
  // the 24-byte preface automatically as part of the FIRST nghttp2_session_
  // mem_send() call on a client session (see nghttp2_session.c's
  // NGHTTP2_OB_FLAG_SENT_CLIENT_MAGIC handling). A manual send would
  // duplicate the preface on the wire: the server sees the second copy as
  // a malformed frame and sends GOAWAY(PROTOCOL_ERROR), which surfaces
  // client-side as CANCEL on the first request stream.
  SubmitClientSettings;
  FlushSession;   // libnghttp2 prepends the preface to this first flush

  FConnected := True;
end;

procedure TNghttp2Client.Disconnect;
begin
  if FSession <> nil then
  begin
    // Best-effort GOAWAY. Ignore errors on already-broken sockets — Disconnect
    // is called from Destroy which must not raise.
    try nghttp2_submit_goaway(FSession, 0, 0, NGHTTP2_NO_ERROR, nil, 0); except end;
    try FlushSession;                                                    except end;
    nghttp2_session_del(FSession);
    FSession := nil;
  end;

  // TLS teardown BEFORE closing the raw socket — SSL_shutdown wants a live fd.
  if FTlsConn <> nil then
  begin
    try FTlsConn.Shutdown; except end;
    FreeAndNil(FTlsConn);
  end;

  if FSocket <> INVALID_SOCKET_HANDLE then
  begin
    CloseSocketHandle(FSocket);
    FSocket := INVALID_SOCKET_HANDLE;
  end;
  FConnected := False;
end;

function TNghttp2Client.DoRead(ABuf: Pointer; ALen: Integer): Integer;
begin
  if FTlsConn <> nil then
    Result := FTlsConn.Read(ABuf, ALen)
  else
    Result := SocketRecv(FSocket, ABuf, ALen);
end;

function TNghttp2Client.DoSendAll(ABuf: Pointer; ALen: Integer): Boolean;
var
  LWritten: Integer;
begin
  if FTlsConn <> nil then
  begin
    // SSL_write in blocking mode returns ALen on success or <=0 on error.
    // Treat any short write as failure — full-length semantics mirror
    // SocketSendAll on the plain path.
    LWritten := FTlsConn.Write(ABuf, ALen);
    Result := LWritten = ALen;
  end
  else
    Result := SocketSendAll(FSocket, ABuf, ALen);
end;

procedure TNghttp2Client.SubmitClientSettings;
var
  LSettings: array[0..1] of Tnghttp2_settings_entry;
  LRet: Integer;
begin
  // Modest client-side SETTINGS. Server sends its own SETTINGS separately.
  LSettings[0].settings_id := NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS;
  LSettings[0].value       := 100;
  LSettings[1].settings_id := NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE;
  LSettings[1].value       := 1024 * 1024;

  LRet := nghttp2_submit_settings(FSession, NGHTTP2_FLAG_NONE,
    @LSettings[0], Length(LSettings));
  if LRet <> 0 then
    raise ENghttp2Client.CreateFmt('nghttp2_submit_settings: %d', [LRet]);
end;

procedure TNghttp2Client.FlushSession;
var
  LOutPtr: PByte;
  LOutLen: NativeInt;
begin
  while nghttp2_session_want_write(FSession) <> 0 do
  begin
    LOutLen := nghttp2_session_mem_send(FSession, LOutPtr);
    if LOutLen < 0 then
      raise ENghttp2Client.CreateFmt('nghttp2_session_mem_send: %d', [LOutLen]);
    if LOutLen = 0 then
      Break;
    if not DoSendAll(LOutPtr, LOutLen) then
      raise ENghttp2Client.Create('send failed during FlushSession');
  end;
end;

function TNghttp2Client.MilliSecondsSince(const AStart: TDateTime): Int64;
begin
  // Avoids dragging in DateUtils. TDateTime is days since 1899-12-30;
  // multiply by 86400*1000 to get ms.
  Result := Round((Now - AStart) * 86400.0 * 1000.0);
end;

procedure TNghttp2Client.PumpUntilDone(ATimeoutMS: Integer);
var
  LStart: TDateTime;
  LRecvLen: Integer;
  LConsumed: NativeInt;
begin
  LStart := Now;
  while not FActiveDone do
  begin
    if MilliSecondsSince(LStart) > ATimeoutMS then
      raise ENghttp2Client.CreateFmt(
        'request timed out after %d ms — server did not close stream %d',
        [ATimeoutMS, FActiveStreamId]);

    FlushSession;

    if nghttp2_session_want_read(FSession) = 0 then
      Break;

    LRecvLen := DoRead(@FRecvBuffer[0], Length(FRecvBuffer));
    if LRecvLen <= 0 then
      raise ENghttp2Client.Create('peer closed connection before stream end');

    LConsumed := nghttp2_session_mem_recv(FSession, @FRecvBuffer[0], LRecvLen);
    if LConsumed < 0 then
      raise ENghttp2Client.CreateFmt('nghttp2_session_mem_recv: %d', [LConsumed]);
  end;

  FlushSession;   // final flush of anything callbacks queued

  if FActiveError <> '' then
    raise ENghttp2Client.Create(FActiveError);
end;

function TNghttp2Client.SubmitRequest(
  const AMethod:  string;
  const APath:    string;
  const AHeaders: TNghttp2Headers;
  const ABody:    TBytes;
  ATimeoutMS: Integer): TNghttp2Response;
var
  LNvs:         array of Tnghttp2_nv;
  LNames:       array of AnsiString;    // hold refs so PAnsiChar stays valid
  LValues:      array of AnsiString;
  I, LBase:     Integer;
  LAuthority:   string;
  LStreamId:    Int32;
  LProvider:    Tnghttp2_data_provider;
  LProviderPtr: Pnghttp2_data_provider;
begin
  if not FConnected then
    raise ENghttp2Client.Create('not connected — call Connect first');

  // Per-request state reset. FActiveRequestBodyPos MUST be reset before
  // nghttp2_submit_request because the read callback can be invoked
  // immediately (during the first FlushSession).
  FActiveResponse       := Default(TNghttp2Response);
  FActiveDone           := False;
  FActiveError          := '';
  FActiveRequestBody    := ABody;
  FActiveRequestBodyPos := 0;

  LAuthority := FHost + ':' + IntToStr(FPort);
  LBase := 4;   // 4 pseudo-headers
  SetLength(LNvs,    LBase + Length(AHeaders));
  SetLength(LNames,  LBase + Length(AHeaders));
  SetLength(LValues, LBase + Length(AHeaders));

  LNames[0] := ':method';    LValues[0] := AnsiString(UpperCase(AMethod));
  LNames[1] := ':path';      LValues[1] := AnsiString(APath);
  LNames[2] := ':scheme';    LValues[2] := 'http';
  LNames[3] := ':authority'; LValues[3] := AnsiString(LAuthority);
  for I := 0 to High(AHeaders) do
  begin
    LNames [LBase + I] := AnsiString(LowerCase(AHeaders[I].Name));
    LValues[LBase + I] := AnsiString(AHeaders[I].Value);
  end;

  for I := 0 to High(LNvs) do
  begin
    LNvs[I].name     := PByte(PAnsiChar(LNames[I]));
    LNvs[I].namelen  := Length(LNames[I]);
    LNvs[I].value    := PByte(PAnsiChar(LValues[I]));
    LNvs[I].valuelen := Length(LValues[I]);
    LNvs[I].flags    := NGHTTP2_NV_FLAG_NONE;
  end;

  // Wire up a data provider only when there's actually a body. nil data_prd
  // tells libnghttp2 to set END_STREAM on the HEADERS frame — the right
  // choice for GET/HEAD/DELETE and empty POSTs (both are legal per RFC 7540).
  if Length(ABody) > 0 then
  begin
    LProvider.source.ptr    := nil;   // not used — we get Self via user_data
    LProvider.read_callback := @ReadRequestBodyCallback;
    LProviderPtr            := @LProvider;
  end
  else
    LProviderPtr := nil;

  LStreamId := nghttp2_submit_request(FSession, nil,
    @LNvs[0], Length(LNvs), LProviderPtr, Pointer(Self));
  if LStreamId < 0 then
    raise ENghttp2Client.CreateFmt('nghttp2_submit_request: %d', [LStreamId]);

  FActiveStreamId := LStreamId;

  PumpUntilDone(ATimeoutMS);

  Result := FActiveResponse;
  FActiveStreamId := -1;
end;

// ─── Convenience one-shot helper ─────────────────────────────────────────

function Nghttp2Get(const AURL: string; ATimeoutMS: Integer): TNghttp2Response;
var
  LClient:    TNghttp2Client;
  LTls:       TTlsClientContext;
  LHost, LPath, LScheme: string;
  LPort:      Word;
  LColonPos, LSlashPos, LSchemePos: Integer;
  LIsHttps:   Boolean;
begin
  // Very small URL parser: (http|https)://host[:port]/path. No auth, no
  // fragment, no query-string escaping beyond what's already in AURL.
  // IPv4 literal only (no DNS resolution). Default ports: 80 / 443.
  LSchemePos := Pos('://', AURL);
  if LSchemePos = 0 then
    raise ENghttp2Client.CreateFmt(
      'malformed URL "%s" — expected http://host[:port]/path or https://...', [AURL]);

  LScheme  := LowerCase(Copy(AURL, 1, LSchemePos - 1));
  LIsHttps := LScheme = 'https';
  if (LScheme <> 'http') and (LScheme <> 'https') then
    raise ENghttp2Client.CreateFmt(
      'unsupported URL scheme "%s" — only http and https are supported', [LScheme]);

  LHost := Copy(AURL, LSchemePos + 3, MaxInt);
  LSlashPos := Pos('/', LHost);
  if LSlashPos = 0 then
    LPath := '/'
  else
  begin
    LPath := Copy(LHost, LSlashPos, MaxInt);
    SetLength(LHost, LSlashPos - 1);
  end;

  LColonPos := Pos(':', LHost);
  if LColonPos > 0 then
  begin
    LPort := StrToIntDef(Copy(LHost, LColonPos + 1, MaxInt),
                         Ord(LIsHttps) * 443 + Ord(not LIsHttps) * 80);
    SetLength(LHost, LColonPos - 1);
  end
  else if LIsHttps then
    LPort := 443
  else
    LPort := 80;

  LTls    := nil;
  LClient := TNghttp2Client.Create;
  try
    if LIsHttps then
    begin
      // Convenience-mode TLS: skip cert verification (self-signed OK for
      // local testing). Production callers should construct their own
      // TTlsClientContext with proper CA setup and use TNghttp2Client
      // directly rather than this helper.
      LTls := TTlsClientContext.Create;
      LTls.SetInsecure;
      LTls.EnableHttp2Alpn;
      LClient.TlsContext := LTls;
    end;

    LClient.Connect(LHost, LPort);
    Result := LClient.SubmitRequest('GET', LPath, nil, nil, ATimeoutMS);
  finally
    LClient.Free;
    LTls.Free;   // safe if nil
  end;
end;

end.
