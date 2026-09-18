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
//  Scope: this client drives the test suites and samples. It is not a
//  general-purpose HTTP client; the constraints below are current fact, and
//  anything beyond them is roadmap work (see README: session pool, async API).
//
//  Design constraints (reviewed 2026-09-16):
//    - Synchronous only. SubmitRequest blocks until the target stream closes
//      (END_STREAM from the server). BeginRequest / PumpAll / TakeResponse
//      (MULTISTREAM-1), and ReadChunk (CL3) for a streamed body, keep several
//      streams open on ONE connection, but the
//      caller's thread still drives the pump — there is no non-blocking submit.
//    - Prior-knowledge HTTP/2 only. The client sends the HTTP/2 preface
//      (RFC 7540 §3.4) immediately after TCP connect: no h2c Upgrade
//      handshake, no ALPN negotiation, no HTTP/1.1 fallback, so the peer must
//      already speak HTTP/2. TLS IS supported — assign TlsContext before
//      Connect (client certificates included); leave it nil for cleartext.
//    - Request bodies ARE supported. A non-empty ABody is sent through a
//      libnghttp2 data_provider, and stays in memory until the stream closes,
//      so this is not a streaming upload.
//    - Responses are buffered whole into TNghttp2Response.Body BY DEFAULT.
//      [CL3] Pass AStreamResponse=True to BeginRequest to opt one stream out:
//      its body is then delivered incrementally through ReadChunk and never
//      accumulates, which is what SSE and large downloads need. Opt-in per
//      stream, mirroring INBOUND-1 on the server side — nothing changes for a
//      stream that does not ask for it.
//    - Connect takes a host and a port. [CL1] The host may be a NAME on
//      Delphi (Windows + POSIX) and on FPC/Unix: Nghttp2.Socket resolves it
//      and tries every address returned, so an IPv6 peer works. On
//      FPC/Windows it must still be an IPv4 literal — there is no resolver to
//      call there — and a name raises. No proxy, no redirects, no cookies, no
//      content decompression, no retries.
//    - One connection per instance, NOT thread-safe, with no pooling or reuse
//      across hosts.
//    - Cross-platform: reuses Nghttp2.Socket for all platform I/O — no
//      Winapi.WinSock2 / Posix.* / FPC Sockets references in this unit.
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

  { MULTISTREAM-1 — one in-flight stream's accumulated state. The on_header,
    on_data_chunk_recv and on_stream_close callbacks each locate their slot by
    the stream_id nghttp2 hands them, rather than assuming a single active
    request. A slot stays InUse until its response is taken. }
  TNghttp2StreamSlot = record
    Id:         Int32;
    InUse:      Boolean;
    Done:       Boolean;
    Error:      string;
    Response:   TNghttp2Response;
    ReqBody:    TBytes;      { pulled by ReadRequestBodyCallback }
    ReqBodyPos: Integer;

    { [CL3] Opt-in incremental delivery. When Streaming is set, DATA goes to
      Inbound for ReadChunk to drain instead of accumulating in Response.Body.

      That choice is the whole point: buffering the whole body is right for a
      request/response exchange and wrong for anything long-lived — SSE, a
      large download, a streaming gRPC call — where the caller must see bytes
      while the peer is still sending. It mirrors INBOUND-1 on the server side,
      which is opt-in per stream for the same reason.

      InboundLen is the count of VALID bytes; Length(Inbound) is capacity and
      runs ahead of it, so a chunk does not reallocate on every DATA frame. }
    Streaming:  Boolean;
    Inbound:    TBytes;
    InboundLen: Integer;
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

    { MULTISTREAM-1 — per-stream state, indexed by nghttp2 stream id.

      Was a single FActive* set: one request at a time. That made case C of the
      drain gate — N streams sharing ONE connection through a graceful shutdown
      — inexpressible, and it is the only shape where GOAWAY's last_stream_id
      semantics are actually exercised.

      A plain array with linear search rather than a TDictionary: N is small
      (tens of streams), the scan is nothing beside a network round trip, and it
      keeps generic specialization out of a unit that must build on FPC 3.2.2 as
      well as trunk and Delphi.

      NOT thread-safe, by design. One thread drives one client; concurrency here
      means multiplexed streams on that connection, not a shared client. Use
      separate clients for separate connections. }
    FStreams: array of TNghttp2StreamSlot;

    function  FindSlot(AStreamId: Int32): Integer;
    function  AllocSlot(AStreamId: Int32): Integer;
    function  AnyPending: Boolean;

    procedure SubmitClientSettings;
    procedure FlushSession;
    procedure PumpUntilDone(ATimeoutMS: Integer);

    { [CL3] ONE pass of the pump, bounded by ATimeoutMS.

      PumpUntilDone loops `while AnyPending`, so ReadChunk cannot use it: it
      would block until the whole stream finished, which is exactly what
      incremental delivery is not. This is the same loop body, run once.

      Returns  1  bytes were received and fed to nghttp2
               0  the deadline passed with nothing to read
              -1  the session no longer wants to read (nothing more is coming) }
    function  PumpOnce(ATimeoutMS: Integer): Integer;

    // Transport-agnostic I/O helpers. Route through TLS if FTlsConn <> nil,
    // otherwise use the plain-socket helpers from Nghttp2.Socket. Same
    // pattern as Nghttp2.Server's connection thread (nested procs there;
    // methods here because the client has methods to call from anyway).
    { [CL2c] ATimeoutMS <= 0 blocks indefinitely, which is what every caller
      got before this. Above 0, ATimedOut comes back True when the deadline
      passed with no bytes and the connection is still healthy — distinct from
      a 0 return, which means the peer closed. }
    function DoRead(ABuf: Pointer; ALen: Integer;
      ATimeoutMS: Integer; out ATimedOut: Boolean): Integer;
    function DoSendAll(ABuf: Pointer; ALen: Integer): Boolean;

    function MilliSecondsSince(const AStart: TDateTime): Int64;
  public
    constructor Create;
    destructor  Destroy; override;

    procedure Connect(const AHost: string; APort: Word);
    procedure Disconnect;

    // Send one request and block until the response arrives.
    //   AHeaders — regular headers (no pseudo-headers). May be empty.
    //   ABody    — request body, sent through a data_provider when non-empty
    //              and held in memory until the stream closes. nil for none.
    function SubmitRequest(
      const AMethod:  string;
      const APath:    string;
      const AHeaders: TNghttp2Headers;
      const ABody:    TBytes;
      ATimeoutMS: Integer = DEFAULT_REQUEST_TIMEOUT_MS): TNghttp2Response;

    { MULTISTREAM-1 — the three-call form SubmitRequest is built from. Use it to
      hold several streams open on ONE connection at once, which SubmitRequest
      cannot express because it pumps to completion before returning.

        for I := 1 to 8 do Ids[I] := C.BeginRequest('GET', '/slow/3000', ...);
        C.PumpAll(20000);
        for I := 1 to 8 do R[I] := C.TakeResponse(Ids[I]);

      BeginRequest submits and returns immediately. PumpAll drives the session
      until every open stream has closed, or the timeout expires. TakeResponse
      hands back one stream's result and frees its slot — raising if THAT stream
      failed, so one broken stream does not discard the others. }
    { [CL3] AStreamResponse opts this stream into incremental delivery: the body
      is NOT accumulated into the response, and must be drained with ReadChunk.
      Default False, so every existing caller is unaffected. }
    function  BeginRequest(
      const AMethod:  string;
      const APath:    string;
      const AHeaders: TNghttp2Headers;
      const ABody:    TBytes;
      AStreamResponse: Boolean = False): Int32;
    procedure PumpAll(ATimeoutMS: Integer = DEFAULT_REQUEST_TIMEOUT_MS);
    function  TakeResponse(AStreamId: Int32): TNghttp2Response;
    function  PendingStreams: Integer;

    { [CL3] Read the next piece of a streaming response.

        > 0   bytes copied into ABuffer (which is sized to exactly that many)
        = 0   end of stream: the peer sent END_STREAM and nothing more is coming
        < 0   the deadline passed and the stream is STILL OPEN — call again

      Deliberately the same three-way contract as INghttp2Stream.ReadInbound on
      the server side, so a reader written against one works against the other.

      NOTE the convention clash this sits on, because it has exactly one
      sensible resolution and the wrong guess is silent: ReadInbound uses <0 for
      "timed out, still open", while Nghttp2.Socket's SocketWaitReadable uses 0
      for timeout and >0 for ready. This follows ReadInbound — it is a
      stream-read API, and its callers already know that shape. Anyone wiring
      the two together must convert rather than assume.

      Partial reads are normal: this returns what has ARRIVED, not what was
      asked for. Only valid on a stream opened with AStreamResponse = True. }
    function  ReadChunk(AStreamId: Int32; var ABuffer: TBytes;
      ACount: Integer;
      ATimeoutMS: Integer = DEFAULT_REQUEST_TIMEOUT_MS): Integer;

    property Connected:  Boolean            read FConnected;
    property Host:       string             read FHost;
    property Port:       Word               read FPort;
    // Optional TLS. Assign BEFORE calling Connect. Non-owning: caller
    // creates + configures + frees the TTlsClientContext. Leave nil for
    // cleartext h2c. See Delphi-nghttp2/samples for a full example.
    //
    // Assigning this implies ALPN 'h2': Connect calls EnableHttp2Alpn on the
    // context itself, so callers need not. That happens at CONNECT time, not
    // on assignment — assignment order does not matter, and the list is
    // re-applied on every Connect. Calling EnableHttp2Alpn yourself is still
    // fine (it is idempotent); the four call sites that do were written before
    // this and are left alone.
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
  LIdx: Integer;
begin
  LClient := TNghttp2Client(user_data);
  if LClient = nil then Exit(0);
  LIdx := LClient.FindSlot(frame^.hd.stream_id);   { MULTISTREAM-1 }
  if LIdx < 0 then Exit(0);

  SetString(LName,  PAnsiChar(name),  namelen);
  SetString(LValue, PAnsiChar(value), valuelen);

  if LName = ':status' then
    LClient.FStreams[LIdx].Response.Status := StrToIntDef(string(LValue), 0)
  else if (Length(LName) = 0) or (LName[1] <> ':') then
  begin
    LHdr.Name  := string(LName);
    LHdr.Value := string(LValue);
    LClient.FStreams[LIdx].Response.Headers :=
      LClient.FStreams[LIdx].Response.Headers + [LHdr];
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
  LIdx:    Integer;
begin
  LClient := TNghttp2Client(user_data);
  if (LClient = nil) or (len = 0) then Exit(0);
  LIdx := LClient.FindSlot(stream_id);   { MULTISTREAM-1 }
  if LIdx < 0 then Exit(0);

  { [CL3] Streaming streams divert here: the bytes go to Inbound for ReadChunk
    to drain, and Response.Body stays empty. Capacity is doubled rather than
    grown exactly, so a long stream does not reallocate on every DATA frame. }
  if LClient.FStreams[LIdx].Streaming then
  begin
    LOldLen := LClient.FStreams[LIdx].InboundLen;
    if LOldLen + Integer(len) > Length(LClient.FStreams[LIdx].Inbound) then
      SetLength(LClient.FStreams[LIdx].Inbound, (LOldLen + Integer(len)) * 2);
    Move(data^, LClient.FStreams[LIdx].Inbound[LOldLen], len);
    Inc(LClient.FStreams[LIdx].InboundLen, Integer(len));
    Exit(0);
  end;

  LOldLen := Length(LClient.FStreams[LIdx].Response.Body);
  SetLength(LClient.FStreams[LIdx].Response.Body, LOldLen + Integer(len));
  Move(data^, LClient.FStreams[LIdx].Response.Body[LOldLen], len);
  Result := 0;
end;

function OnStreamCloseCb(
  session: Pnghttp2_session;
  stream_id: Int32;
  error_code: UInt32;
  user_data: Pointer): Integer; cdecl;
var
  LClient: TNghttp2Client;
  LIdx:    Integer;
begin
  LClient := TNghttp2Client(user_data);
  if LClient = nil then Exit(0);
  LIdx := LClient.FindSlot(stream_id);   { MULTISTREAM-1 }
  if LIdx < 0 then Exit(0);

  LClient.FStreams[LIdx].Done := True;
  if error_code <> NGHTTP2_NO_ERROR then
    LClient.FStreams[LIdx].Error := Format(
      'stream %d closed with nghttp2 error code %d - received status=%d, %d header(s), %d body byte(s) before close',
      [stream_id, error_code,
       LClient.FStreams[LIdx].Response.Status,
       Length(LClient.FStreams[LIdx].Response.Headers),
       Length(LClient.FStreams[LIdx].Response.Body)]);
  Result := 0;
end;

// ─── Request body data provider (POST/PUT/PATCH support) ─────────────────
// Called by nghttp2 to pull request body bytes as it emits DATA frames.
// Reads from the stream's own ReqBody at ReqBodyPos; sets EOF when
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
  LIdx:       Integer;
begin
  LClient := TNghttp2Client(user_data);
  if LClient = nil then Exit(0);
  LIdx := LClient.FindSlot(stream_id);   { MULTISTREAM-1 — per-stream cursor }
  if LIdx < 0 then
  begin
    data_flags^ := NGHTTP2_DATA_FLAG_EOF;
    Exit(0);
  end;

  LRemaining := System.Length(LClient.FStreams[LIdx].ReqBody)
                - LClient.FStreams[LIdx].ReqBodyPos;
  if LRemaining <= 0 then
  begin
    data_flags^ := NGHTTP2_DATA_FLAG_EOF;
    Exit(0);
  end;

  if LRemaining < NativeInt(length) then
    LToRead := LRemaining
  else
    LToRead := NativeInt(length);

  Move(LClient.FStreams[LIdx].ReqBody[LClient.FStreams[LIdx].ReqBodyPos],
       buf^, LToRead);
  Inc(LClient.FStreams[LIdx].ReqBodyPos, LToRead);

  if LClient.FStreams[LIdx].ReqBodyPos
     >= System.Length(LClient.FStreams[LIdx].ReqBody) then
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
      'libnghttp2 could not be loaded - %s.  Install the nghttp2 runtime ' +
      'library and (Windows) ensure nghttp2.dll is on PATH or next to the .exe.',
      [NghttpLoadError]);

  InitSockets;   // no-op on non-Windows
  SetLength(FRecvBuffer, DEFAULT_RECV_BUFFER_SIZE);
  FSocket := INVALID_SOCKET_HANDLE;
  FSession        := nil;
  FCallbacks      := nil;
  FConnected      := False;
  SetLength(FStreams, 0);   { MULTISTREAM-1 }
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
    raise ENghttp2Client.Create('already connected - call Disconnect first');

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
      { [CL2b] Offer 'h2' ourselves rather than trusting the caller to have
        called EnableHttp2Alpn. This client has no HTTP/1.1 fallback, so there
        is no configuration in which NOT offering h2 is useful - making it
        opt-in only created a way to reach the confusing failure below.

        WHEN this applies is deliberate, and it is here rather than in the
        TlsContext setter. The ALPN list is (re)applied at CONNECT time, on
        every Connect, so the behaviour does not depend on the order in which
        the caller assigns TlsContext and configures it. A setter-side call
        would be order-sensitive in exactly the way that is hard to see: it
        would fire once, against whatever state the context happened to be in
        at assignment, and a later Disconnect/Connect pair would not revisit
        it. Applying it here means there is a single moment when the list has
        to be right, and it always is.

        Calling it twice is harmless: SSL_CTX_set_alpn_protos REPLACES the
        stored list rather than appending, and all four existing call sites
        set the same three bytes. Note this does mutate the caller-owned
        context - acceptable because the only value it can write is the one an
        h2-only client requires. }
      FTlsContext.EnableHttp2Alpn;

      FTlsConn := TTlsClientConnection.Create(FTlsContext, FSocket);
      FTlsConn.DoHandshake;

      { Two different failures, deliberately worded apart.

        EMPTY is reached when the peer has ALPN DISABLED: it echoes no ALPN
        extension, the handshake COMPLETES, and NegotiatedProtocol is ''.
        Measured against `openssl s_server` with no -alpn flag - handshake ok,
        "No ALPN negotiated". The old message rendered that as
        'server selected ""', which reads like the server returned garbage when
        the real meaning is "this endpoint does not do HTTP/2 over TLS".

        What does NOT reach here, contrary to an earlier draft of this very
        comment: a peer that offers only http/1.1. With no overlap OpenSSL does
        not complete the handshake and select nothing - it sends a FATAL
        no_application_protocol alert (alert 120, RFC 7301 §3.2). DoHandshake
        above raises first and neither branch below runs. Confirmed by running
        both peers: `-alpn http/1.1` gives s_client exit 1 and alert 120, while
        no -alpn gives exit 0 and an empty protocol. The earlier claim came
        from reading s_client's "No ALPN negotiated" line, which it prints on
        the way out of a FAILED handshake too - that line is not evidence of
        success.

        NON-EMPTY AND NOT h2 means the peer chose something we never offered,
        which RFC 7301 §3.2 forbids. Unreachable against a conformant peer, and
        kept precisely because "unreachable" is a claim about other people's
        servers. }
      if FTlsConn.NegotiatedProtocol = '' then
        raise ENghttp2Client.CreateFmt(
          'ALPN: %s:%d negotiated no protocol. This client offers "h2" only ' +
          'and has no HTTP/1.1 fallback, so a peer that selects nothing is ' +
          'either HTTP/1.1-only or has ALPN disabled. Use an HTTP/2 server, ' +
          'or h2c (no TlsContext) if the endpoint is cleartext HTTP/2.',
          [FHost, FPort])
      else if FTlsConn.NegotiatedProtocol <> 'h2' then
        raise ENghttp2Client.CreateFmt(
          'ALPN negotiation failed - server selected "%s" (expected "h2"). ' +
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

{ [CL2c] Reads with a deadline.

  The bug this closes: PumpUntilDone has always documented a timeout and always
  checked it — but only BETWEEN reads. DoRead went straight to a blocking recv
  with no SO_RCVTIMEO set anywhere, so a peer that accepted the connection and
  then said nothing parked the client forever and the elapsed check never ran
  again. The timeout was real in the source and inert at runtime.

  The plain path gates on readability here; the TLS path pushes the same
  deadline into TTlsClientConnection, whose FeedIn gates before its own recv.
  See the KNOWN LIMIT note in FeedIn: select cannot wait on an fd >= 1024 and
  reports it ready instead, so this is dependable for ordinary client use and
  not a guarantee under heavy descriptor pressure. }
function TNghttp2Client.DoRead(ABuf: Pointer; ALen: Integer;
  ATimeoutMS: Integer; out ATimedOut: Boolean): Integer;
var
  LReady: Integer;
begin
  ATimedOut := False;

  if FTlsConn <> nil then
  begin
    FTlsConn.ReadTimeoutMS := ATimeoutMS;
    Result := FTlsConn.Read(ABuf, ALen);
    if Result = TLS_READ_TIMED_OUT then
    begin
      ATimedOut := True;
      Result    := 0;
    end;
    Exit;
  end;

  if ATimeoutMS > 0 then
  begin
    LReady := SocketWaitReadable(FSocket, ATimeoutMS);
    if LReady = 0 then
    begin
      ATimedOut := True;
      Exit(0);
    end;
    { EINTR is a signal, not a dead socket — come round again rather than
      reporting a failure the connection has not suffered. }
    if LReady < 0 then
    begin
      if SocketLastErrorIsWouldBlock then
      begin
        ATimedOut := True;
        Exit(0);
      end;
      Exit(-1);
    end;
  end;

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
  LRemainingMS: Int64;      { [CL2c] }
  LTimedOut: Boolean;       { [CL2c] }
begin
  LStart := Now;
  { MULTISTREAM-1 — run until every open stream has closed, not just one. }
  while AnyPending do
  begin
    { [CL2c] >= rather than >. With the read now bounded by what remains of the
      budget, an elapsed time of EXACTLY ATimeoutMS left zero to wait on, and
      the old strict > sent us round the loop to spin until the clock ticked
      past. Harmless on Linux; Now has ~15 ms granularity on Windows. }
    if MilliSecondsSince(LStart) >= ATimeoutMS then
      raise ENghttp2Client.CreateFmt(
        'request timed out after %d ms - %d stream(s) still open',
        [ATimeoutMS, PendingStreams]);

    FlushSession;

    if nghttp2_session_want_read(FSession) = 0 then
      Break;

    { [CL2c] Hand the read what is LEFT of the budget, so a silent peer expires
      the deadline instead of parking in recv. On expiry we loop rather than
      raise here: the check at the top of the loop owns the timeout message and
      already names how many streams were still open. }
    LRemainingMS := ATimeoutMS - MilliSecondsSince(LStart);
    if LRemainingMS <= 0 then
      Continue;

    { MilliSecondsSince returns Int64 and ATimeoutMS is an Integer, so the
      subtraction is Int64. Narrow explicitly rather than letting the call site
      do it implicitly: the value is bounded above by ATimeoutMS and below by 1
      on this line, so the cast cannot lose anything — but an implicit
      conversion here is a warning on Delphi and a range-check failure with
      $R+, neither of which this container can catch. }
    LRecvLen := DoRead(@FRecvBuffer[0], Length(FRecvBuffer),
                       Integer(LRemainingMS), LTimedOut);
    if LTimedOut then
      Continue;
    if LRecvLen <= 0 then
      raise ENghttp2Client.Create('peer closed connection before stream end');

    LConsumed := nghttp2_session_mem_recv(FSession, @FRecvBuffer[0], LRecvLen);
    if LConsumed < 0 then
      raise ENghttp2Client.CreateFmt('nghttp2_session_mem_recv: %d', [LConsumed]);
  end;

  FlushSession;   // final flush of anything callbacks queued

  { Per-stream errors are NOT raised here. With several streams in flight, one
    failure must not discard the others' responses — TakeResponse raises for the
    stream it is asked about, so SubmitRequest still throws exactly as before. }
end;

function TNghttp2Client.BeginRequest(
  const AMethod:  string;
  const APath:    string;
  const AHeaders: TNghttp2Headers;
  const ABody:    TBytes;
  AStreamResponse: Boolean): Int32;
var
  LNvs:         array of Tnghttp2_nv;
  LNames:       array of AnsiString;    // hold refs so PAnsiChar stays valid
  LValues:      array of AnsiString;
  I, LBase:     Integer;
  LAuthority:   string;
  LStreamId:    Int32;
  LIdx:         Integer;
  LProvider:    Tnghttp2_data_provider;
  LProviderPtr: Pnghttp2_data_provider;
begin
  if not FConnected then
    raise ENghttp2Client.Create('not connected - call Connect first');

  { The slot is allocated AFTER submit, once nghttp2 has assigned the id — but
    the body cursor must exist before the first FlushSession, because the read
    callback can fire during it. AllocSlot below therefore runs immediately
    after nghttp2_submit_request and before any pumping. }

  LAuthority := FHost + ':' + IntToStr(FPort);
  LBase := 4;   // 4 pseudo-headers
  SetLength(LNvs,    LBase + Length(AHeaders));
  SetLength(LNames,  LBase + Length(AHeaders));
  SetLength(LValues, LBase + Length(AHeaders));

  LNames[0] := ':method';    LValues[0] := AnsiString(UpperCase(AMethod));
  LNames[1] := ':path';      LValues[1] := AnsiString(APath);

  { [CL2] :scheme names the scheme of the TARGET URI (RFC 7540 §8.1.2.3), so a
    request travelling over TLS must say https. This used to be hardcoded to
    'http', which meant every TLS request advertised the wrong scheme - legal
    to parse, but gRPC peers and proxies are entitled to reject the mismatch,
    and anything keying a virtual host off it sees the wrong value.

    FTlsConn is the honest signal, not FTlsContext: it becomes non-nil only
    after DoHandshake succeeded AND ALPN selected h2, it is what DoRead and
    DoSendAll route bytes through, and it is nilled during teardown before the
    socket closes. FTlsContext merely records what the caller assigned, so it
    would still claim https after a handshake that never ran. }
  LNames[2] := ':scheme';
  if FTlsConn <> nil then
    LValues[2] := 'https'
  else
    LValues[2] := 'http';

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

  LIdx := AllocSlot(LStreamId);
  FStreams[LIdx].ReqBody    := ABody;
  FStreams[LIdx].ReqBodyPos := 0;
  FStreams[LIdx].Streaming  := AStreamResponse;   { [CL3] }

  Result := LStreamId;
end;

{ ─── MULTISTREAM-1 slot bookkeeping ─────────────────────────────────────── }

function TNghttp2Client.FindSlot(AStreamId: Int32): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FStreams) do
    if FStreams[I].InUse and (FStreams[I].Id = AStreamId) then
      Exit(I);
  Result := -1;
end;

{ Reuses a freed slot before growing, so a long-lived client running thousands
  of sequential requests does not grow this array without bound. }
function TNghttp2Client.AllocSlot(AStreamId: Int32): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FStreams) do
    if not FStreams[I].InUse then
    begin
      FStreams[I] := Default(TNghttp2StreamSlot);
      FStreams[I].Id    := AStreamId;
      FStreams[I].InUse := True;
      Exit(I);
    end;
  SetLength(FStreams, Length(FStreams) + 1);
  Result := High(FStreams);
  FStreams[Result] := Default(TNghttp2StreamSlot);
  FStreams[Result].Id    := AStreamId;
  FStreams[Result].InUse := True;
end;

function TNghttp2Client.AnyPending: Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FStreams) do
    if FStreams[I].InUse and (not FStreams[I].Done) then
      Exit(True);
  Result := False;
end;

function TNghttp2Client.PendingStreams: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FStreams) do
    if FStreams[I].InUse and (not FStreams[I].Done) then
      Inc(Result);
end;

procedure TNghttp2Client.PumpAll(ATimeoutMS: Integer);
begin
  PumpUntilDone(ATimeoutMS);
end;

{ [CL3] One pass of PumpUntilDone's loop body. See the declaration for the
  three return values. Kept beside it deliberately: if that loop changes, this
  must change with it, and two pumps that drift apart would be a defect nothing
  here would catch. }
function TNghttp2Client.PumpOnce(ATimeoutMS: Integer): Integer;
var
  LRecvLen:  Integer;
  LConsumed: NativeInt;
  LTimedOut: Boolean;
begin
  FlushSession;

  { Nothing further will arrive — the caller must treat this as end of data
    rather than looping, or it spins until its deadline. }
  if nghttp2_session_want_read(FSession) = 0 then
    Exit(-1);

  LRecvLen := DoRead(@FRecvBuffer[0], Length(FRecvBuffer), ATimeoutMS, LTimedOut);
  if LTimedOut then
    Exit(0);
  if LRecvLen <= 0 then
    raise ENghttp2Client.Create('peer closed connection before stream end');

  LConsumed := nghttp2_session_mem_recv(FSession, @FRecvBuffer[0], LRecvLen);
  if LConsumed < 0 then
    raise ENghttp2Client.CreateFmt('nghttp2_session_mem_recv: %d', [LConsumed]);

  { Callbacks fired during mem_recv may have queued WINDOW_UPDATE frames; get
    them onto the wire now or the peer stalls waiting for window. }
  FlushSession;
  Result := 1;
end;

function TNghttp2Client.ReadChunk(AStreamId: Int32; var ABuffer: TBytes;
  ACount: Integer; ATimeoutMS: Integer): Integer;
var
  LIdx:       Integer;
  LStart:     TDateTime;
  LRemaining: Int64;
  LTook:      Integer;
  LPumped:    Integer;
begin
  LIdx := FindSlot(AStreamId);
  if LIdx < 0 then
    raise ENghttp2Client.CreateFmt('no such stream: %d', [AStreamId]);
  if not FStreams[LIdx].Streaming then
    raise ENghttp2Client.CreateFmt(
      'stream %d was not opened for streaming - pass AStreamResponse=True to '
      + 'BeginRequest, or use PumpAll/TakeResponse for a buffered response',
      [AStreamId]);
  if ACount <= 0 then
    raise ENghttp2Client.CreateFmt('ACount must be positive, got %d', [ACount]);

  LStart := Now;
  repeat
    { Buffered bytes first: return what has arrived rather than waiting for a
      full ACount. A reader that blocks for a full buffer on a live stream is
      the classic way to turn incremental delivery back into batch delivery. }
    if FStreams[LIdx].InboundLen > 0 then
    begin
      LTook := FStreams[LIdx].InboundLen;
      if LTook > ACount then
        LTook := ACount;
      SetLength(ABuffer, LTook);
      Move(FStreams[LIdx].Inbound[0], ABuffer[0], LTook);
      if LTook < FStreams[LIdx].InboundLen then
        Move(FStreams[LIdx].Inbound[LTook], FStreams[LIdx].Inbound[0],
             FStreams[LIdx].InboundLen - LTook);
      Dec(FStreams[LIdx].InboundLen, LTook);
      Exit(LTook);
    end;

    { Buffer empty AND the stream closed: that is end of data, not a timeout.
      Checked after the buffer, because END_STREAM can land in the same pass as
      the final bytes and those bytes must be delivered first. }
    if FStreams[LIdx].Done then
    begin
      SetLength(ABuffer, 0);
      Exit(0);
    end;

    LRemaining := ATimeoutMS - MilliSecondsSince(LStart);
    if LRemaining <= 0 then
    begin
      SetLength(ABuffer, 0);
      Exit(-1);
    end;

    LPumped := PumpOnce(Integer(LRemaining));
    if LPumped < 0 then
    begin
      { The session will not read again, so no further DATA can arrive. Report
        end of stream rather than spinning to the deadline and calling it a
        timeout — a timeout would tell the caller to retry forever. }
      SetLength(ABuffer, 0);
      Exit(0);
    end;
  until False;
end;

{ Frees the slot as it hands the response back, so the caller cannot read a
  stale response twice and a long run does not accumulate slots. }
function TNghttp2Client.TakeResponse(AStreamId: Int32): TNghttp2Response;
var
  LIdx: Integer;
  LErr: string;
begin
  LIdx := FindSlot(AStreamId);
  if LIdx < 0 then
    raise ENghttp2Client.CreateFmt('no such stream: %d', [AStreamId]);
  if not FStreams[LIdx].Done then
    raise ENghttp2Client.CreateFmt(
      'stream %d has not completed - call PumpAll first', [AStreamId]);

  { [CL3] Refuse to discard bytes the caller has not read. On a streaming
    stream Response.Body is empty BY DESIGN — the body went to ReadChunk — and
    handing that back silently would look exactly like a server that sent no
    body at all. Drain to end-of-stream first, then take the status/headers. }
  if FStreams[LIdx].Streaming and (FStreams[LIdx].InboundLen > 0) then
    raise ENghttp2Client.CreateFmt(
      'stream %d is a streaming response with %d byte(s) still unread - drain '
      + 'it with ReadChunk until it returns 0 before taking the response '
      + '(Body is empty on a streaming stream; status and headers are not)',
      [AStreamId, FStreams[LIdx].InboundLen]);

  Result := FStreams[LIdx].Response;
  LErr   := FStreams[LIdx].Error;
  FStreams[LIdx].InUse := False;
  FStreams[LIdx] := Default(TNghttp2StreamSlot);

  if LErr <> '' then
    raise ENghttp2Client.Create(LErr);
end;

{ The original one-shot API, now expressed in the three-call form. Behaviour is
  unchanged: submit one stream, pump to completion, return or raise. }
function TNghttp2Client.SubmitRequest(
  const AMethod:  string;
  const APath:    string;
  const AHeaders: TNghttp2Headers;
  const ABody:    TBytes;
  ATimeoutMS: Integer): TNghttp2Response;
var
  LStreamId: Int32;
begin
  LStreamId := BeginRequest(AMethod, APath, AHeaders, ABody);
  PumpAll(ATimeoutMS);
  Result := TakeResponse(LStreamId);
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
  // [CL1] The host may be a name on Delphi; on FPC it must still be an IPv4
  // literal (see ConnectToHost). Default ports: 80 / 443.
  LSchemePos := Pos('://', AURL);
  if LSchemePos = 0 then
    raise ENghttp2Client.CreateFmt(
      'malformed URL "%s" - expected http://host[:port]/path or https://...', [AURL]);

  LScheme  := LowerCase(Copy(AURL, 1, LSchemePos - 1));
  LIsHttps := LScheme = 'https';
  if (LScheme <> 'http') and (LScheme <> 'https') then
    raise ENghttp2Client.CreateFmt(
      'unsupported URL scheme "%s" - only http and https are supported', [LScheme]);

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
