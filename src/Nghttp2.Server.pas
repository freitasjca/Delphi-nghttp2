unit Nghttp2.Server;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Nghttp2.Server
//  TCP accept loop + per-connection worker threads. Cleartext HTTP/2 (h2c)
//  via prior knowledge in v1 — clients send the HTTP/2 preface directly.
//  TLS + ALPN negotiation deferred to a later increment.
//
//  Threading model: one dedicated accept thread; one connection thread per
//  accepted connection. Streams multiplex within that connection thread.
//
//  Whether they multiplex serially or in parallel is the host's choice, made
//  through TNghttp2Config.AsyncDispatch:
//
//    False (default) — OnRequest runs inline on the connection thread. One
//      request at a time per connection, so a slow route blocks every other
//      stream the client has open on that connection.
//
//    True — OnRequest hands off to the host's own pool and returns at once,
//      and the pump switches to a timed readability wait so it can flush the
//      responses those threads complete. See the Nghttp2.Session header for
//      why responses come back through a queue rather than being submitted
//      by the worker directly.
//
//  MaxConnections caps concurrency at the other end: a thread per connection
//  does not scale to five figures, so an explicit ceiling beats discovering
//  the limit as thread-creation failures.
//
//  Graceful shutdown protocol (used by the provider entry point's
//  StopListenGraceful — framework contract from horse/.agents/AGENTS.md):
//    1) StopAcceptingNewConnections — closes the listener and raises the
//       DRAINING flag. Existing connections keep pumping; each sends the
//       first GOAWAY (last_stream_id = 2^31-1, NO_ERROR) so the peer stops
//       opening new streams without any stream being cut off.
//    2) caller waits, within its timeout, for BOTH ActiveRequests → 0 and
//       AllConnectionsIdle. The request counter alone is not enough: a worker
//       retires it when its handler returns, which is before the response has
//       been submitted or written.
//    3) Stop — raises the STOPPING flag, then WAITS for the pumps to retire
//       themselves. Each sends the second GOAWAY naming the last stream it
//       actually processed, flushes it, and only then closes its socket.
//       Force-close is the fallback for whatever has not settled, never the
//       first move: a pump can only send its farewell while its socket is
//       open, so force-closing on the heels of the flag suppresses that frame
//       entirely and the peer sees one GOAWAY where there should be two.
//
//  The two GOAWAYs are RFC 9113 §6.8: the first is an open-ended warning, the
//  second the definitive cutoff. One frame alone cannot serve both roles — a
//  peer that opened a stream concurrently with the shutdown decision needs
//  the second to learn whether that stream was processed or must be replayed.
//
//  Draining and stopping are deliberately separate flags. While they were one,
//  beginning a drain tore down the pumps immediately, so responses whose
//  handlers had already completed could never reach the socket — the exact
//  outcome graceful shutdown exists to prevent.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, SyncObjs, Generics.Collections,
{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections,
{$IFEND}
  Nghttp2.Compat,   { TInterlocked shim for FPC < 3.3.1 — no-op elsewhere }
  Nghttp2.Types,
  Nghttp2.Session,
  Nghttp2.Socket,
  Nghttp2.Native,   { NghttpLoad — see Start }
  Nghttp2.Tls;

type
  TNghttp2Config = record
    Port:                 Word;
    ListenBacklog:        Integer;
    RecvBufferSize:       Integer;
    // Advertised to clients in the initial SETTINGS frame; they self-limit
    // to this many concurrent streams per connection.
    MaxConcurrentStreams: Integer;
    // Hard cap on simultaneously accepted connections; 0 = unlimited.
    // Past the cap new sockets are closed immediately rather than queued,
    // since every connection costs a thread in this model.
    MaxConnections:       Integer;
    // Set by a host that answers OnRequest from a worker pool. Switches the
    // per-connection session to deferred response submission — see the
    // Nghttp2.Session unit header. Leave False for inline dispatch.
    // This is the transport-level switch: any host with its own threading can
    // set it, independently of WorkerThreads below.
    AsyncDispatch:        Boolean;
    // Size of the dispatch pool the host should build; 0 = none, run OnRequest
    // inline. Read by the Horse provider, which sets AsyncDispatch to match.
    WorkerThreads:        Integer;
    // How long the pump blocks waiting for client bytes before looping to
    // flush responses that workers finished meanwhile. Only consulted in
    // async mode; ignored when AsyncDispatch is False.
    PollIntervalMS:       Integer;
    { Drive connections from an epoll event loop instead of one thread each.
      Linux only, h2c only, opt-in — see Nghttp2.Engine.Epoll. Ignored when
      that unit is not linked, or on any other platform, in which case the
      thread-per-connection driver runs exactly as before. }
    UseEventLoop:         Boolean;
    { Event-loop threads, when UseEventLoop is on. 0 = one per core.

      Measured 2026-08-17: with a single loop the thread sat at ~106% CPU at
      BOTH c=100 and c=5000 while 27 cores idled, capping the engine at
      41.8k/27.7k req/s. One loop is one core, whatever the connection count.
      Each loop binds its own SO_REUSEPORT listener, so the kernel spreads
      accepts and no handoff is needed. }
    EngineThreads:        Integer;
    // TLS + ALPN fields intentionally omitted in v1 — h2c only.
    class function Default: TNghttp2Config; static;
  end;

  { Pre-1.6.0 name. The Horse prefix was a leftover from where this record was
    written; nothing here has ever depended on Horse. An ALIAS, so a variable
    declared with either name is the same record type and assigns freely to the
    other. REMOVED IN 2.0.0. }
  THorseNghttp2Config = TNghttp2Config
    deprecated 'Renamed in 1.6.0 to TNghttp2Config. Removed in 2.0.0.';

  TNghttp2OnRequestProc = Nghttp2.Session.TNghttp2OnRequestProc;

  TNghttp2Server = class;

  { ── Alternative connection driver ────────────────────────────────────
    Implemented by Nghttp2.Engine.Epoll. Declared here, rather than the
    server referencing that unit, because the engine must reference the
    server (it drives TNghttp2ConnectionPump) — a direct dependency both
    ways would be circular. The engine registers itself through
    Nghttp2EngineFactory below in its own initialization, so linking the
    unit is what enables it and nothing here names it. }
  INghttp2Engine = interface
    ['{6E1C4B2A-9F3D-4C87-A1B5-2D7E8F0A3C64}']
    procedure Start;
    procedure Stop;
    // Take ownership of a freshly accepted socket. Called from the accept
    // thread; the engine defers the work to its own thread, because a pump
    // may only ever be touched by the thread that drives it.
    procedure HandOff(ASock: TSocketHandle; const APeerAddr: string);
    procedure CloseAll;
    function  LiveConnections: Integer;
    function  AllIdle: Boolean;

    { True when the engine binds its own listeners (SO_REUSEPORT, one per loop
      thread) and therefore does its own accepting. The server then creates no
      listener and starts no accept thread — there is nothing to hand off,
      because each loop accepts on the thread that will serve the connection.

      False keeps the original arrangement: server listener, accept thread,
      HandOff to the engine. That is the fallback wherever SO_REUSEPORT is
      unavailable. }
    function  OwnsAccept: Boolean;

    // Close the engine's own listeners, leaving live connections running.
    // The engine-mode counterpart of closing the server's listener.
    procedure StopAccepting;

    { What this engine actually is, for banners, logs and test gates.

      Added 2026-08-18 after the IOCP engine shipped and every one of those
      reported "epoll event loop" ON WINDOWS. The label was a hardcoded string
      in the test server, and `UsingEventLoop` only answers "is SOME engine
      registered". Since the epoll unit compiles to nothing off Linux, the
      running engine was IOCP while every harness gate — all of which match on
      that literal text — passed happily.

      Those gates exist precisely to stop a driver being mislabelled, so
      hardcoding the name defeated them. An engine that names itself cannot. }
    function DriverName: string;
  end;

  { ── Result of one pump iteration ──────────────────────────────────────
    psStop and psAbort are NOT interchangeable, and collapsing them changes
    shutdown behaviour on a path no suite covers. In the original loop a
    `Break` (socket error, protocol error) fell through to the farewell
    GOAWAY, while an `Exit` (send failure) skipped it — because a connection
    whose send just failed has no working socket to announce anything on. }
  TNghttp2PumpStep = (
    psContinue,   // iterate again
    psStop,       // leave the loop, THEN send the farewell GOAWAY
    psAbort       // leave the loop and skip the farewell
  );

  { Outcome of one non-blocking write attempt. ioWouldBlock is a normal,
    expected result — the peer's window is full and the remainder is held —
    NOT a failure. Confusing the two is how an event loop drops the tail of a
    response under load. }
  TNghttp2IoResult = (ioOk, ioWouldBlock, ioError);

  { ── The connection state machine ──────────────────────────────────────
    Everything one HTTP/2 connection needs to make progress, with the loop
    that drives it left to the caller. TNghttp2ConnectionThread is one such
    caller — one thread, one connection — and an event-loop engine is the
    other, many connections per thread, calling RunOnce only on the ones its
    poller reported ready.

    The phase order inside RunOnce is load-bearing and took four wrong
    attempts to settle (see the plan's build history): notice → read → drain
    → farewell → write. It lives here, once, precisely so two drivers cannot
    drift apart on it — a divergence there would be invisible to a passing
    suite, which is how the first three attempts got as far as they did.

    Does NOT own the socket. The thread that accepted it closes it, and
    TNghttp2Server.ForceCloseAllConnections reaches it through that thread. }
  TNghttp2ConnectionPump = class
  private
    FServer:     TNghttp2Server;
    FSock:       TSocketHandle;
    FPeerAddr:   string;
    FConn:       INghttp2Connection;
    FSession:    TNghttp2Session;
    FTls:        TTlsConnection;   // nil = plain h2c path
    FRecvBuf:    TBytes;
    FAsync:      Boolean;
    FPollMS:     Integer;
    FPeerClosed: Boolean;

    { ── Non-blocking mode (event-loop driver only) ─────────────────────────
      In blocking mode none of this is touched and every path below behaves
      exactly as the thread driver has always seen it.

      FOutPending exists for the same reason TTlsConnection needed one: bytes
      extracted from nghttp2 cannot be pushed back, so a socket that accepts
      only part of a write leaves a remainder that has to live somewhere. }
    FNonBlocking: Boolean;
    FOutPending:  TBytes;
    FOutUsed:     Integer;   // bytes still to send, from index 0

    { Non-blocking TLS state. The handshake cannot complete inside Setup under
      an event loop — it would block the thread serving every other connection
      on that loop — so it is driven a step at a time from RunOnce instead. }
    FTlsHandshakeDone: Boolean;
    FSessionStarted:   Boolean;
    { Set from the STATE the last TLS call returned, never inferred from which
      call it was: WriteNB can return tisWantRead during a renegotiation and
      ReadNB can return tisWantWrite. Read interest is permanent, so only the
      want-write direction has to be expressed. }
    FTlsWantsWrite:    Boolean;

    // Read from and write to either the plain socket or the TLS-wrapped fd,
    // without duplicating the pump logic.
    function DoRead(ABuf: Pointer; ALen: Integer): Integer;
    function DoSendAll(ABuf: Pointer; ALen: Integer): Boolean;
    // Async mode only: bounded wait for anything worth waking up for.
    //   >0 readable · 0 nothing to read · <0 socket error
    function WaitReadable(ATimeoutMS: Integer): Integer;

    procedure SetNonBlocking(AValue: Boolean);
    procedure AppendOut(ABuf: Pointer; ALen: Integer);
    // Pushes FOutPending at the socket, keeping whatever it will not take.
    function  FlushPending: TNghttp2IoResult;
    // The write phase in non-blocking mode. Separate from the blocking one
    // rather than a branch inside it — the blocking loop is what every
    // shipped suite exercises and it stays untouched.
    function  WritePhaseNB: TNghttp2PumpStep;
    // Env-gated state dump — see PumpTrace.
    procedure Trace(const AWhere: string);
    { DRAIN-DIAG-4. Phase marker inside RunOnce, gated like every other drain
      diagnostic. Exists because a captured failing draw showed ONE RunOnce
      taking 2 953 ms in a loop whose every other iteration is 50 ms apart —
      41 iterations in the failing run against 43 in a passing one, so the
      extra ~3 s is dead time, not extra work. Every wait RunOnce can reach is
      bounded at FPollMS (50 ms) and the only Sleep on the path is
      GOAWAY_GRACE_MS (100 ms), so the blocking call is not obvious from
      reading it. This attributes the gap to a phase instead of guessing. }
    procedure PhaseMark(const AWhere: string);
    // OnRequest wiring + initial SETTINGS flush. Split out of Setup because
    // with non-blocking TLS it cannot run until the handshake completes.
    function  StartSession: Boolean;
  public
    constructor Create(AServer: TNghttp2Server; ASock: TSocketHandle;
      const APeerAddr: string);
    destructor Destroy; override;

    // TLS handshake, OnRequest wiring, initial SETTINGS flush.
    // False = abandon this connection (bad handshake, non-h2 ALPN, send fail).
    function Setup: Boolean;

    // The loop condition — everything except the driver's own stop flags.
    function ShouldContinue: Boolean;

    // One iteration of the pump.
    function RunOnce: TNghttp2PumpStep;

    // Post-loop fallback for a pump forced out without reaching a settled
    // state. Idempotent; a no-op unless a drain is in progress.
    procedure SendFarewell;

    { ── Event-loop driver surface ────────────────────────────────────────
      Setting this also puts the socket into the matching mode, so the flag
      and the descriptor cannot drift. Set it before Setup. }
    property NonBlocking: Boolean read FNonBlocking write SetNonBlocking;

    { Wake hook for an event-loop driver, forwarded to the session. Fires on
      a WORKER thread the instant a response is staged, so an implementation
      must be thread-safe and must not block.

      Without it an engine only notices staged replies when its poller next
      returns — the client is waiting and sending nothing, so no socket
      becomes readable and the reply waits out the whole loop timeout. }
    procedure SetWakeProc(const AProc: TNghttp2WakeProc);

    { Bytes readable WITHOUT the socket becoming readable again — decrypted
      plaintext sitting in SSL, plus ciphertext already pulled off the socket
      into FBioIn but not yet decrypted.

      An event loop cannot see either. epoll reports the SOCKET, and after a
      large record is drained off it the socket is empty while OpenSSL still
      holds most of the request — so a level-triggered loop waits for a
      readability that will never come and the request is never finished.
      The thread driver has always guarded this in WaitReadable; the engine
      needs the same fact exposed to it. }
    function HasBufferedInput: Boolean;

    { True while bytes are held waiting for the socket to drain. The engine
      must keep watching for writability until this goes false, or the tail
      of a response is never sent. }
    function WantsWritable: Boolean;

    { DRAIN-DIAG-1. One-line snapshot of everything the graceful drain
      consults, formatted from INSIDE the class so the private fields need no
      accessors of their own — FOutUsed and FPeerClosed have no business being
      public API just to be observable.

      Exists because three successive hypotheses about the drain (uncounted
      queue time, the deadline, held output) each looked right, each carried a
      fix, and none was the cause. Every one of them was an inference from
      aggregate timings. This reports what is actually TRUE, per connection,
      at the moments that matter.

      Costs nothing when unused: callers gate on TNghttp2Server.DrainDiagnostics,
      which is False unless a test turns it on. }
    function DrainState: string;

    { True when the pump has nothing more to do and the connection can be
      retired — the engine's equivalent of the thread driver's loop
      condition going false. }
    function Finished: Boolean;

    { Nothing outstanding: no worker holds a stream, no response is staged,
      and nghttp2 has no bytes left to write. Only meaningful at the bottom of
      an iteration — that is the one point where a staged response has been
      submitted AND its bytes have gone out. }
    function Idle: Boolean;

    property Session: TNghttp2Session read FSession;
  end;

  // ─── Per-connection worker thread ─────────────────────────────────────
  TNghttp2ConnectionThread = class(TThread)
  private
    FServer:   TNghttp2Server;
    FSock:     TSocketHandle;
    FPeerAddr: string;
    // 1 = nothing outstanding: no worker holds a stream, no response is
    // staged, and nghttp2 has no bytes left to write. Written only by this
    // connection thread at the end of each pump iteration; read by the
    // server's graceful drain. See TNghttp2Server.AllConnectionsIdle.
    FIdle:     Integer;
    procedure SetIdle(AValue: Boolean);
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TNghttp2Server; ASock: TSocketHandle;
      const APeerAddr: string);
    function  IsIdle: Boolean;
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
    FConfig:         TNghttp2Config;
    FOnRequest:      TNghttp2OnRequestProc;
    { INBOUND-1 — handed to every new session. Plain-proc rather than
      `of object` for the same reason OnRequest is: the host wires a
      unit-scope trampoline, and a method pointer here would force a type
      mismatch at the assignment below. }
    FOnShouldStreamInbound: TNghttp2ShouldStreamInboundProc;
    { WS-8441 — handed to every new session; see the property below. }
    FEnableConnectProtocol: Boolean;
    FListener:       TSocketHandle;
    FAcceptThread:   TNghttp2AcceptThread;
    FConnections:    TList<TNghttp2ConnectionThread>;
    FConnLock:       TCriticalSection;
    // Hard stop. Connection pumps exit as soon as they see this, abandoning
    // whatever they were doing, so it must be set only once the drain is over.
    FStopping:       Integer;   // 0 / 1 via TInterlocked
    // Graceful drain in progress: stop accepting, but keep every existing
    // connection serving. Split out from FStopping because that one flag used
    // to mean both "stop accepting" and "tear down the pumps" — so beginning a
    // drain killed the pumps outright and queued responses could never be
    // written, which is the opposite of what a graceful shutdown is for.
    FDraining:       Integer;   // 0 / 1 via TInterlocked
    // Live connection threads. Tracked separately from FConnections.Count
    // because Stop must wait for threads to finish WITHOUT dereferencing
    // them — they free themselves now, so a count is the only thing safe to
    // observe once a thread has left the list.
    FConnCount:      Integer;   // TInterlocked-managed
    FActiveRequests: Integer;   // TInterlocked-managed request-in-flight counter
    // Optional TLS context. Non-owning reference — caller allocates the
    // TTlsServerContext (loads cert+key+ALPN) before calling Start, and
    // Frees it after Stop. When nil, connections run in cleartext (h2c).
    FTlsContext:     TTlsServerContext;
    { Non-nil only when UseEventLoop was requested AND an engine unit is
      linked. While set, this owns every connection and the per-connection
      thread driver is not used at all. }
    FEngine:         INghttp2Engine;

    { DRAIN-DIAG-1. Off by default; a test turns it on before Start. Gates
      every diagnostic WriteLn in the drain path, so a normal run pays one
      Boolean read per pump iteration and prints nothing. }
    FDrainDiagnostics: Boolean;
  protected
    function  IsStopping: Boolean;
    function  IsDraining: Boolean;
    procedure RegisterConnection(AConn: TNghttp2ConnectionThread);
    procedure UnregisterConnection(AConn: TNghttp2ConnectionThread);
    // Config surface the connection threads read. Exposed here rather than
    // copied into each thread so a single record stays the source of truth.
    function  AsyncDispatch:        Boolean;
    function  PollIntervalMS:       Integer;
    function  MaxConcurrentStreams: Integer;
  public
    { Public, not protected: an accept-owning engine lives in another unit and
      does its own accepting, so it has to apply the same ceiling the server's
      accept thread does. Protected would compile inside Nghttp2.Server and
      fail only once an engine unit is linked. }
    function  AtConnectionLimit:    Boolean;
    // Empty when no engine is registered — i.e. the thread driver is running.
    function  EngineName:           string;

    { True when every live connection has finished everything it owes: no
      worker still holds one of its streams, no staged response is waiting to
      be submitted, and nghttp2 has no bytes left to write.

      A graceful drain must wait for THIS, not just for the request counter to
      reach zero. That counter is retired by the worker as its handler
      returns, which is before the response has been submitted to nghttp2 and
      before it has reached the socket — so draining on the counter alone
      declares victory while replies are still queued, and the force-close
      that follows severs requests whose handlers had already completed. }
    function AllConnectionsIdle: Boolean;

    { True once an event-loop engine actually took over — i.e. UseEventLoop
      was asked for AND a platform engine was linked. Requesting is not
      getting, and the difference is invisible from the outside: a run that
      silently fell back to the thread driver looks exactly like one that did
      not, which is how a benchmark ends up measuring the wrong thing. }
    function UsingEventLoop: Boolean;

    // Connection threads not yet finished. Safe to read at any time; unlike
    // the thread objects themselves, which free themselves on exit.
    function LiveConnections: Integer;

    // SEC-30 counter surface — called by the provider entry point's
    // ExecutePipeline (Inc on request entry, Dec in finally). Public because
    // THorseProviderNghttp2 lives in a different unit.
    procedure IncActiveRequests;
    procedure DecActiveRequests;

    constructor Create;
    destructor  Destroy; override;

    // Bind, listen, spawn the accept thread. Returns immediately.
    procedure Start(const AConfig: TNghttp2Config);
    // Close listener; accept loop exits; live connections keep running.
    procedure StopAcceptingNewConnections;
    // Hard-close every live connection socket.
    procedure ForceCloseAllConnections;
    // Full stop — StopAcceptingNewConnections + ForceCloseAllConnections +
    // wait for every thread to terminate.
    procedure Stop;

    property OnRequest:      TNghttp2OnRequestProc read FOnRequest write FOnRequest;

    { INBOUND-1. Leave unset and every stream accumulates its body and
      dispatches on END_STREAM — the historical behaviour. See
      TNghttp2ShouldStreamInbound in Nghttp2.Session.pas for what setting it
      changes. }
    property OnShouldStreamInbound: TNghttp2ShouldStreamInboundProc
      read FOnShouldStreamInbound write FOnShouldStreamInbound;

    { WS-8441. Set before Listen to advertise
      SETTINGS_ENABLE_CONNECT_PROTOCOL, permitting WebSocket-over-HTTP/2 via
      extended CONNECT (RFC 8441). Off by default. }
    property EnableConnectProtocol: Boolean
      read FEnableConnectProtocol write FEnableConnectProtocol;
    property ActiveRequests: Integer               read FActiveRequests;
    property Port:           Word                  read FConfig.Port;
    // Read by an engine that binds its own listeners.
    property ListenBacklog:  Integer               read FConfig.ListenBacklog;
    property EngineThreads:  Integer               read FConfig.EngineThreads;
    // Optional TLS. Caller allocates + configures the context (LoadCert /
    // LoadPrivateKey / EnableHttp2Alpn) and assigns before Start. Set to nil
    // for cleartext h2c. Non-owning — caller must Free the context after Stop.
    property TlsContext:     TTlsServerContext     read FTlsContext write FTlsContext;

    { DRAIN-DIAG-1. Set before Start. While true, every connection prints a
      TNghttp2ConnectionPump.DrainState line on each pump iteration for the
      duration of a drain, and the provider brackets the wait loop. Output is
      additionally IsConsole-gated at each site, so a service build stays
      silent even if this is left on. }
    property DrainDiagnostics: Boolean
      read FDrainDiagnostics write FDrainDiagnostics;
  end;

{ DRAIN-DIAG-5. Serialised diagnostic write.

  WriteLn from several connection threads into one stdout is NOT atomic: a
  captured 4-connection drain produced `phase=drain-donwantWr=0 | ...`, i.e.
  one line spliced into the middle of another. The single line needed to
  compare a failing connection against three succeeding ones in the SAME drain
  was the one that got corrupted.

  A diagnostic that garbles exactly when several threads are interesting is
  worse than none — it invites a conclusion drawn from a mangled line. }
procedure DrainLog(const AMsg: string);

var
  { Assigned by Nghttp2.Engine.Epoll's initialization when that unit is linked.
    nil everywhere else, which is what makes UseEventLoop a no-op rather than
    an error on Windows, macOS, and any build that does not include it. }
  Nghttp2EngineFactory: function(AServer: TNghttp2Server): INghttp2Engine = nil;

implementation

var
  // Read once at unit init — see TNghttp2ConnectionPump.Trace.
  GPumpTrace: Boolean = False;
  // DRAIN-DIAG-5: serialises diagnostic writes across connection threads.
  GDrainLogLock: TCriticalSection = nil;
  // DRAIN-DIAG-1 default for FDrainDiagnostics — see the initialization block.
  GDrainDiag: Boolean = False;

procedure DrainLog(const AMsg: string);
begin
  if not IsConsole then Exit;
  if GDrainLogLock <> nil then
  begin
    GDrainLogLock.Enter;
    try
      WriteLn(AMsg);
    finally
      GDrainLogLock.Leave;
    end;
  end
  else
    WriteLn(AMsg);
end;

// ─── TNghttp2Config ─────────────────────────────────────────────────

class function TNghttp2Config.Default: TNghttp2Config;
begin
  Result.Port                 := 9200;
  { FIX-BACKLOG (2026-08-17). Was 128, which silently lost connections under
    a connection BURST — measured, not theorised:

      h2load -t 14 -n 200000 -c 10000   28 545 of 200 000 requests failed,
                                        ListenOverflows +2 946
      same run, -r 500 (connections
      created at 500/s instead of
      all at once)                      0 failed, ListenOverflows +0

    Same connection count, same request count; only the ARRIVAL RATE differs.
    The accept queue, not the connection count, was the constraint.

    Two things made this hard to see. The kernel drops the completing handshake
    silently when the queue is full (`tcp_abort_on_overflow` is 0 by default),
    so nothing is logged server-side — no exception, no error, just missing
    requests. And the overflow count LOOKS far too small to explain the loss:
    2 946 against 28 545. It is not, because one dropped connection costs every
    request that would have ridden it — ~20 here (n/c), which reconciles the two
    numbers almost exactly. Comparing a connection counter against a request
    counter is what made this look like two separate defects for a while.

    Note this is per LISTENER, and with SO_REUSEPORT the engine opens one per
    loop — so the effective queue is ListenBacklog x EngineThreads. Even so 128
    x 28 loops = 3 584 could not absorb 10 000 at once.

    1024 is chosen to sit under the common `somaxconn` of 4096 (listen() caps
    silently against it, so a larger value would be quietly truncated on some
    hosts and give a false sense of headroom). The queue costs kernel memory
    only while entries actually occupy it, so an idle server pays nothing. }
  Result.ListenBacklog        := 1024;
  Result.RecvBufferSize       := 16 * 1024;
  Result.MaxConcurrentStreams := 100;
  Result.MaxConnections       := 0;      // unlimited
  Result.AsyncDispatch        := False;  // inline dispatch unless opted in
  Result.WorkerThreads        := 0;      // no pool unless the host asks
  Result.PollIntervalMS       := 50;
  Result.UseEventLoop         := False;  // thread-per-connection remains default
  Result.EngineThreads        := 0;      // 0 = one loop per core
end;

// ─── TNghttp2ConnectionThread ────────────────────────────────────────────

const
  // Ceiling on how long a closing connection waits for its worker threads.
  // Generous on purpose: overshooting costs a parked teardown, undershooting
  // costs a leaked session (see the caller).
  DISPATCH_DRAIN_TIMEOUT_MS = 30000;
  DISPATCH_DRAIN_TICK_MS    = 5;

  // How long Stop lets the pumps retire themselves before force-closing.
  // A pump needs this window to send its farewell GOAWAY, which it can only
  // do while its socket is still open. Typical cost is one poll interval plus
  // a flush — well under 200 ms — so this is ten times the headroom needed,
  // and it only elapses in full when a connection is genuinely stuck.
  FAREWELL_TIMEOUT_MS       = 2000;

procedure WaitForPendingDispatch(ASession: TNghttp2Session);
var
  LWaited: Integer;
begin
  LWaited := 0;
  while (ASession.PendingDispatch > 0) and (LWaited < DISPATCH_DRAIN_TIMEOUT_MS) do
  begin
    Sleep(DISPATCH_DRAIN_TICK_MS);
    Inc(LWaited, DISPATCH_DRAIN_TICK_MS);
  end;
end;

constructor TNghttp2ConnectionThread.Create(AServer: TNghttp2Server;
  ASock: TSocketHandle; const APeerAddr: string);
begin
  inherited Create(True);   // create suspended
  { Self-freeing. Previously False, with the server freeing whatever was still
    in FConnections when Stop ran — which meant every connection that closed
    NORMALLY leaked its TThread object and OS thread handle, because it had
    already removed itself from that list on the way out. Only connections
    still open at shutdown were ever freed. A long-lived server leaked one
    thread object per connection served, which matters rather more now that
    async dispatch makes high connection counts practical.

    The cost of True is that the server may no longer touch a connection
    object during teardown — it could be freeing itself concurrently. So Stop
    waits on FConnCount rather than joining objects, and every other access
    (ForceCloseAllConnections, AllConnectionsIdle) happens under FConnLock,
    which a thread must also take to unregister. Anything still in the list is
    therefore still alive. }
  FreeOnTerminate := True;
  FServer         := AServer;
  FSock           := ASock;
  FPeerAddr       := APeerAddr;
  // Idle until proven otherwise: a connection that has not yet been handed a
  // request owes nothing, and must not hold up a drain.
  FIdle           := 1;
end;

procedure TNghttp2ConnectionThread.SetIdle(AValue: Boolean);
begin
  if AValue then
    TInterlocked.Exchange(FIdle, 1)
  else
    TInterlocked.Exchange(FIdle, 0);
end;

function TNghttp2ConnectionThread.IsIdle: Boolean;
begin
  Result := TInterlocked.CompareExchange(FIdle, 0, 0) <> 0;
end;

// ─── TNghttp2ConnectionPump ──────────────────────────────────────────────

constructor TNghttp2ConnectionPump.Create(AServer: TNghttp2Server;
  ASock: TSocketHandle; const APeerAddr: string);
begin
  inherited Create;
  FServer     := AServer;
  FSock       := ASock;
  FPeerAddr   := APeerAddr;
  FPeerClosed := False;
  FTls        := nil;
  FAsync      := AServer.AsyncDispatch;
  FPollMS     := AServer.PollIntervalMS;
  if FPollMS <= 0 then
    FPollMS := 50;

  SetLength(FRecvBuf, 16 * 1024);   // matches Config.RecvBufferSize default

  FConn    := TNghttp2ConnectionState.Create(APeerAddr, AServer.Port);
  FSession := TNghttp2Session.Create(FConn, AServer.MaxConcurrentStreams,
                                    AServer.EnableConnectProtocol);   { WS-8441 }
  FSession.AsyncMode := FAsync;
end;

destructor TNghttp2ConnectionPump.Destroy;
begin
  { Detach the driver's wake hook FIRST, before anything else here.

    It points at the driver, and the driver may be freed once this pump is
    gone. A worker that stages a response after that would call through a
    dangling instance — and the wedged-worker path below deliberately LEAKS
    the session rather than freeing it, so "the session is gone" is not a
    guarantee this can rely on. Detaching is, and it is safe to call even on
    a session that outlives us. }
  if FSession <> nil then
    FSession.SetWakeProc(nil);

  // Worker threads reach back into this session (EndAsyncDispatch, and the
  // response staging in Send) so it must outlive every stream it handed out.
  // The driver's loop exits on paths that do not wait for that — protocol
  // error, send failure, shutdown — so settle up here.
  if FAsync and (FSession <> nil) and (FSession.PendingDispatch > 0) then
    WaitForPendingDispatch(FSession);

  // A worker still holding a stream past that wait is wedged, and freeing the
  // session under it would be a use-after-free on a background thread — the
  // worst possible failure mode to diagnose. Leak instead: bounded by the
  // number of stuck connections, and the process is already unhealthy.
  if (FSession <> nil) and (FSession.PendingDispatch = 0) then
    FSession.Free;
  FSession := nil;

  if FTls <> nil then
  begin
    FTls.Shutdown;      // best-effort SSL_shutdown before socket close
    FreeAndNil(FTls);   // SSL_free — doesn't close the fd
  end;

  inherited;
end;

function TNghttp2ConnectionPump.DoRead(ABuf: Pointer; ALen: Integer): Integer;
var
  LRead: Integer;
begin
  if (FTls <> nil) and FNonBlocking then
  begin
    case FTls.ReadNB(ABuf, ALen, LRead) of
      tisOk:        begin FTlsWantsWrite := False; Result := LRead; end;
      // Nothing to read yet. SOCKET_WOULD_BLOCK, not 0 — 0 means peer closed,
      // and conflating them tears down healthy connections under load.
      tisWantRead:  begin FTlsWantsWrite := False; Result := SOCKET_WOULD_BLOCK; end;
      // A READ can want WRITE: renegotiation. Record it so WantsWritable asks
      // for EPOLLOUT, and report would-block meanwhile.
      tisWantWrite: begin FTlsWantsWrite := True;  Result := SOCKET_WOULD_BLOCK; end;
      tisClosed:    Result := 0;
    else
      Result := -1;
    end;
    Exit;
  end;

  if FTls <> nil then
    Result := FTls.Read(ABuf, ALen)        // blocking driver, unchanged
  else if FNonBlocking then
    Result := SocketRecvNB(FSock, ABuf, ALen)
  else
    Result := SocketRecv(FSock, ABuf, ALen);
end;

function TNghttp2ConnectionPump.DoSendAll(ABuf: Pointer; ALen: Integer): Boolean;
var
  LWritten: Integer;
begin
  if FTls <> nil then
  begin
    LWritten := FTls.Write(ABuf, ALen);
    // SSL_write's partial-write semantics differ across OpenSSL versions,
    // but in blocking mode (our default) it returns ALen on success or
    // <=0 on error. Treat any short write as failure.
    Result := LWritten = ALen;
  end
  else
    Result := SocketSendAll(FSock, ABuf, ALen);
end;

function TNghttp2ConnectionPump.WaitReadable(ATimeoutMS: Integer): Integer;
begin
  // A staged response outranks the socket: report "nothing to read" and let
  // the caller fall straight through to its drain step. Checked before every
  // wait, because a worker can stage its response AND retire its dispatch
  // count in the window between the last drain and this call — leaving no
  // other signal that the reply is waiting.
  if FSession.HasPendingResponses then
    Exit(0);

  // OpenSSL may hold whole decrypted records that the socket no longer
  // reports as readable; a select()-first pump would stall on them until
  // the peer happened to send more.
  if (FTls <> nil) and (FTls.Pending > 0) then
    Exit(1);

  // Work outstanding: block on worker completion rather than on the socket
  // clock. The requesting client is waiting for us and sending nothing, so
  // a plain socket wait would sit out the entire poll interval before
  // flushing a response that was ready almost immediately — which is a
  // ~50 ms tail latency on any request whose worker finishes just after the
  // pump's drain step. Still peek the socket either side of the wait so a
  // client that does send more streams is not delayed.
  if FSession.PendingDispatch > 0 then
  begin
    Result := SocketWaitReadable(FSock, 0);
    if Result <> 0 then Exit;
    FSession.WaitForResponse(ATimeoutMS);
    Result := SocketWaitReadable(FSock, 0);
    Exit;
  end;

  Result := SocketWaitReadable(FSock, ATimeoutMS);
end;

const
  { Stop pulling frames out of nghttp2 once this much is already held for a
    socket that will not take it. Without a ceiling a peer that stops reading
    makes the server buffer its entire response stream in userspace — the
    memory-exhaustion shape of a slow-loris. nghttp2's own flow control bounds
    DATA, but not control frames, and 256 KB is far above a normal burst. }
  PUMP_OUT_HIGH_WATER = 256 * 1024;

  { FIX-DRAIN-RST-2. Ceiling for the lingering close, not a delay: the normal
    exit is the peer's FIN, which ends the wait immediately. Bounded so a peer
    that never closes cannot pin the connection thread. }
  CONNECTION_LINGER_MS = 250;

procedure TNghttp2ConnectionPump.SetNonBlocking(AValue: Boolean);
begin
  if FNonBlocking = AValue then Exit;
  if not SetSocketNonBlocking(FSock, AValue) then
    raise ENghttp2Socket.Create('TNghttp2ConnectionPump: SetSocketNonBlocking failed');
  FNonBlocking := AValue;
end;

procedure TNghttp2ConnectionPump.SetWakeProc(const AProc: TNghttp2WakeProc);
begin
  if FSession <> nil then
    FSession.SetWakeProc(AProc);
end;

procedure TNghttp2ConnectionPump.Trace(const AWhere: string);
begin
  { Set NGHTTP2_PUMP_TRACE=1 to dump the exact state at each decision point.

    Added because two rounds of inferring the wedge state from the outside got
    it wrong: a handshake failure was predicted and check 16 was the fault; the
    ciphertext drain was predicted to clear it and check 17 wedges instead.
    The five values below are the entire input to every branch in the write
    path, so whichever combination is stuck will be visible rather than
    deduced. Costs one env lookup per call when off. }
  if not GPumpTrace then Exit;
  WriteLn(ErrOutput, Format(
    '[pump %s] sock=%d out=%d tlsPend=%s tlsWantW=%s nghttp2WantWrite=%s ' +
    'wantsWritable=%s peerClosed=%s sessionStarted=%s',
    [AWhere, Integer(FSock), FOutUsed,
     BoolToStr((FTls <> nil) and FTls.HasPendingOutput, True),
     BoolToStr(FTlsWantsWrite, True),
     BoolToStr(FSession.WantWrite, True),
     BoolToStr(WantsWritable, True),
     BoolToStr(FPeerClosed, True),
     BoolToStr(FSessionStarted, True)]));
  Flush(ErrOutput);
end;

function TNghttp2ConnectionPump.HasBufferedInput: Boolean;
begin
  Result := (FTls <> nil) and FNonBlocking and (FTls.Pending > 0);
end;

function DrainStamp: string;
begin
  { DRAIN-DIAG-3. Every diagnostic line carries a wall-clock stamp because the
    LOG ORDER CANNOT BE TRUSTED: connection threads, the shutdown thread and
    the main thread all WriteLn to one buffered stdout, so lines interleave
    arbitrarily. In the trace that motivated this, `[shutdown] firing` printed
    AFTER forty `[drain]` lines and half the startup banner arrived last —
    ordering that would have supported an entirely wrong conclusion about what
    ran when. A stamp makes the real sequence recoverable no matter how the
    buffers flush. }
  Result := FormatDateTime('hh:nn:ss.zzz', Now);
end;

function TNghttp2ConnectionPump.DrainState: string;
begin
  { Order matters for reading a timeline: the two composite predicates the
    drain actually tests come FIRST, then the terms they are built from, so a
    disagreement between them is visible on the same line rather than by
    cross-referencing two. }
  { fd, not just FPeerAddr: every connection here is 127.0.0.1, so the peer
    string cannot tell two apart — and the decisive comparison is exactly
    that. In a 4-connection drain some deliver and some do not, within ONE
    server and ONE drain, which is a controlled experiment with the variable
    already isolated. It was unusable until these lines could be grouped. }
  Result := Format(
    '%s fd=%d %s idle=%d wantWr=%d | pendDisp=%d pendResp=%d wantWrite=%d ' +
    'outUsed=%d bufIn=%d peerClosed=%d tls=%d',
    [DrainStamp, Integer(FSock), FPeerAddr,
     Ord(Idle), Ord(WantsWritable),
     FSession.PendingDispatch,
     Ord(FSession.HasPendingResponses),
     Ord(FSession.WantWrite),
     FOutUsed,
     Ord(HasBufferedInput),
     Ord(FPeerClosed),
     Ord(FTls <> nil)]);
end;

function TNghttp2ConnectionPump.WantsWritable: Boolean;
begin
  { The ONLY thing the engine needs from TLS readiness.

    It registers EPOLLIN permanently and EPOLLOUT iff this returns True, so
    tisWantRead needs nothing expressed and the whole TTlsIoState-to-epoll
    mapping reduces to this predicate. Three sources of "we owe the socket
    bytes": plaintext we have not encrypted yet, ciphertext OpenSSL produced
    that the socket would not take, and a handshake that wants to write. }
  Result := (FOutUsed > 0)
         or ((FTls <> nil) and FTls.HasPendingOutput)
         or FTlsWantsWrite;
end;

function TNghttp2ConnectionPump.Finished: Boolean;
begin
  { Never finished before the session has started. During a non-blocking TLS
    handshake nghttp2 has nothing queued and no bytes are held, so the naive
    test below reports "done" and the engine retires the connection in the
    middle of its handshake. }
  if FNonBlocking and (FTls <> nil) and (not FSessionStarted) then
    Exit(False);

  // Otherwise: ShouldContinue plus everything still owed to the socket —
  // bytes in FOutPending, or ciphertext inside OpenSSL, are owed to the peer
  // even when nghttp2 itself is done.
  Result := (not ShouldContinue) and (not WantsWritable);
end;

procedure TNghttp2ConnectionPump.AppendOut(ABuf: Pointer; ALen: Integer);
begin
  if ALen <= 0 then Exit;
  if Length(FOutPending) < FOutUsed + ALen then
    SetLength(FOutPending, FOutUsed + ALen + 8192);
  Move(PByte(ABuf)^, FOutPending[FOutUsed], ALen);
  Inc(FOutUsed, ALen);
end;

function TNghttp2ConnectionPump.FlushPending: TNghttp2IoResult;
var
  LSent: Integer;
begin
  { Drain ciphertext OpenSSL has ALREADY produced, before looking at our own
    plaintext — and unconditionally, because the loop below is gated on
    FOutUsed and there is a state where that is zero while TLS still holds
    bytes the peer is waiting for.

    That state is a deadlock, and it was the first thing TLS-on-the-loop hit:
    SSL_write accepts a whole response, so FOutUsed drops to 0, but the socket
    would not take all the ciphertext and TTlsConnection keeps the remainder.
    WantsWritable reports HasPendingOutput, so EPOLLOUT IS registered and the
    loop IS woken — and every wake ran a flush whose only loop was `while
    FOutUsed > 0`, i.e. did nothing at all. Small replies fit one socket write
    and never showed it; the first large one wedged the connection forever.

    A plaintext-only flush is not a flush. }
  if FTls <> nil then
    case FTls.FlushPendingOutput of
      tisOk:        FTlsWantsWrite := False;
      tisWantWrite: begin FTlsWantsWrite := True;  Exit(ioWouldBlock); end;
      tisWantRead:  begin FTlsWantsWrite := False; Exit(ioWouldBlock); end;
      tisClosed:    Exit(ioError);
    else
      Exit(ioError);
    end;

  while FOutUsed > 0 do
  begin
    if FTls <> nil then
    begin
      { FOutPending holds PLAINTEXT here — nghttp2 frames waiting to be
        encrypted. TTlsConnection keeps its own buffer for ciphertext the
        socket would not take, so a short write is handled on its side and
        this loop only needs to know how much plaintext SSL accepted. }
      case FTls.WriteNB(@FOutPending[0], FOutUsed, LSent) of
        tisOk:        FTlsWantsWrite := False;
        tisWantWrite: begin FTlsWantsWrite := True;  Exit(ioWouldBlock); end;
        // A WRITE can want READ: renegotiation needs peer bytes before it can
        // encrypt. EPOLLIN is permanent, so nothing extra to register.
        tisWantRead:  begin FTlsWantsWrite := False; Exit(ioWouldBlock); end;
      else
        Exit(ioError);
      end;
      if LSent <= 0 then Exit(ioWouldBlock);
    end
    else
    begin
      LSent := SocketSendNB(FSock, @FOutPending[0], FOutUsed);
      if LSent = SOCKET_WOULD_BLOCK then
        Exit(ioWouldBlock);
      if LSent <= 0 then
        Exit(ioError);
    end;
    Dec(FOutUsed, LSent);
    if FOutUsed > 0 then
      // Short write: shuffle the tail down, so no other routine has to carry
      // an offset. Cheap at these sizes.
      Move(FOutPending[LSent], FOutPending[0], FOutUsed);
  end;
  Result := ioOk;
end;

function TNghttp2ConnectionPump.WritePhaseNB: TNghttp2PumpStep;
var
  LSendPtr: PByte;
  LSendLen: NativeInt;
begin
  Result := psContinue;
  Trace('write.enter');

  // Held bytes go first — HTTP/2 frames must reach the peer in order, so
  // newly extracted ones cannot overtake a remainder.
  case FlushPending of
    ioError:      Exit(psAbort);
    ioWouldBlock: Exit(psContinue);   // still backed up; engine waits on write
  end;

  { Stop extracting while EITHER buffer is backed up. FOutUsed alone misses the
    TLS case entirely: SSL_write accepts everything, so plaintext stays near
    zero while ciphertext piles up inside TTlsConnection unbounded — the
    memory-exhaustion shape this ceiling exists to prevent, just one layer
    down from where it was being measured. }
  while FSession.WantWrite and (FOutUsed < PUMP_OUT_HIGH_WATER)
    and ((FTls = nil) or (not FTls.HasPendingOutput)) do
  begin
    LSendLen := FSession.ExtractOutgoing(LSendPtr);
    if LSendLen <= 0 then Break;
    AppendOut(LSendPtr, LSendLen);
    case FlushPending of
      ioError:      Exit(psAbort);
      ioWouldBlock: Break;            // remainder held; stop extracting
    end;
  end;

  { The state that decides whether this connection is ever woken again. If
    nghttp2 still WantWrite here but nothing is pending, no EPOLLOUT is asked
    for and only the periodic sweep will come back to it. }
  Trace('write.exit');
end;

function TNghttp2ConnectionPump.Setup: Boolean;
begin
  Result := False;

  // ── TLS handshake (if enabled) ───────────────────────────────────────
  // Runs BEFORE any nghttp2 traffic. On failure, close the connection —
  // don't try to fall back to h2c because that would leak the fact that
  // TLS validation failed vs succeeded.
  if FServer.TlsContext <> nil then
  begin
    try
      FTls := TTlsConnection.Create(FServer.TlsContext, FSock);

      if FNonBlocking then
      begin
        { Do NOT handshake here. Setup runs on the loop thread, and a blocking
          handshake would stall every other connection that loop owns for as
          long as the peer cares to drag it out. RunOnce drives HandshakeStep
          instead, one epoll wake at a time. }
        FTls.NonBlocking := True;
        Exit(True);
      end;

      FTls.DoHandshake;
      // ALPN must have selected 'h2'. If the client didn't offer h2, our
      // callback returned NOACK and OpenSSL either omitted ALPN or the
      // handshake failed. Either way, reject at this point.
      if FTls.NegotiatedProtocol <> 'h2' then
        Exit;
    except
      // Swallow handshake errors — they're per-connection noise (malformed
      // TLS, wrong ALPN, cert issues). Just tear down and move on.
      Exit;
    end;
  end;

  Result := StartSession;
end;

function TNghttp2ConnectionPump.StartSession: Boolean;
var
  LSendPtr: PByte;
  LSendLen: NativeInt;
begin
  Result := False;

  // Wire the plain-proc callback directly — the SEC-30 active-request
  // counter is bumped by the host's OnRequest handler (for the Horse
  // provider, in ExecutePipelineTrampoline, which brackets queue time as
  // well as execution). Keeping it there avoids a method-pointer vs
  // plain-procedure type mismatch here.
  FSession.OnRequest := FServer.OnRequest;
  FSession.OnShouldStreamInboundProc := FServer.OnShouldStreamInbound;   { INBOUND-1 }

  { Flush initial SETTINGS before entering the pump.

    Mode matters here. DoSendAll loops over SocketSend and treats <=0 as
    failure — on a non-blocking socket a full send buffer returns EAGAIN, so
    the blocking path would report the handshake as failed for a connection
    that is perfectly healthy. WritePhaseNB holds the remainder instead. }
  if FNonBlocking then
  begin
    if WritePhaseNB = psAbort then Exit;
  end
  else
    while FSession.WantWrite do
    begin
      LSendLen := FSession.ExtractOutgoing(LSendPtr);
      if LSendLen <= 0 then Break;
      if not DoSendAll(LSendPtr, LSendLen) then Exit;
    end;

  FSessionStarted := True;
  Result := True;
end;

function TNghttp2ConnectionPump.ShouldContinue: Boolean;
begin
  { Synchronous mode keeps its original shape exactly: block in recv, feed,
    flush, repeat — every response is already submitted by the time
    FeedIncoming returns.

    Async mode stays in the loop while workers hold streams: a client that
    half-closes after sending its request (recv returns 0) must still get its
    response, so peer close stops the reading rather than the loop. }
  Result := ((not FPeerClosed) and FSession.WantRead)
            or FSession.WantWrite
            or (FSession.PendingDispatch > 0)
            or FSession.HasPendingResponses;
end;

function TNghttp2ConnectionPump.Idle: Boolean;
begin
  Result := (FSession.PendingDispatch = 0) and
            (not FSession.HasPendingResponses) and
            (not FSession.WantWrite) and
            // Buffered TLS input is work outstanding even though nghttp2 has
            // not seen it yet. Reporting idle here lets the engine's sweep
            // skip a connection that is holding half a request.
            (not HasBufferedInput);
end;

procedure TNghttp2ConnectionPump.PhaseMark(const AWhere: string);
begin
  if FServer.DrainDiagnostics and FServer.IsDraining then
    DrainLog(Format('[drain] %s fd=%d %s phase=%s pendDisp=%d pendResp=%d wantWrite=%d',
      [DrainStamp, Integer(FSock), FPeerAddr, AWhere,
       FSession.PendingDispatch,
       Ord(FSession.HasPendingResponses),
       Ord(FSession.WantWrite)]));
end;

function TNghttp2ConnectionPump.RunOnce: TNghttp2PumpStep;
var
  LRecvLen:  Integer;
  LSendPtr:  PByte;
  LSendLen:  NativeInt;
  LFeedRc:   NativeInt;
  LReadable: Integer;
begin
  Result := psContinue;

  { ── Non-blocking TLS handshake ─────────────────────────────────────────
    One step per wake. HandshakeStep flushes on every pass and reports which
    readiness it needs next; EPOLLIN is permanent, so only want-write has to
    be recorded for the engine to act on.

    Nothing below this may run until the handshake completes — nghttp2 has not
    seen a byte yet, and writing SETTINGS into a half-open TLS session would
    put application data ahead of the handshake. }
  if (FTls <> nil) and FNonBlocking and (not FTlsHandshakeDone) then
  begin
    case FTls.HandshakeStep of
      tisOk:
        begin
          FTlsHandshakeDone := True;
          FTlsWantsWrite    := False;
          { ALPN must have selected 'h2'. Rejecting here rather than falling
            back to h2c is deliberate: a fallback would tell the client
            whether TLS validation succeeded. }
          if FTls.NegotiatedProtocol <> 'h2' then
            Exit(psAbort);
          if not StartSession then
            Exit(psAbort);
          // Fall through: the same wake can carry real traffic.
        end;
      // Still handshaking. Note HandshakeStep returns tisWantWrite even after
      // SSL_accept succeeds if the closing flight is still buffered — treating
      // that as done would let app data race the handshake onto the wire.
      tisWantWrite: begin FTlsWantsWrite := True;  Exit(psContinue); end;
      tisWantRead:  begin FTlsWantsWrite := False; Exit(psContinue); end;
    else
      // tisClosed or tisError — no farewell is deliverable through a session
      // that never opened.
      Exit(psAbort);
    end;
  end;

  // A drain has begun: tell the peer to stop opening new streams. Without
  // this the drain cannot converge against a closed-loop client, which
  // keeps issuing requests as fast as replies arrive. Idempotent, and
  // safe here — between pump calls, never inside one.
  if FServer.IsDraining then
    FSession.SubmitShutdownNotice;

  PhaseMark('read-begin');
  // ─── Read side ───────────────────────────────────────────────────────
  if (not FPeerClosed) and FSession.WantRead then
  begin
    if FNonBlocking then
      { An engine already did the waiting — that is its entire job — and both
        branches below BLOCK: WaitReadable parks in select() for PollIntervalMS
        and can park again inside WaitForResponse. Either would stall the one
        thread serving every other connection on this loop. Just attempt the
        read; SOCKET_WOULD_BLOCK is handled below and is the normal answer. }
      LReadable := 1
    else if FAsync then
    begin
      LReadable := WaitReadable(FPollMS);
      if LReadable < 0 then Exit(psStop);   // socket error
    end
    else
      LReadable := 1;                       // block in recv, as before

    if LReadable > 0 then
    begin
      LRecvLen := DoRead(@FRecvBuf[0], Length(FRecvBuf));
      if LRecvLen = SOCKET_WOULD_BLOCK then
      begin
        // Non-blocking mode only, and the single most common outcome there:
        // the poller said readable, another pass already drained it, or it
        // was a spurious wake. Nothing to feed — fall through to the drain
        // and write phases. Reading this as peer-close (which -1 and 0 both
        // mean) would tear down healthy connections under load.
      end
      else if LRecvLen <= 0 then
      begin
        // Peer closed or recv failed. With work still in flight we owe
        // those streams a response attempt, so stop reading and let the
        // loop condition retire the connection once they finish.
        if not FAsync then Exit(psStop);
        FPeerClosed := True;
      end
      else
      begin
        LFeedRc := FSession.FeedIncoming(@FRecvBuf[0], LRecvLen);
        if LFeedRc < 0 then Exit(psStop);   // nghttp2 protocol error
      end;
    end;
  end
  else if FAsync and (not FNonBlocking) and (FSession.PendingDispatch > 0) then
  begin
    // Nothing readable to wait on (peer gone, or nghttp2 wants no more
    // input) but workers are still running. Block on completion rather
    // than spin; skip the wait outright if a response is already staged.
    //
    // Thread driver only. Under an engine this blocks the shared loop; the
    // engine instead re-services connections that still have work, which is
    // the same guarantee reached without parking anyone.
    if not FSession.HasPendingResponses then
      FSession.WaitForResponse(FPollMS);
  end;

  PhaseMark('read-done');
  // ─── Submit whatever the workers finished ────────────────────────────
  // Must happen here, outside FeedIncoming: nghttp2_submit_response is
  // safe to call between pump calls but never re-entrantly from inside
  // one. No-op in synchronous mode.
  FSession.DrainPendingResponses;

  { ── Farewell GOAWAY — stage two of RFC 9113 §6.8 ────────────────────
    Queued HERE, after the responses are submitted but before the write
    loop, so it leaves in the same burst as the final response rather
    than in a flush of its own.

    Timing is the whole problem. A one-shot client exits the moment its
    last stream ends: a frame trace showed the response delivered at
    t=4.003 and the connection gone before the server's drain even
    returned 50 ms later. Sending this at teardown missed the peer
    entirely; sending it in a second flush right after the response still
    races the client's exit. Riding along in the same write removes the
    race — TCP preserves order, so the peer sees the open-ended notice
    first and the cutoff second, exactly as the RFC intends.

    The condition is "everything owed is now in nghttp's queue": no
    worker still holds a stream, and no staged response is waiting to be
    submitted. Deliberately not `not WantWrite` — the response we are
    about to flush makes that false, and waiting for it would put us back
    in a separate burst. }
  if FServer.IsDraining and (not FPeerClosed)
     and (FSession.PendingDispatch = 0)
     and (not FSession.HasPendingResponses) then
  begin
    { DRAIN-DIAG-2: log the cutoff BEFORE submitting it. This number decides on
      the wire which requests the peer must replay — everything above it is
      abandoned — so a low value is indistinguishable, at the client, from a
      severed reply. Observed varying between 13 and 0 across runs of the same
      single-request test while stage 8 passed both times. }
    if FServer.DrainDiagnostics and IsConsole then
      DrainLog(Format('[drain] %s fd=%d %s final GOAWAY cutoff '
        + 'last_proc_stream_id=%d',
        [DrainStamp, Integer(FSock), FPeerAddr, FSession.LastProcStreamId]));
    FSession.SubmitFinalGoaway;
  end;

  PhaseMark('drain-done');
  // ─── Write side ──────────────────────────────────────────────────────
  if FNonBlocking then
    Exit(WritePhaseNB);

  while FSession.WantWrite do
  begin
    LSendLen := FSession.ExtractOutgoing(LSendPtr);
    if LSendLen <= 0 then Break;
    // Send failure: no working socket, so skip the farewell entirely.
    if not DoSendAll(LSendPtr, LSendLen) then Exit(psAbort);
  end;
end;

procedure TNghttp2ConnectionPump.SendFarewell;
var
  LSendPtr: PByte;
  LSendLen: NativeInt;
begin
  { Fallback for the in-loop farewell. That path covers the graceful case;
    this catches a pump forced out some other way — FStopping raised during a
    hard Stop, for instance — where the connection never reached a settled
    state. Idempotent, so it is a no-op when the frame already went.

    Gated on IsDraining, and that gate is not optional. Without it this ran
    on EVERY connection teardown, writing a GOAWAY to peers that had simply
    finished and hung up — which is a write to a closed socket, i.e. SIGPIPE,
    i.e. the whole server process killed with exit 141. (SIGPIPE is now
    ignored at the socket layer, so this can no longer be fatal, but writing
    to a dead peer on every normal close was never the intent: a GOAWAY is a
    shutdown announcement, not a goodbye for ordinary connection reuse.)

    Also skipped when the peer has already gone; there is nobody to inform. }
  if not (FServer.IsDraining and (not FPeerClosed)) then Exit;

  // DRAIN-DIAG-2: the fallback path submits the same cutoff, so it has to be
  // observable too — otherwise a run that took THIS route would look like the
  // in-loop one and the two would be impossible to tell apart in a log.
  if FServer.DrainDiagnostics and IsConsole then
    DrainLog(Format('[drain] %s fd=%d %s final GOAWAY (SendFarewell) cutoff '
      + 'last_proc_stream_id=%d',
      [DrainStamp, Integer(FSock), FPeerAddr, FSession.LastProcStreamId]));

  FSession.SubmitFinalGoaway;

  // Best effort in both modes. Non-blocking cannot guarantee the frame
  // leaves — a full send buffer holds it in FOutPending, and the engine gets
  // one more writable pass to push it before the socket closes.
  if FNonBlocking then
  begin
    WritePhaseNB;
    Exit;
  end;

  while FSession.WantWrite do
  begin
    LSendLen := FSession.ExtractOutgoing(LSendPtr);
    if LSendLen <= 0 then Break;
    if not DoSendAll(LSendPtr, LSendLen) then Break;
  end;
end;

// ─── TNghttp2ConnectionThread.Execute ────────────────────────────────────
// The thread driver: one connection, one thread, loop until it is done. All
// the protocol work lives in TNghttp2ConnectionPump — this is only the loop
// and the socket's lifetime.

procedure TNghttp2ConnectionThread.Execute;
var
  LPump:     TNghttp2ConnectionPump;
  LStep:     TNghttp2PumpStep;
  LLingerRc: Integer;      // FIX-DRAIN-RST-2: how the graceful close exited
begin
  FServer.RegisterConnection(Self);

  { Pump construction is INSIDE the try. It was outside, so anything that threw
    while building it — a nil FFI pointer, an allocation failure — skipped the
    finally entirely: the socket was never shut down and the peer hung instead
    of getting a connection error. A client that fails fast is diagnosable; one
    that hangs cost six rounds of investigation. }
  LPump := nil;
  try
    LPump := TNghttp2ConnectionPump.Create(FServer, FSock, FPeerAddr);

    if LPump.Setup then
    begin
      while (not Terminated) and (not FServer.IsStopping)
        and LPump.ShouldContinue do
      begin
        LStep := LPump.RunOnce;
        // Send failure — no socket to say goodbye on. Skip the farewell.
        if LStep = psAbort then Exit;
        if LStep = psStop  then Break;

        // Publish whether anything is still owed, for the server's graceful
        // drain. Only on a completed iteration: the two exits above leave
        // mid-flight, exactly as the original loop's Exit and Break did.
        SetIdle(LPump.Idle);

        { DRAIN-DIAG-1: a per-iteration timeline of THIS connection for the
          whole drain window. Emitted from the OWNING thread, which is what
          makes it safe — the server never reaches into a pump it does not
          own, and a diagnostic must never be the thing that introduces a
          lifetime hazard into the path it is diagnosing.

          IsDraining is protected but this class shares the unit, so no
          accessor is needed. }
        if FServer.DrainDiagnostics and FServer.IsDraining then
          DrainLog('[drain] ' + LPump.DrainState);
      end;

      LPump.SendFarewell;
    end;
  finally
    // Order matters and matches the original teardown: settle the session
    // (which may wait on workers) BEFORE the socket goes, then leave the
    // registry last so the server can still reach this connection until
    // there is nothing left to reach. LPump.Free is nil-safe, which is what
    // makes the construction-failure path above land here correctly.
    LPump.Free;
    { FIX-DRAIN-RST-2 (re-applied 2026-08-19). THIS is where the socket dies —
      strace shows this thread issuing shutdown(SHUT_RDWR)+close 250 us after
      its own full-length writes of the response, which RSTs the reply away.
      ForceCloseAllConnections runs later and is not the actor.

      Judge this by the strace (shutdown should now be SHUT_WR, followed by
      reads to EOF, then close) and by the linger= code below — NOT by the
      delivery rate, which is noisy and has misled twice. }
    LLingerRc := CloseSocketGraceful(FSock, CONNECTION_LINGER_MS);
    if FServer.DrainDiagnostics then
      DrainLog(Format('[drain] %s fd=%d close: linger=%d (0=peer FIN, '
        + '1=budget expired, -1=error)',
        [DrainStamp, Integer(FSock), LLingerRc]));
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
  while (not Terminated) and (not FServer.IsStopping)
    and (not FServer.IsDraining) do
  begin
    LSock := AcceptConnection(FServer.FListener, LPeerAddr);
    if LSock = INVALID_SOCKET_HANDLE then
    begin
      // Accept returned error — most commonly the listener was closed by
      // StopAcceptingNewConnections. Exit if we're stopping; otherwise loop
      // (spurious errors under load).
      if FServer.IsStopping or FServer.IsDraining then Break;
      Continue;
    end;

    // Every connection costs a thread here, so refuse past the cap rather
    // than accept work the process cannot staff. Closing immediately gives
    // the client a clean connection error to retry on; leaving the socket
    // open and unserviced would look like a hang.
    if FServer.AtConnectionLimit then
    begin
      ShutdownSocketHandle(LSock);
      Continue;
    end;

    if FServer.FEngine <> nil then
      // Ownership passes to the engine here; it will close the socket.
      FServer.FEngine.HandOff(LSock, LPeerAddr)
    else
    begin
      LWorker := TNghttp2ConnectionThread.Create(FServer, LSock, LPeerAddr);
      LWorker.Start;
    end;
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
  // DRAIN-DIAG-1: env-var default; a caller may still set the property.
  FDrainDiagnostics := GDrainDiag;
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

function TNghttp2Server.IsDraining: Boolean;
begin
  Result := TInterlocked.CompareExchange(FDraining, 0, 0) <> 0;
end;

procedure TNghttp2Server.RegisterConnection(AConn: TNghttp2ConnectionThread);
begin
  FConnLock.Enter;
  try
    FConnections.Add(AConn);
    Inc(FConnCount);
  finally
    FConnLock.Leave;
  end;
end;

procedure TNghttp2Server.UnregisterConnection(AConn: TNghttp2ConnectionThread);
begin
  { The last thing a connection thread does before Execute returns and the
    thread frees itself. Count and list drop together under the lock, so
    anything a lock holder can see in FConnections is still alive. }
  FConnLock.Enter;
  try
    FConnections.Remove(AConn);
    Dec(FConnCount);
  finally
    FConnLock.Leave;
  end;
end;

function TNghttp2Server.UsingEventLoop: Boolean;
begin
  Result := FEngine <> nil;
end;

function TNghttp2Server.LiveConnections: Integer;
begin
  // In engine mode there are no connection threads to count — the whole
  // graceful-shutdown contract reads through these three accessors, so
  // delegating here is what keeps StopListenGraceful working unchanged.
  if FEngine <> nil then
    Exit(FEngine.LiveConnections);
  FConnLock.Enter;
  try
    Result := FConnCount;
  finally
    FConnLock.Leave;
  end;
end;

function TNghttp2Server.AsyncDispatch: Boolean;
begin
  Result := FConfig.AsyncDispatch;
end;

function TNghttp2Server.PollIntervalMS: Integer;
begin
  Result := FConfig.PollIntervalMS;
end;

function TNghttp2Server.MaxConcurrentStreams: Integer;
begin
  Result := FConfig.MaxConcurrentStreams;
end;

function TNghttp2Server.AllConnectionsIdle: Boolean;
var
  I: Integer;
begin
  if FEngine <> nil then
    Exit(FEngine.AllIdle);
  Result := True;
  FConnLock.Enter;
  try
    for I := 0 to FConnections.Count - 1 do
      if not FConnections[I].IsIdle then
        Exit(False);
  finally
    FConnLock.Leave;
  end;
end;

function TNghttp2Server.EngineName: string;
begin
  if FEngine <> nil then
    Result := FEngine.DriverName
  else
    Result := '';
end;

function TNghttp2Server.AtConnectionLimit: Boolean;
begin
  if FConfig.MaxConnections <= 0 then
    Exit(False);

  // Engine mode keeps no connection threads, so FConnections is empty and the
  // count below would report zero forever — MaxConnections silently ignored
  // exactly where high connection counts are the point.
  if FEngine <> nil then
    Exit(FEngine.LiveConnections >= FConfig.MaxConnections);

  FConnLock.Enter;
  try
    Result := FConnections.Count >= FConfig.MaxConnections;
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

procedure TNghttp2Server.Start(const AConfig: TNghttp2Config);
begin
  if FListener <> INVALID_SOCKET_HANDLE then
    raise Exception.Create('TNghttp2Server: already listening');

  { Load libnghttp2 HERE, not in the host.

    Until now only Horse.Provider.Nghttp2 and TNghttp2Client called NghttpLoad,
    so a program using TNghttp2Server directly — including the "minimal server"
    in this repo's README — left every FFI pointer nil. The failure mode was
    diabolical: the listener binds (that is our own socket code, no FFI), the
    banner prints, the client connects and completes its TCP handshake, and
    then the connection thread dies on a nil call inside TNghttp2Session.Create
    with the exception captured silently by TThread. The client waits forever on
    a socket nobody will close. No error, no log line, no crash.

    NghttpLoad is idempotent, so a host that already called it pays nothing. }
  if not NghttpLoad then
    raise ENghttp2Socket.CreateFmt(
      'TNghttp2Server.Start: libnghttp2 could not be loaded — %s', [NghttpLoadError]);

  FConfig := AConfig;
  TInterlocked.Exchange(FStopping, 0);

  { Engine mode is opt-in twice over: the caller asks for it, and a platform
    engine has to have registered itself. Either missing means the thread
    driver runs, which is the validated default — an unavailable engine must
    degrade quietly, never refuse to start a server.

    Built BEFORE the listener now, because an engine that owns its accept path
    binds its own SO_REUSEPORT listeners and the server must not bind the port
    first — a plain SO_REUSEADDR listener on the same port would take a share
    of the accepts with no loop thread behind it, and those connections would
    simply never be served. }
  if FConfig.UseEventLoop and Assigned(Nghttp2EngineFactory) then
  begin
    FEngine := Nghttp2EngineFactory(Self);
    if FEngine <> nil then
      FEngine.Start;
  end;

  if (FEngine <> nil) and FEngine.OwnsAccept then
    // Each loop accepts on the thread that will serve the connection. No
    // server listener, no accept thread, no handoff queue.
    Exit;

  FListener := CreateListenerSocket(FConfig.Port, FConfig.ListenBacklog);
  FAcceptThread := TNghttp2AcceptThread.Create(Self);
  FAcceptThread.Start;
end;

procedure TNghttp2Server.StopAcceptingNewConnections;
var
  LListener: TSocketHandle;
begin
  // Draining, NOT stopping. Existing connections must keep pumping so their
  // queued responses actually reach the socket; only the listener closes here.
  // Setting FStopping at this point would exit every pump immediately and
  // discard replies whose handlers had already finished.
  TInterlocked.Exchange(FDraining, 1);

  { DRAIN-DIAG-3: this procedure is the ONLY code that runs between the
    shutdown trigger and the drain's wait loop, and the client is reset inside
    that window — ~1 s in, while the pump goes on reporting a healthy
    connection for another second. Stamp each step so the reset can be placed
    against them instead of guessed at. }
  if FDrainDiagnostics then
    DrainLog(Format('[drain] %s StopAcceptingNewConnections: entered, '
      + 'FDraining set', [DrainStamp]));

  // An accept-owning engine has its own listeners; ask it to close them. The
  // rest of the drain is identical — connections keep pumping either way.
  if (FEngine <> nil) and FEngine.OwnsAccept then
  begin
    FEngine.StopAccepting;
    Exit;
  end;

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

  if FDrainDiagnostics then
    DrainLog(Format('[drain] %s listener %d shut down, joining accept thread',
      [DrainStamp, Integer(LListener)]));

  if Assigned(FAcceptThread) then
  begin
    FAcceptThread.WaitFor;
    FreeAndNil(FAcceptThread);
  end;

  if FDrainDiagnostics then
    DrainLog(Format('[drain] %s StopAcceptingNewConnections: done',
      [DrainStamp]));
end;

procedure TNghttp2Server.ForceCloseAllConnections;
var
  LConn: TNghttp2ConnectionThread;
  I:     Integer;
begin
  if FEngine <> nil then
  begin
    FEngine.CloseAll;
    Exit;
  end;

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
  LWaited: Integer;
begin
  StopAcceptingNewConnections;

  // Now the hard part: tell every pump to exit. Anything a caller wanted
  // drained must already have been drained before Stop is reached — see
  // THorseProviderNghttp2.StopListenGraceful, which waits on ActiveRequests
  // and AllConnectionsIdle in between these two calls.
  TInterlocked.Exchange(FStopping, 1);

  { Let the pumps retire themselves BEFORE any socket is force-closed. Each
    one still owes its peer a farewell GOAWAY naming the last stream it
    processed, and it can only send that while its own socket is open.

    Force-closing straight after raising the flag — as this did — killed that
    frame every single time: the pump would notice the flag, try to flush,
    and find the socket already gone. Peers were left with the open-ended
    notice and a dead connection, unable to tell a request that had been
    served from one they needed to replay. A frame trace shows one GOAWAY
    where there should be two. }
  LWaited := 0;
  while (LiveConnections > 0) and (LWaited < FAREWELL_TIMEOUT_MS) do
  begin
    Sleep(DISPATCH_DRAIN_TICK_MS);
    Inc(LWaited, DISPATCH_DRAIN_TICK_MS);
  end;

  // Hard cutoff for whatever did not settle in that window.
  ForceCloseAllConnections;

  { Wait on the count, never on the objects. Connection threads free
    themselves, so snapshotting them and calling WaitFor/Free would be a race
    against their own destruction — and the snapshot could only ever see the
    ones still listed, which is exactly why the old version leaked every
    connection that had already closed.

    Unbounded on purpose. Returning early would let the caller free this
    server while threads still dereference it through FServer, trading a leak
    for a use-after-free on a background thread. It is bounded in practice:
    every socket was just shut down, so the pumps exit promptly, and the one
    slow path — a connection waiting on a wedged worker — carries its own
    30 s cap inside WaitForPendingDispatch. }
  while LiveConnections > 0 do
    Sleep(5);

  { Engine last: LiveConnections above reads through it, so tearing it down
    any earlier would make that loop consult a dead object — and releasing the
    interface is what frees the engine, joining its thread on the way out. }
  if FEngine <> nil then
  begin
    FEngine.Stop;
    FEngine := nil;
  end;
end;


initialization
  GDrainLogLock := TCriticalSection.Create;
  GPumpTrace := GetEnvironmentVariable('NGHTTP2_PUMP_TRACE') = '1';
  { DRAIN-DIAG-1 default. An env var rather than a server argument so no test
    program, script or harness needs changing to turn it on — the same choice
    NGHTTP2_PUMP_TRACE made above, and the reason it can be switched on for a
    single run of an existing suite. Any server may still override it through
    the DrainDiagnostics property before Start. }
  GDrainDiag := GetEnvironmentVariable('NGHTTP2_DRAIN_DEBUG') = '1';

finalization
  FreeAndNil(GDrainLogLock);

end.
