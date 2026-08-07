unit Nghttp2.Server;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Nghttp2.Server
//  TCP accept loop + per-connection worker threads. Cleartext HTTP/2 (h2c)
//  via prior knowledge in v1 — clients send the HTTP/2 preface directly.
//  TLS + ALPN negotiation deferred to a later increment.
//
//  Threading model: one dedicated accept thread; one worker thread per
//  accepted connection. Streams multiplex synchronously within each worker.
//  For per-stream parallelism the caller offloads inside their route handler
//  (WorkerPool from Task 5).
//
//  Graceful shutdown protocol (used by the provider entry point's
//  StopListenGraceful — framework contract from horse/.agents/AGENTS.md):
//    1) StopAcceptingNewConnections    — closes listener; accept loop exits
//    2) caller waits ActiveRequests → 0 within its timeout
//    3) ForceCloseAllConnections       — hard-close every live conn socket
//    4) Stop                            — join both accept + connection threads
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, SyncObjs, Generics.Collections,
{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections,
{$IFEND}
  Nghttp2.Types,
  Nghttp2.Session,
  Nghttp2.Socket,
  Nghttp2.Tls;

type
  THorseNghttp2Config = record
    Port:                 Word;
    ListenBacklog:        Integer;
    RecvBufferSize:       Integer;
    MaxConcurrentStreams: Integer;
    // TLS + ALPN fields intentionally omitted in v1 — h2c only.
    class function Default: THorseNghttp2Config; static;
  end;

  TNghttp2OnRequestProc = Nghttp2.Session.TNghttp2OnRequestProc;

  TNghttp2Server = class;

  // ─── Per-connection worker thread ─────────────────────────────────────
  TNghttp2ConnectionThread = class(TThread)
  private
    FServer:   TNghttp2Server;
    FSock:     TSocketHandle;
    FPeerAddr: string;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TNghttp2Server; ASock: TSocketHandle;
      const APeerAddr: string);
    property Sock: TSocketHandle read FSock;
  end;

  // ─── Accept-loop thread ───────────────────────────────────────────────
  TNghttp2AcceptThread = class(TThread)
  private
    FServer: TNghttp2Server;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TNghttp2Server);
  end;

  // ─── Server ───────────────────────────────────────────────────────────
  TNghttp2Server = class
  private
    FConfig:         THorseNghttp2Config;
    FOnRequest:      TNghttp2OnRequestProc;
    FListener:       TSocketHandle;
    FAcceptThread:   TNghttp2AcceptThread;
    FConnections:    TList<TNghttp2ConnectionThread>;
    FConnLock:       TCriticalSection;
    FStopping:       Integer;   // 0 / 1 via TInterlocked
    FActiveRequests: Integer;   // TInterlocked-managed request-in-flight counter
    // Optional TLS context. Non-owning reference — caller allocates the
    // TTlsServerContext (loads cert+key+ALPN) before calling Start, and
    // Frees it after Stop. When nil, connections run in cleartext (h2c).
    FTlsContext:     TTlsServerContext;
  protected
    function  IsStopping: Boolean;
    procedure RegisterConnection(AConn: TNghttp2ConnectionThread);
    procedure UnregisterConnection(AConn: TNghttp2ConnectionThread);
  public
    // SEC-30 counter surface — called by the provider entry point's
    // ExecutePipeline (Inc on request entry, Dec in finally). Public because
    // THorseProviderNghttp2 lives in a different unit.
    procedure IncActiveRequests;
    procedure DecActiveRequests;

    constructor Create;
    destructor  Destroy; override;

    // Bind, listen, spawn the accept thread. Returns immediately.
    procedure Start(const AConfig: THorseNghttp2Config);
    // Close listener; accept loop exits; live connections keep running.
    procedure StopAcceptingNewConnections;
    // Hard-close every live connection socket.
    procedure ForceCloseAllConnections;
    // Full stop — StopAcceptingNewConnections + ForceCloseAllConnections +
    // wait for every thread to terminate.
    procedure Stop;

    property OnRequest:      TNghttp2OnRequestProc read FOnRequest write FOnRequest;
    property ActiveRequests: Integer               read FActiveRequests;
    property Port:           Word                  read FConfig.Port;
    // Optional TLS. Caller allocates + configures the context (LoadCert /
    // LoadPrivateKey / EnableHttp2Alpn) and assigns before Start. Set to nil
    // for cleartext h2c. Non-owning — caller must Free the context after Stop.
    property TlsContext:     TTlsServerContext     read FTlsContext write FTlsContext;
  end;

implementation

// ─── THorseNghttp2Config ─────────────────────────────────────────────────

class function THorseNghttp2Config.Default: THorseNghttp2Config;
begin
  Result.Port                 := 9200;
  Result.ListenBacklog        := 128;
  Result.RecvBufferSize       := 16 * 1024;
  Result.MaxConcurrentStreams := 100;
end;

// ─── TNghttp2ConnectionThread ────────────────────────────────────────────

constructor TNghttp2ConnectionThread.Create(AServer: TNghttp2Server;
  ASock: TSocketHandle; const APeerAddr: string);
begin
  inherited Create(True);   // create suspended
  FreeOnTerminate := False; // Server tracks + joins us
  FServer         := AServer;
  FSock           := ASock;
  FPeerAddr       := APeerAddr;
end;

procedure TNghttp2ConnectionThread.Execute;
var
  LConn:      INghttp2Connection;
  LSession:   TNghttp2Session;
  LRecvBuf:   TBytes;
  LRecvLen:   Integer;
  LSendPtr:   PByte;
  LSendLen:   NativeInt;
  LFeedRc:    NativeInt;
  LTls:       TTlsConnection;   // nil = plain h2c path

  // Nested I/O helpers — read from and write to either plain socket or the
  // TLS-wrapped fd, without duplicating the pump loop. Both capture LTls
  // and FSock from the enclosing scope.
  function DoRead(ABuf: Pointer; ALen: Integer): Integer;
  begin
    if LTls <> nil then
      Result := LTls.Read(ABuf, ALen)
    else
      Result := SocketRecv(FSock, ABuf, ALen);
  end;

  function DoSendAll(ABuf: Pointer; ALen: Integer): Boolean;
  var
    LWritten: Integer;
  begin
    if LTls <> nil then
    begin
      LWritten := LTls.Write(ABuf, ALen);
      // SSL_write's partial-write semantics differ across OpenSSL versions,
      // but in blocking mode (our default) it returns ALen on success or
      // <=0 on error. Treat any short write as failure.
      Result := LWritten = ALen;
    end
    else
      Result := SocketSendAll(FSock, ABuf, ALen);
  end;

begin
  FServer.RegisterConnection(Self);
  SetLength(LRecvBuf, 16 * 1024);   // matches Config.RecvBufferSize default
  LTls := nil;

  LConn    := TNghttp2ConnectionState.Create(FPeerAddr, FServer.Port);
  LSession := TNghttp2Session.Create(LConn);
  try
    // ── TLS handshake (if enabled) ─────────────────────────────────────────
    // Runs BEFORE any nghttp2 traffic. On failure, close the connection —
    // don't try to fall back to h2c because that would leak the fact that
    // TLS validation failed vs succeeded.
    if FServer.TlsContext <> nil then
    begin
      try
        LTls := TTlsConnection.Create(FServer.TlsContext, FSock);
        LTls.DoHandshake;
        // ALPN must have selected 'h2'. If the client didn't offer h2, our
        // callback returned NOACK and OpenSSL either omitted ALPN or the
        // handshake failed. Either way, reject at this point.
        if LTls.NegotiatedProtocol <> 'h2' then
          Exit;
      except
        // Swallow handshake errors — they're per-connection noise (malformed
        // TLS, wrong ALPN, cert issues). Just tear down and move on.
        Exit;
      end;
    end;

    // Wire the plain-proc callback directly — the SEC-30 active-request
    // counter is bumped inside THorseProviderNghttp2.ExecutePipeline
    // (via FServer.IncActiveRequests/DecActiveRequests), keeping the
    // counter increment at the true per-request boundary and avoiding a
    // method-pointer vs plain-procedure type mismatch here.
    LSession.OnRequest := FServer.OnRequest;

    // Flush initial SETTINGS frame before entering the pump.
    while LSession.WantWrite do
    begin
      LSendLen := LSession.ExtractOutgoing(LSendPtr);
      if LSendLen <= 0 then Break;
      if not DoSendAll(LSendPtr, LSendLen) then Exit;
    end;

    // Main pump.
    while (not Terminated) and (not FServer.IsStopping)
      and (LSession.WantRead or LSession.WantWrite) do
    begin
      // ─── Read side ─────────────────────────────────────────────────────
      if LSession.WantRead then
      begin
        LRecvLen := DoRead(@LRecvBuf[0], Length(LRecvBuf));
        if LRecvLen <= 0 then Break;   // peer close or recv error
        LFeedRc := LSession.FeedIncoming(@LRecvBuf[0], LRecvLen);
        if LFeedRc < 0 then Break;     // nghttp2 protocol error
      end;

      // ─── Write side ────────────────────────────────────────────────────
      while LSession.WantWrite do
      begin
        LSendLen := LSession.ExtractOutgoing(LSendPtr);
        if LSendLen <= 0 then Break;
        if not DoSendAll(LSendPtr, LSendLen) then Exit;
      end;
    end;
  finally
    LSession.Free;
    if LTls <> nil then
    begin
      LTls.Shutdown;   // best-effort SSL_shutdown before socket close
      LTls.Free;       // SSL_free — doesn't close the fd
    end;
    ShutdownSocketHandle(FSock);
    FSock := INVALID_SOCKET_HANDLE;
    FServer.UnregisterConnection(Self);
  end;
end;

// ─── TNghttp2AcceptThread ────────────────────────────────────────────────

constructor TNghttp2AcceptThread.Create(AServer: TNghttp2Server);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FServer         := AServer;
end;

procedure TNghttp2AcceptThread.Execute;
var
  LSock:     TSocketHandle;
  LPeerAddr: string;
  LWorker:   TNghttp2ConnectionThread;
begin
  while (not Terminated) and (not FServer.IsStopping) do
  begin
    LSock := AcceptConnection(FServer.FListener, LPeerAddr);
    if LSock = INVALID_SOCKET_HANDLE then
    begin
      // Accept returned error — most commonly the listener was closed by
      // StopAcceptingNewConnections. Exit if we're stopping; otherwise loop
      // (spurious errors under load).
      if FServer.IsStopping then Break;
      Continue;
    end;

    LWorker := TNghttp2ConnectionThread.Create(FServer, LSock, LPeerAddr);
    LWorker.Start;
  end;
end;

// ─── TNghttp2Server ──────────────────────────────────────────────────────

constructor TNghttp2Server.Create;
begin
  inherited Create;
  FListener     := INVALID_SOCKET_HANDLE;
  FConnections  := TList<TNghttp2ConnectionThread>.Create;
  FConnLock     := TCriticalSection.Create;
  FStopping     := 0;
  FActiveRequests := 0;
end;

destructor TNghttp2Server.Destroy;
begin
  Stop;
  FConnections.Free;
  FConnLock.Free;
  inherited;
end;

function TNghttp2Server.IsStopping: Boolean;
begin
  Result := TInterlocked.CompareExchange(FStopping, 0, 0) <> 0;
end;

procedure TNghttp2Server.RegisterConnection(AConn: TNghttp2ConnectionThread);
begin
  FConnLock.Enter;
  try
    FConnections.Add(AConn);
  finally
    FConnLock.Leave;
  end;
end;

procedure TNghttp2Server.UnregisterConnection(AConn: TNghttp2ConnectionThread);
begin
  FConnLock.Enter;
  try
    FConnections.Remove(AConn);
  finally
    FConnLock.Leave;
  end;
end;

procedure TNghttp2Server.IncActiveRequests;
begin
  TInterlocked.Increment(FActiveRequests);
end;

procedure TNghttp2Server.DecActiveRequests;
begin
  TInterlocked.Decrement(FActiveRequests);
end;

procedure TNghttp2Server.Start(const AConfig: THorseNghttp2Config);
begin
  if FListener <> INVALID_SOCKET_HANDLE then
    raise Exception.Create('TNghttp2Server: already listening');

  FConfig := AConfig;
  TInterlocked.Exchange(FStopping, 0);

  FListener     := CreateListenerSocket(FConfig.Port, FConfig.ListenBacklog);
  FAcceptThread := TNghttp2AcceptThread.Create(Self);
  FAcceptThread.Start;
end;

procedure TNghttp2Server.StopAcceptingNewConnections;
var
  LListener: TSocketHandle;
begin
  TInterlocked.Exchange(FStopping, 1);

  // Snapshot + null the field before closing — AcceptLoop reads it under no
  // lock; a NULL after close is safer than a use-after-close race.
  LListener := FListener;
  FListener := INVALID_SOCKET_HANDLE;
  if LListener <> INVALID_SOCKET_HANDLE then
    // FIX-DAEMON-SHUTDOWN-1 (2026-08-06) — must use ShutdownSocketHandle
    // (shutdown(SHUT_RDWR) + close) rather than plain CloseSocketHandle.
    // POSIX close() on a fd being read by another thread's blocked accept()
    // does NOT unblock that syscall on Linux (behavior is implementation-
    // defined per SUS; Linux waits until the accept()-owning thread exits).
    // shutdown() atomically forces accept() to return with an error, which
    // is what the accept loop tests for on line ~281.  Without this fix,
    // the accept thread stays parked in accept(), FAcceptThread.WaitFor
    // below blocks forever, the process never exits, and the socket stays
    // bound — reproducing the zombie-daemon behavior observed 2026-08-06
    // on Delphi Linux + PAServer 14.2 with kill -TERM/SIGINT.
    ShutdownSocketHandle(LListener);

  if Assigned(FAcceptThread) then
  begin
    FAcceptThread.WaitFor;
    FreeAndNil(FAcceptThread);
  end;
end;

procedure TNghttp2Server.ForceCloseAllConnections;
var
  LConn: TNghttp2ConnectionThread;
  I:     Integer;
begin
  FConnLock.Enter;
  try
    for I := 0 to FConnections.Count - 1 do
    begin
      LConn := FConnections[I];
      if LConn.Sock <> INVALID_SOCKET_HANDLE then
        ShutdownSocketHandle(LConn.Sock);
      // Note: don't null LConn.FSock here — the connection thread owns it
      // and will null after ShutdownSocketHandle returns in its finally.
    end;
  finally
    FConnLock.Leave;
  end;
end;

procedure TNghttp2Server.Stop;
var
  LSurvivors: array of TNghttp2ConnectionThread;
  I:          Integer;
begin
  StopAcceptingNewConnections;
  ForceCloseAllConnections;

  // Snapshot the list of active connection threads (they self-unregister as
  // they exit, so we can't safely iterate FConnections while joining).
  FConnLock.Enter;
  try
    SetLength(LSurvivors, FConnections.Count);
    for I := 0 to FConnections.Count - 1 do
      LSurvivors[I] := FConnections[I];
  finally
    FConnLock.Leave;
  end;

  for I := 0 to High(LSurvivors) do
  begin
    LSurvivors[I].WaitFor;
    LSurvivors[I].Free;
  end;
end;

end.
