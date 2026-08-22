unit Nghttp2.Engine.Epoll;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Nghttp2.Engine.Epoll
//  Event-loop connection driver for Linux. Many connections per thread,
//  instead of TNghttp2ConnectionThread's one thread each.
//
//  Enabled by linking this unit AND setting THorseNghttp2Config.UseEventLoop.
//  Linking alone changes nothing; the unit registers itself through
//  Nghttp2EngineFactory in its initialization, and Nghttp2.Server never names
//  it. On any non-Linux target the whole unit compiles to nothing, so it is
//  safe to keep in a cross-platform project's uses clause.
//
//  Scope of this increment — h2c only. A TLS listener falls back to the
//  thread driver. TTlsConnection already has the non-blocking API it needs
//  (HandshakeStep / ReadNB / WriteNB / HasPendingOutput), but mapping the
//  readiness those report onto epoll registration is its own step, and doing
//  it in the same round as the loop would make a hang ambiguous between the
//  two.
//
//  What this fixes: the thread-per-connection model costs a stack and a
//  scheduler entry per connection, which is the wall Indy hits around 500.
//  It also fixes the poll interval — a worker finishing its handler now wakes
//  the loop through an eventfd rather than waiting out PollIntervalMS.
//
//  Threading contract, and the one rule that matters:
//    A TNghttp2ConnectionPump may only ever be touched by the loop thread.
//    The accept thread therefore does not build pumps; it drops the raw
//    socket on a queue and pokes the eventfd, and the loop thread does the
//    rest. Everything else here is single-threaded by construction.
// ============================================================================

interface

{$IF DEFINED(LINUX)}

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, SyncObjs, Generics.Collections,
  BaseUnix, Unix,
{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs,
  System.Generics.Collections,
  Posix.Base, Posix.Unistd,
{$IFEND}
  Nghttp2.Compat,   { TInterlocked shim for FPC < 3.3.1 — no-op elsewhere }
  Nghttp2.Socket,
  Nghttp2.Server;

{$IFEND}

implementation

{$IF DEFINED(LINUX)}

const
  // Ceiling on events returned by one epoll_wait. Not a connection limit —
  // anything above this is simply reported by the next call.
  MAX_EVENTS = 256;

  { Bounds how long the loop sleeps with nothing to do.

    Only a shutdown-check pace, NOT a response-latency ceiling — a worker
    staging a reply pokes the eventfd through TNghttp2ConnectionPump's wake
    hook, so epoll_wait returns at once rather than sitting here.

    It was doing double duty before that hook existed, and the cost was
    visible: the 94-check suite ran 2.8x slower under the engine than under
    the thread driver, because every reply waited on this timeout. Lowering
    it would have traded that latency for a spinning core; the wake is the
    actual fix. }
  LOOP_TIMEOUT_MS = 200;

  // Ceiling on consecutive RunOnce passes for one connection that still has
  // TLS-buffered input. High enough to finish a large request in one wake
  // (16 KB per read, so this covers ~512 KB), low enough that no single
  // connection can hold a loop indefinitely.
  MAX_BUFFERED_PASSES = 32;

  // ─── epoll / eventfd ───────────────────────────────────────────────────
  EPOLLIN      = $01;
  EPOLLOUT     = $04;
  EPOLLERR     = $08;
  EPOLLHUP     = $10;
  EPOLLRDHUP   = $2000;

  EPOLL_CTL_ADD = 1;
  EPOLL_CTL_DEL = 2;
  EPOLL_CTL_MOD = 3;

type
  TEpollData = record
    case Integer of
      0: (ptr: Pointer);
      1: (fd:  Integer);
      2: (u32: Cardinal);
      3: (u64: UInt64);
  end;

  { PACKED, and that is not cosmetic. On x86-64 the kernel's struct
    epoll_event carries __attribute__((packed)) — 12 bytes, not the 16 a
    natural-alignment record would produce. Get it wrong and epoll_wait
    writes results at the wrong stride: no compile error, no crash at the
    call, just events attributed to the wrong descriptors. }
  TEpollEvent = {$IF DEFINED(CPUX64)}packed {$IFEND}record
    Events: Cardinal;
    Data:   TEpollData;
  end;
  PEpollEvent = ^TEpollEvent;

{$IF DEFINED(FPC)}
{$LINKLIB c}
{$IFEND}

function epoll_create1(flags: Integer): Integer; cdecl;
  external {$IF NOT DEFINED(FPC)}libc name 'epoll_create1'{$IFEND};
function epoll_ctl(epfd, op, fd: Integer; event: PEpollEvent): Integer; cdecl;
  external {$IF NOT DEFINED(FPC)}libc name 'epoll_ctl'{$IFEND};
function epoll_wait(epfd: Integer; events: PEpollEvent;
  maxevents, timeout: Integer): Integer; cdecl;
  external {$IF NOT DEFINED(FPC)}libc name 'epoll_wait'{$IFEND};
function eventfd(initval: Cardinal; flags: Integer): Integer; cdecl;
  external {$IF NOT DEFINED(FPC)}libc name 'eventfd'{$IFEND};

{ Raw fd I/O. Delphi POSIX spells these __close/__read/__write; FPC spells
  them fpClose/fpRead/fpWrite. Only the eventfd goes through here — sockets
  keep using Nghttp2.Socket — so three one-line wrappers are cheaper than
  branching at every call site. }

function CloseFd(AFd: Integer): Integer;
begin
{$IF DEFINED(FPC)}
  Result := fpClose(AFd);
{$ELSE}
  Result := __close(AFd);
{$IFEND}
end;

{ Buffer passed as a typed Pointer, not an untyped const/var parameter.
  Delphi POSIX declares __read/__write with a `Pointer` buffer, and an untyped
  parameter cannot be passed there — it has no address to take at the call
  site (E2010: Incompatible types: 'Pointer' and 'untyped parameter'). FPC's
  untyped-const overloads accept the dereference, so a Pointer signature is
  the one spelling both compilers take. }

function WriteFd(AFd: Integer; ABuf: Pointer; ACount: Integer): Integer;
begin
{$IF DEFINED(FPC)}
  Result := fpWrite(AFd, PByte(ABuf)^, ACount);
{$ELSE}
  Result := __write(AFd, ABuf, ACount);
{$IFEND}
end;

function ReadFd(AFd: Integer; ABuf: Pointer; ACount: Integer): Integer;
begin
{$IF DEFINED(FPC)}
  Result := fpRead(AFd, PByte(ABuf)^, ACount);
{$ELSE}
  Result := __read(AFd, ABuf, ACount);
{$IFEND}
end;

type
  TNghttp2EngineLoop = class;

  { One event-loop thread. Runs exactly one TNghttp2EngineLoop and nothing
    else — the loop owns all its state, so the thread is a driver, not a
    participant. }
  TNghttp2LoopThread = class(TThread)
  private
    FLoop: TNghttp2EngineLoop;
  protected
    procedure Execute; override;
  public
    constructor Create(ALoop: TNghttp2EngineLoop);
  end;

  TPendingAccept = record
    Sock:     TSocketHandle;
    PeerAddr: string;
  end;

  { ── One loop: listener + epoll set + connections, all thread-confined ────

    Every field here belongs to this loop's thread. Nothing is shared with
    another loop, which is the entire point: N loops means N independent
    epoll sets with no lock between them.

    Each loop binds its OWN listener with SO_REUSEPORT on the same port, and
    the kernel distributes incoming connections across them. That is why there
    is no accept thread and no handoff queue in this mode — a connection is
    accepted by the very thread that will serve it, and never crosses a
    boundary. The FQueue below exists only for the fallback path, where the
    server still owns the listener and hands sockets over.

    Measured before this existed: one loop saturated at ~106% CPU at both
    c=100 and c=5000 while 27 cores idled. One loop is one core. }
  TNghttp2EngineLoop = class
  private
    FEngine:   TObject;             // TNghttp2EpollEngine, untyped to break the cycle
    FServer:   TNghttp2Server;
    FIndex:    Integer;
    FPort:     Word;
    FBacklog:  Integer;
    FOwnsAccept: Boolean;

    FListener: TSocketHandle;
    FEpollFd:  Integer;
    FWakeFd:   Integer;
    FThread:   TNghttp2LoopThread;
    FStopping: Integer;

    // Loop-thread only. No lock, by construction.
    FPumps:    TDictionary<TSocketHandle, TNghttp2ConnectionPump>;
    FEvents:   TDictionary<TSocketHandle, Cardinal>;

    // Fallback handoff path only (when the engine does not own accept).
    FQueueLock: TCriticalSection;
    FQueue:     TList<TPendingAccept>;

    // Published for the graceful-shutdown accessors, which run on the
    // caller's thread and must not touch FPumps.
    FLiveCount: Integer;
    FIdleFlag:  Integer;

    procedure DrainWakeFd;
    function  RegisterFd(ASock: TSocketHandle; AEvents: Cardinal): Boolean;
    procedure UnregisterFd(ASock: TSocketHandle);
    procedure AcceptReady;
    procedure AdmitPending;
    procedure AdmitSocket(ASock: TSocketHandle; const APeerAddr: string);
    procedure ServiceConnection(ASock: TSocketHandle; AEvents: Cardinal);
    procedure RetireConnection(ASock: TSocketHandle; ASendFarewell: Boolean);
    procedure UpdateInterest(ASock: TSocketHandle; APump: TNghttp2ConnectionPump);
    procedure SweepAndPublish;
    procedure PublishCounters;
  public
    constructor Create(AEngine: TObject; AServer: TNghttp2Server;
      AIndex: Integer; AOwnsAccept: Boolean);
    destructor  Destroy; override;

    procedure Start;
    procedure Stop;
    procedure Wake;
    procedure StopAccepting;
    procedure RunLoop;
    procedure HandOff(ASock: TSocketHandle; const APeerAddr: string);
    function  IsStopping: Boolean;
    function  LiveConnections: Integer;
    function  AllIdle: Boolean;

    property Index: Integer read FIndex;
  end;

  TNghttp2EpollEngine = class(TInterfacedObject, INghttp2Engine)
  private
    FServer:     TNghttp2Server;
    FLoops:      array of TNghttp2EngineLoop;
    FOwnsAccept: Boolean;
    FNext:       Integer;   // round-robin cursor, fallback handoff only
    function  LoopCount: Integer;
  public
    constructor Create(AServer: TNghttp2Server);
    destructor  Destroy; override;

    // INghttp2Engine
    procedure Start;
    procedure Stop;
    procedure HandOff(ASock: TSocketHandle; const APeerAddr: string);
    procedure CloseAll;
    function  LiveConnections: Integer;
    function  AllIdle: Boolean;
    function  DriverName: string;
    function  OwnsAccept: Boolean;
    procedure StopAccepting;
  end;

// ─── TNghttp2LoopThread ──────────────────────────────────────────────────

constructor TNghttp2LoopThread.Create(ALoop: TNghttp2EngineLoop);
begin
  inherited Create(True);
  FreeOnTerminate := False;   // Stop joins these explicitly
  FLoop := ALoop;
end;

procedure TNghttp2LoopThread.Execute;
begin
  FLoop.RunLoop;
end;

// ─── TNghttp2EngineLoop ──────────────────────────────────────────────────

constructor TNghttp2EngineLoop.Create(AEngine: TObject; AServer: TNghttp2Server;
  AIndex: Integer; AOwnsAccept: Boolean);
begin
  inherited Create;
  FEngine      := AEngine;
  FServer      := AServer;
  FIndex       := AIndex;
  FOwnsAccept  := AOwnsAccept;
  FPort        := AServer.Port;
  FBacklog     := AServer.ListenBacklog;
  FListener    := INVALID_SOCKET_HANDLE;
  FEpollFd     := -1;
  FWakeFd      := -1;
  FStopping    := 0;
  FPumps       := TDictionary<TSocketHandle, TNghttp2ConnectionPump>.Create;
  FEvents      := TDictionary<TSocketHandle, Cardinal>.Create;
  FQueueLock   := TCriticalSection.Create;
  FQueue       := TList<TPendingAccept>.Create;
end;

destructor TNghttp2EngineLoop.Destroy;
begin
  Stop;
  FQueue.Free;
  FQueueLock.Free;
  FEvents.Free;
  FPumps.Free;
  inherited;
end;

function TNghttp2EngineLoop.IsStopping: Boolean;
begin
  Result := TInterlocked.CompareExchange(FStopping, 0, 0) <> 0;
end;

procedure TNghttp2EngineLoop.Start;
var
  LEvent: TEpollEvent;
begin
  if FThread <> nil then Exit;

  FEpollFd := epoll_create1(0);
  if FEpollFd < 0 then
    raise ENghttp2Socket.CreateFmt('epoll_create1 failed (loop %d)', [FIndex]);

  // EFD_NONBLOCK = $800. The loop drains this unconditionally after a wake,
  // and a blocking read on a spurious wake would park the thread that serves
  // every connection on this loop.
  FWakeFd := eventfd(0, $800);
  if FWakeFd < 0 then
    raise ENghttp2Socket.CreateFmt('eventfd failed (loop %d)', [FIndex]);

  FillChar(LEvent, SizeOf(LEvent), 0);
  LEvent.Events  := EPOLLIN;
  LEvent.Data.fd := FWakeFd;
  if epoll_ctl(FEpollFd, EPOLL_CTL_ADD, FWakeFd, @LEvent) <> 0 then
    raise ENghttp2Socket.CreateFmt('epoll_ctl(ADD, wakefd) failed (loop %d)', [FIndex]);

  if FOwnsAccept then
  begin
    { Own listener, SO_REUSEPORT, same port as every other loop. The kernel
      hashes each incoming connection to one of them, so accepts spread across
      loops without a shared queue or a lock. }
    FListener := CreateListenerSocket(FPort, FBacklog, {AReusePort=}True);
    SetSocketNonBlocking(FListener, True);

    FillChar(LEvent, SizeOf(LEvent), 0);
    LEvent.Events  := EPOLLIN;
    LEvent.Data.fd := Integer(FListener);
    if epoll_ctl(FEpollFd, EPOLL_CTL_ADD, Integer(FListener), @LEvent) <> 0 then
      raise ENghttp2Socket.CreateFmt('epoll_ctl(ADD, listener) failed (loop %d)', [FIndex]);
  end;

  FThread := TNghttp2LoopThread.Create(Self);
  FThread.Start;
end;

procedure TNghttp2EngineLoop.Stop;
begin
  if FThread <> nil then
  begin
    TInterlocked.Exchange(FStopping, 1);
    Wake;
    FThread.WaitFor;      // it retires its own connections on the way out
    FreeAndNil(FThread);
  end;

  StopAccepting;
  if FWakeFd >= 0 then begin CloseFd(FWakeFd);  FWakeFd  := -1; end;
  if FEpollFd >= 0 then begin CloseFd(FEpollFd); FEpollFd := -1; end;
end;

procedure TNghttp2EngineLoop.StopAccepting;
var
  LSock: TSocketHandle;
begin
  LSock := FListener;
  FListener := INVALID_SOCKET_HANDLE;
  if LSock <> INVALID_SOCKET_HANDLE then
  begin
    // Deregister before closing: an epoll set holding a closed fd can report
    // events for a descriptor number the kernel has already reissued.
    UnregisterFd(LSock);
    ShutdownSocketHandle(LSock);
  end;
end;

procedure TNghttp2EngineLoop.Wake;
var
  LOne: UInt64;
begin
  if FWakeFd < 0 then Exit;
  LOne := 1;
  // An eventfd counter saturates rather than blocking, and the loop drains it
  // whole, so redundant wakes collapse into one.
  WriteFd(FWakeFd, @LOne, SizeOf(LOne));
end;

procedure TNghttp2EngineLoop.DrainWakeFd;
var
  LBuf: UInt64;
begin
  // Read to EAGAIN. Leaving it readable makes epoll_wait return immediately
  // forever — a busy loop that still works, which is the worst kind.
  while ReadFd(FWakeFd, @LBuf, SizeOf(LBuf)) = SizeOf(LBuf) do
    ;
end;

function TNghttp2EngineLoop.RegisterFd(ASock: TSocketHandle;
  AEvents: Cardinal): Boolean;
var
  LEvent: TEpollEvent;
begin
  FillChar(LEvent, SizeOf(LEvent), 0);
  LEvent.Events  := AEvents;
  LEvent.Data.fd := Integer(ASock);
  Result := epoll_ctl(FEpollFd, EPOLL_CTL_ADD, Integer(ASock), @LEvent) = 0;
  if Result then
    FEvents.AddOrSetValue(ASock, AEvents);
end;

procedure TNghttp2EngineLoop.UnregisterFd(ASock: TSocketHandle);
var
  LEvent: TEpollEvent;
begin
  FillChar(LEvent, SizeOf(LEvent), 0);
  // Pre-2.6.9 kernels reject a nil event pointer; a dummy is the portable form.
  epoll_ctl(FEpollFd, EPOLL_CTL_DEL, Integer(ASock), @LEvent);
  FEvents.Remove(ASock);
end;

procedure TNghttp2EngineLoop.AcceptReady;
var
  LSock: TSocketHandle;
  LPeer: string;
begin
  { Drain the accept queue. The listener is level-triggered, so stopping after
    one would still make progress — but each epoll_wait round trip costs a
    syscall, and under load there are usually several waiting. }
  repeat
    if FListener = INVALID_SOCKET_HANDLE then Exit;
    LSock := AcceptConnection(FListener, LPeer);
    if LSock = INVALID_SOCKET_HANDLE then Exit;   // EAGAIN, or listener closed

    if FServer.AtConnectionLimit then
    begin
      // Refuse rather than accept work the process cannot staff. A closed
      // socket gives the client a clean error to retry on; leaving it open
      // and unserviced looks like a hang.
      ShutdownSocketHandle(LSock);
      Continue;
    end;

    AdmitSocket(LSock, LPeer);
  until False;
end;

procedure TNghttp2EngineLoop.AdmitSocket(ASock: TSocketHandle;
  const APeerAddr: string);
var
  LPump: TNghttp2ConnectionPump;
begin
  LPump := TNghttp2ConnectionPump.Create(FServer, ASock, APeerAddr);
  try
    LPump.NonBlocking := True;
    // Before Setup, so a response staged by the very first request cannot
    // beat the hook into place. Wake is thread-safe (one eventfd write).
    LPump.SetWakeProc(Wake);
    if not LPump.Setup then
    begin
      LPump.Free;
      ShutdownSocketHandle(ASock);
      Exit;
    end;
  except
    // One bad connection must never take the loop down with it.
    LPump.Free;
    ShutdownSocketHandle(ASock);
    Exit;
  end;

  if not RegisterFd(ASock, EPOLLIN or EPOLLRDHUP) then
  begin
    LPump.Free;
    ShutdownSocketHandle(ASock);
    Exit;
  end;

  FPumps.AddOrSetValue(ASock, LPump);
  // Setup's SETTINGS flush may already be held behind a full send buffer, so
  // ask for writability before the first event arrives.
  UpdateInterest(ASock, LPump);
end;

procedure TNghttp2EngineLoop.HandOff(ASock: TSocketHandle;
  const APeerAddr: string);
var
  LItem: TPendingAccept;
begin
  { Fallback path only — used when the server owns the listener. Runs on the
    ACCEPT thread, so it must not touch a pump: building one creates the
    nghttp2 session, and that belongs to this loop's thread from the moment it
    exists. Queue the raw socket and poke the loop. }
  LItem.Sock     := ASock;
  LItem.PeerAddr := APeerAddr;
  FQueueLock.Enter;
  try
    FQueue.Add(LItem);
  finally
    FQueueLock.Leave;
  end;
  Wake;
end;

procedure TNghttp2EngineLoop.AdmitPending;
var
  LBatch: TArray<TPendingAccept>;
  I: Integer;
begin
  FQueueLock.Enter;
  try
    if FQueue.Count = 0 then Exit;
    LBatch := FQueue.ToArray;
    FQueue.Clear;
  finally
    FQueueLock.Leave;
  end;
  for I := 0 to High(LBatch) do
    AdmitSocket(LBatch[I].Sock, LBatch[I].PeerAddr);
end;

procedure TNghttp2EngineLoop.UpdateInterest(ASock: TSocketHandle;
  APump: TNghttp2ConnectionPump);
var
  LWanted, LCurrent: Cardinal;
  LEvent: TEpollEvent;
begin
  { Level-triggered, deliberately. Edge-triggered is fewer syscalls but demands
    every ready fd be drained to EAGAIN on pain of a silent stall, and RunOnce
    reads once per call by design.

    EPOLLOUT ONLY while output is held. Registered permanently under
    level-triggering, epoll_wait returns instantly whenever a socket is
    writable — which is nearly always — and the loop spins a core while still
    serving traffic correctly. }
  LWanted := EPOLLIN or EPOLLRDHUP;
  if APump.WantsWritable then
    LWanted := LWanted or EPOLLOUT;

  if not FEvents.TryGetValue(ASock, LCurrent) then Exit;
  if LCurrent = LWanted then Exit;   // no syscall unless it actually changed

  FillChar(LEvent, SizeOf(LEvent), 0);
  LEvent.Events  := LWanted;
  LEvent.Data.fd := Integer(ASock);
  if epoll_ctl(FEpollFd, EPOLL_CTL_MOD, Integer(ASock), @LEvent) = 0 then
    FEvents.AddOrSetValue(ASock, LWanted);
end;

procedure TNghttp2EngineLoop.ServiceConnection(ASock: TSocketHandle;
  AEvents: Cardinal);
var
  LPump:  TNghttp2ConnectionPump;
  LStep:  TNghttp2PumpStep;
  LGuard: Integer;
begin
  if not FPumps.TryGetValue(ASock, LPump) then
  begin
    UnregisterFd(ASock);   // event for an fd we no longer own
    Exit;
  end;

  if (AEvents and (EPOLLERR or EPOLLHUP)) <> 0 then
  begin
    RetireConnection(ASock, False);   // no farewell is deliverable
    Exit;
  end;

  try
    LStep := LPump.RunOnce;
  except
    RetireConnection(ASock, False);
    Exit;
  end;

  case LStep of
    psAbort: begin RetireConnection(ASock, False); Exit; end;
    psStop:  begin RetireConnection(ASock, True);  Exit; end;
  end;

  { Keep going while OpenSSL still holds readable bytes.

    epoll reports the SOCKET. After a large TLS record is drained off it the
    socket is empty while OpenSSL still buffers most of the request, so
    waiting for the next EPOLLIN waits forever — the request never completes
    and the client hangs with the server believing it has flushed everything.
    That is exactly what stalled the 64 KB body check.

    Bounded, because a connection with a lot buffered must not monopolise a
    loop that is serving thousands of others. Whatever is left after the cap
    is picked up by SweepAndPublish, which sees it because Idle counts
    buffered input as work outstanding. }
  LGuard := 0;
  while LPump.HasBufferedInput and (LGuard < MAX_BUFFERED_PASSES) do
  begin
    Inc(LGuard);
    try
      LStep := LPump.RunOnce;
    except
      RetireConnection(ASock, False);
      Exit;
    end;
    case LStep of
      psAbort: begin RetireConnection(ASock, False); Exit; end;
      psStop:  begin RetireConnection(ASock, True);  Exit; end;
    end;
  end;

  if LPump.Finished then
  begin
    RetireConnection(ASock, True);
    Exit;
  end;

  UpdateInterest(ASock, LPump);
end;

procedure TNghttp2EngineLoop.RetireConnection(ASock: TSocketHandle;
  ASendFarewell: Boolean);
var
  LPump: TNghttp2ConnectionPump;
begin
  if not FPumps.TryGetValue(ASock, LPump) then
  begin
    UnregisterFd(ASock);
    ShutdownSocketHandle(ASock);
    Exit;
  end;

  if ASendFarewell then
    try
      // Best effort — the pump decides whether a farewell is owed (a no-op
      // outside a drain), and non-blocking cannot guarantee it reaches the
      // wire before the socket closes.
      LPump.SendFarewell;
    except
      // Never let a teardown failure escape into the loop.
    end;

  UnregisterFd(ASock);
  FPumps.Remove(ASock);
  LPump.Free;               // may wait on a wedged worker — same contract as
                            // the thread driver's finally block
  ShutdownSocketHandle(ASock);
end;

procedure TNghttp2EngineLoop.SweepAndPublish;
var
  LKeys: TArray<TSocketHandle>;
  I:     Integer;
  LPump: TNghttp2ConnectionPump;
begin
  { A worker finishing its handler stages a response and signals the session's
    own event — which makes no socket readable, because the client is waiting
    on us and sending nothing. The wake hook covers the case where the worker
    pokes this loop; this sweep covers anything it missed.

    Only NON-IDLE pumps are serviced. Idle is the overwhelmingly common state
    and servicing those would put a recv syscall per connection per cycle on
    the loop — the exact per-connection cost this engine exists to remove.
    Testing Idle is a few field reads and no syscall.

    Still O(all connections) per cycle. Measured second-order next to loop-
    thread saturation; revisit after N loops, not before. }
  LKeys := FPumps.Keys.ToArray;
  for I := 0 to High(LKeys) do
    if FPumps.TryGetValue(LKeys[I], LPump) and (not LPump.Idle) then
      ServiceConnection(LKeys[I], 0);

  PublishCounters;
end;

procedure TNghttp2EngineLoop.PublishCounters;
var
  LPair: TPair<TSocketHandle, TNghttp2ConnectionPump>;
  LIdle: Boolean;
begin
  { The graceful-shutdown accessors run on the CALLER's thread and must not
    walk FPumps, which belongs to this loop. Publish two integers instead.

    Idle means what it does for the thread driver: nothing owed. Held output
    counts — bytes in the pump's buffer are owed to the peer even when nghttp2
    has finished. }
  LIdle := True;
  for LPair in FPumps do
    if not (LPair.Value.Idle and (not LPair.Value.WantsWritable)) then
    begin
      LIdle := False;
      Break;
    end;

  TInterlocked.Exchange(FLiveCount, FPumps.Count);
  if LIdle then TInterlocked.Exchange(FIdleFlag, 1)
           else TInterlocked.Exchange(FIdleFlag, 0);
end;

function TNghttp2EngineLoop.LiveConnections: Integer;
begin
  Result := TInterlocked.CompareExchange(FLiveCount, 0, 0);
end;

function TNghttp2EngineLoop.AllIdle: Boolean;
begin
  Result := TInterlocked.CompareExchange(FIdleFlag, 0, 0) <> 0;
end;

procedure TNghttp2EngineLoop.RunLoop;
var
  LEvents: array[0..MAX_EVENTS - 1] of TEpollEvent;
  LCount, I, LFd: Integer;
  LKeys: TArray<TSocketHandle>;
begin
  while not IsStopping do
  begin
    LCount := epoll_wait(FEpollFd, @LEvents[0], MAX_EVENTS, LOOP_TIMEOUT_MS);

    if LCount < 0 then
    begin
      // EINTR is routine. Anything else on the epoll fd itself is not
      // recoverable from in here.
      if SocketLastErrorIsWouldBlock then Continue;
      Break;
    end;

    for I := 0 to LCount - 1 do
    begin
      LFd := LEvents[I].Data.fd;
      if LFd = FWakeFd then
      begin
        DrainWakeFd;
        Continue;
      end;
      if (FListener <> INVALID_SOCKET_HANDLE) and (LFd = Integer(FListener)) then
      begin
        AcceptReady;
        Continue;
      end;
      ServiceConnection(TSocketHandle(LFd), LEvents[I].Events);
    end;

    // Fallback handoffs, after servicing, so a connection queued mid-cycle is
    // admitted this turn rather than waiting for the next.
    if not FOwnsAccept then
      AdmitPending;

    SweepAndPublish;
  end;

  // Tear down everything this thread owns, on this thread.
  LKeys := FPumps.Keys.ToArray;
  for I := 0 to High(LKeys) do
    RetireConnection(LKeys[I], True);
  PublishCounters;
end;

// ─── TNghttp2EpollEngine ─────────────────────────────────────────────────

constructor TNghttp2EpollEngine.Create(AServer: TNghttp2Server);
var
  N, I: Integer;
begin
  inherited Create;
  FServer := AServer;
  FNext   := 0;

  { SO_REUSEPORT is what makes N loops worth having: without it they would all
    need feeding from one accept thread through a lock, which is the shared
    bottleneck this design exists to remove. It is Linux-only, and this unit
    only compiles on Linux, so owning accept is the normal case here. }
  FOwnsAccept := True;

  { TLS runs on the loop as of B4d. The pump drives HandshakeStep from RunOnce
    a step per wake, reads through ReadNB and encrypts through WriteNB, and
    reports want-write through WantsWritable — which is all this engine needs,
    since EPOLLIN is registered permanently and only the want-write direction
    has to be expressed.

    Before that wiring existed this constructor forced FOwnsAccept := False
    for any TLS listener, because Setup called the BLOCKING DoHandshake and a
    single slow peer would have stalled every connection sharing its loop. }

  N := AServer.EngineThreads;
  if N <= 0 then
    N := Nghttp2CpuCount;
  if N < 1 then N := 1;
  { Cap it. Past the core count the loops contend for the same CPUs while each
    still carries its own epoll set and per-cycle sweep, so more threads buy
    nothing and cost cache. }
  if N > Nghttp2CpuCount then
    N := Nghttp2CpuCount;

  SetLength(FLoops, N);
  for I := 0 to N - 1 do
    FLoops[I] := TNghttp2EngineLoop.Create(Self, AServer, I, FOwnsAccept);
end;

destructor TNghttp2EpollEngine.Destroy;
var
  I: Integer;
begin
  Stop;
  for I := 0 to High(FLoops) do
    FLoops[I].Free;
  SetLength(FLoops, 0);
  inherited;
end;

function TNghttp2EpollEngine.LoopCount: Integer;
begin
  Result := Length(FLoops);
end;

function TNghttp2EpollEngine.DriverName: string;
begin
  Result := 'epoll event loop';
end;

function TNghttp2EpollEngine.OwnsAccept: Boolean;
begin
  Result := FOwnsAccept;
end;

procedure TNghttp2EpollEngine.Start;
var
  I: Integer;
begin
  for I := 0 to High(FLoops) do
    FLoops[I].Start;
end;

procedure TNghttp2EpollEngine.Stop;
var
  I: Integer;
begin
  for I := 0 to High(FLoops) do
    FLoops[I].Stop;
end;

procedure TNghttp2EpollEngine.StopAccepting;
var
  I: Integer;
begin
  for I := 0 to High(FLoops) do
    FLoops[I].StopAccepting;
end;

procedure TNghttp2EpollEngine.CloseAll;
var
  I: Integer;
begin
  { Called from the server's hard cutoff, on another thread. Do NOT touch a
    loop's pumps here — raise its stop flag and let it tear its own
    connections down, which is the only thread allowed to. Stop then joins. }
  for I := 0 to High(FLoops) do
  begin
    TInterlocked.Exchange(FLoops[I].FStopping, 1);
    FLoops[I].Wake;
  end;
end;

procedure TNghttp2EpollEngine.HandOff(ASock: TSocketHandle;
  const APeerAddr: string);
var
  LIdx: Integer;
begin
  // Fallback path only. Round-robin; the kernel does this for us when
  // SO_REUSEPORT is in play.
  if LoopCount = 0 then
  begin
    ShutdownSocketHandle(ASock);
    Exit;
  end;
  LIdx  := TInterlocked.Increment(FNext);
  FLoops[Abs(LIdx) mod LoopCount].HandOff(ASock, APeerAddr);
end;

function TNghttp2EpollEngine.LiveConnections: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FLoops) do
    Inc(Result, FLoops[I].LiveConnections);
end;

function TNghttp2EpollEngine.AllIdle: Boolean;
var
  I: Integer;
begin
  // Every loop must be idle. One busy loop is a connection still owed a
  // response, and the drain must not declare victory over it.
  for I := 0 to High(FLoops) do
    if not FLoops[I].AllIdle then
      Exit(False);
  Result := True;
end;

// ─── Registration ────────────────────────────────────────────────────────

function CreateEpollEngine(AServer: TNghttp2Server): INghttp2Engine;
begin
  Result := TNghttp2EpollEngine.Create(AServer);
end;

{$IFEND}

initialization
{$IF DEFINED(LINUX)}
  { Linking this unit is what makes UseEventLoop mean anything. Nghttp2.Server
    holds only the function pointer, so it never references this unit and the
    dependency stays one-way. }
  Nghttp2EngineFactory := CreateEpollEngine;
{$IFEND}

finalization
{$IF DEFINED(LINUX)}
  Nghttp2EngineFactory := nil;
{$IFEND}

end.
