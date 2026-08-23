unit Nghttp2.Engine.Iocp;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Nghttp2.Engine.Iocp — IOCP event-loop driver for Windows.
//
//  The Windows counterpart to Nghttp2.Engine.Epoll. Same contract
//  (INghttp2Engine), same opt-in (TNghttp2Config.UseEventLoop), same
//  registration trick: nothing references this unit, so LINKING it is what
//  enables it and the dependency stays one-way. On any non-Windows target the
//  whole unit compiles to nothing.
//
//  ── The design decision, and why it is not what the plan assumed ──
//
//  epoll is READINESS-based ("this socket can be read") and IOCP is
//  COMPLETION-based ("this read you posted has finished"). The plan therefore
//  expected IOCP to need its own buffer-ownership design: post a real buffer,
//  receive bytes into engine-owned memory, and inject them into the pump
//  through a new seam.
//
//  It does not, because of the ZERO-BYTE RECEIVE pattern. A WSARecv posted
//  with a zero-length buffer transfers nothing; its completion means only
//  "data has arrived". That is a readiness edge, which is exactly what the
//  pump already consumes — so on completion we call the pump and its DoRead
//  reads the socket through SocketRecvNB, unchanged.
//
//  What that buys, and it is the whole reason for the choice:
//
//    * TNghttp2ConnectionPump is reused VERBATIM. Not adapted — verbatim.
//      That pump carries the TLS state machine, the async dispatch handshake,
//      the two-stage GOAWAY and the high-water gate, all validated across 20
//      stages on three compilers. A second input path through it would be new
//      code on the one component least able to afford it.
//    * No buffer lifetime problem. Engine-owned receive buffers outliving
//      their completions is the classic IOCP defect, and there are none here.
//
//  The cost is one extra completion per read — two syscalls where overlapped
//  buffers need one. That is a real cost and it is deliberately unmeasured:
//  measure it against the thread driver on Windows first, and only pay for
//  overlapped buffers if the number justifies it. Optimising ahead of the
//  measurement is what produced the 22.3x figure, the TLS ceiling and the
//  "lost requests" claim, each of which later needed retracting.
//
//  ── Two structural differences from the epoll engine ──
//
//  1. N COMPLETION PORTS, ONE PER LOOP THREAD — not one shared port serviced
//     by N threads, which is the more idiomatic Windows arrangement.
//
//     The pump may only ever be touched by the thread that drives it. A
//     shared port hands each completion to whichever thread is free, so a
//     connection would be serviced by thread A now and thread B later. With
//     one outstanding operation per direction that is never CONCURRENT, and
//     the completion does carry a memory barrier — but "not concurrent" and
//     "same thread" are different guarantees, and the pump was written and
//     validated against the stronger one. A private port per loop keeps the
//     invariant identical to the epoll engine, at the cost of the kernel's
//     load balancing. Revisit only with a measurement.
//
//  2. OwnsAccept = False. Windows has no SO_REUSEPORT that load-balances
//     accepts across listeners the way Linux does; SO_REUSEADDR has entirely
//     different semantics and would let an unrelated process steal the port.
//     So this engine takes the fallback the interface already documents:
//     the server keeps its listener and accept thread, and hands sockets over
//     through HandOff. AcceptEx would allow engine-owned accepts later; it is
//     not needed to make the driver work and would add a second overlapped
//     path before the first one has been measured.
//
//  ── Imports are declared locally, on purpose ──
//
//  CreateIoCompletionPort/GetQueuedCompletionStatus/WSARecv/WSASend are bound
//  here by name rather than taken from Winapi.Windows / Winapi.WinSock2 /
//  FPC's WinSock2. Those units expose different subsets across compilers and
//  versions — stock Winapi.WinSock2 already declares FD_SET as a record TYPE
//  rather than the macro every example uses, and finding that out costs a
//  build round. Binding what this unit needs makes it independent of which
//  RTL is present, which matters most for the code that cannot be compiled
//  where it is written.
// ============================================================================

interface

{$IF DEFINED(MSWINDOWS)}

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, SyncObjs, Windows, Generics.Collections,
{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs, Winapi.Windows,
  System.Generics.Collections,
{$IFEND}
  Nghttp2.Compat,   { TInterlocked shim for FPC < 3.3.1 — no-op elsewhere }
  Nghttp2.Socket,
  Nghttp2.Server;

type
  TNghttp2IocpLoop = class;

  { One connection: its socket, its pump, and the two OVERLAPPED structures
    that carry its readiness probes.

    The OVERLAPPEDs are FIELDS, not locals. The kernel writes to them when the
    operation completes, so they must outlive the call that posted them — a
    stack OVERLAPPED is the other classic IOCP defect, and it corrupts memory
    rather than failing cleanly. The object lives until its connection retires,
    and retirement waits for both operations to have completed. }
  TNghttp2IocpConn = class
  private
    FSock:      TSocketHandle;
    FPump:      TNghttp2ConnectionPump;
    FLoop:      TNghttp2IocpLoop;
    FPeerAddr:  string;

    FReadOvl:   TOverlapped;
    FWriteOvl:  TOverlapped;
    FReadPosted:  Boolean;
    FWritePosted: Boolean;
    FClosing:     Boolean;
  public
    constructor Create(ALoop: TNghttp2IocpLoop; ASock: TSocketHandle;
      const APeerAddr: string);
    destructor Destroy; override;

    // Arm the readiness probes. Zero-byte, so nothing is transferred.
    function PostRead: Boolean;
    function PostWrite: Boolean;

    // True while the kernel still owns either OVERLAPPED. Retiring before
    // this goes False frees memory the kernel is about to write to.
    function HasPendingOps: Boolean;

    property Sock: TSocketHandle read FSock;
    property Pump: TNghttp2ConnectionPump read FPump;
    property Closing: Boolean read FClosing write FClosing;
  end;

  TNghttp2IocpLoopThread = class(TThread)
  private
    FLoop: TNghttp2IocpLoop;
  protected
    procedure Execute; override;
  public
    constructor Create(ALoop: TNghttp2IocpLoop);
  end;

  TNghttp2IocpLoop = class
  private
    FEngine:    TObject;
    FServer:    TNghttp2Server;
    FIndex:     Integer;
    FIocp:      THandle;
    FThread:    TNghttp2IocpLoopThread;
    FStopping:  Integer;          // 0/1 via TInterlocked

    FConns:     TObjectList<TNghttp2IocpConn>;

    // Sockets handed over by the accept thread, waiting to be adopted by the
    // loop thread. Same reason as the epoll engine: a pump may only be built
    // and touched by the thread that will drive it.
    FPendingLock: TCriticalSection;
    FPendingSock: TList<TSocketHandle>;
    FPendingAddr: TStringList;

    FLiveCount: Integer;          // published for LiveConnections
    FIdleCount: Integer;

    // Connections retired but not yet freed, because the kernel still owns an
    // OVERLAPPED inside them. Lets SweepClosing skip its O(n) walk entirely in
    // the overwhelmingly common case of nothing closing — see FIX-IOCP-SWEEP-2.
    FClosingCount: Integer;

    function  IsStopping: Boolean;
    procedure AdmitPending;
    procedure AdmitSocket(ASock: TSocketHandle; const APeerAddr: string);
    procedure ServiceConnection(AConn: TNghttp2IocpConn);
    procedure RetireConnection(AConn: TNghttp2IocpConn;
      ASendFarewell: Boolean);
    procedure UpdateInterest(AConn: TNghttp2IocpConn);
    procedure PublishCounters;
    procedure SweepClosing;
  public
    constructor Create(AEngine: TObject; AServer: TNghttp2Server;
      AIndex: Integer);
    destructor Destroy; override;

    procedure Start;
    procedure Stop;
    procedure Wake;
    procedure RunLoop;

    procedure HandOff(ASock: TSocketHandle; const APeerAddr: string);
    procedure CloseAll;
    function  LiveConnections: Integer;
    function  AllIdle: Boolean;

    property Iocp: THandle read FIocp;
  end;

  TNghttp2IocpEngine = class(TInterfacedObject, INghttp2Engine)
  private
    FServer:         TNghttp2Server;
    FLoops:          array of TNghttp2IocpLoop;
    FNext:           Integer;   // round-robin cursor for HandOff
    FTimerPeriodSet: Boolean;   // True if timeBeginPeriod(1) succeeded in Start
    function LoopCount: Integer;
  public
    constructor Create(AServer: TNghttp2Server);
    destructor Destroy; override;

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

{$IFEND}

implementation

{$IF DEFINED(MSWINDOWS)}

const
  { Completion keys. The connection pointer is the key for socket operations,
    so a completion needs no lookup; these two are sentinels that cannot
    collide with a heap pointer. }
  IOCP_KEY_WAKE = ULONG_PTR(1);
  IOCP_KEY_STOP = ULONG_PTR(2);

  // GetQueuedCompletionStatus timeout. Not a poll interval — completions wake
  // the loop immediately. This only bounds how long a stopping loop waits
  // before noticing, and how often SweepClosing runs.
  IOCP_WAIT_MS = 50;

  WSA_IO_PENDING_ = 997;   // ERROR_IO_PENDING
  TIMERR_NOERROR  = 0;     // timeBeginPeriod success

type
  TWsaBufRec = record
    len: ULONG;
    buf: PAnsiChar;
  end;
  PWsaBufRec = ^TWsaBufRec;

{ Bound by name rather than imported — see the unit header. }
function IocpCreate(FileHandle: THandle; ExistingCompletionPort: THandle;
  CompletionKey: ULONG_PTR; NumberOfConcurrentThreads: DWORD): THandle; stdcall;
  external 'kernel32.dll' name 'CreateIoCompletionPort';

function IocpGetStatus(CompletionPort: THandle;
  var lpNumberOfBytes: DWORD; var lpCompletionKey: ULONG_PTR;
  var lpOverlapped: POverlapped; dwMilliseconds: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'GetQueuedCompletionStatus';

function IocpPostStatus(CompletionPort: THandle; dwNumberOfBytesTransferred: DWORD;
  dwCompletionKey: ULONG_PTR; lpOverlapped: POverlapped): BOOL; stdcall;
  external 'kernel32.dll' name 'PostQueuedCompletionStatus';

function WsaRecvOvl(s: TSocketHandle; lpBuffers: PWsaBufRec;
  dwBufferCount: DWORD; var lpNumberOfBytesRecvd: DWORD; var lpFlags: DWORD;
  lpOverlapped: POverlapped; lpCompletionRoutine: Pointer): Integer; stdcall;
  external 'ws2_32.dll' name 'WSARecv';

function WsaSendOvl(s: TSocketHandle; lpBuffers: PWsaBufRec;
  dwBufferCount: DWORD; var lpNumberOfBytesSent: DWORD; dwFlags: DWORD;
  lpOverlapped: POverlapped; lpCompletionRoutine: Pointer): Integer; stdcall;
  external 'ws2_32.dll' name 'WSASend';

function WsaGetLastErr: Integer; stdcall;
  external 'ws2_32.dll' name 'WSAGetLastError';

{ Windows multimedia timer resolution. Without timeBeginPeriod(1) the scheduler
  fires at 15.6 ms intervals — waking a sleeping TEvent worker thread can cost
  up to 15.6 ms per dispatch, which caps throughput to ~1100 req/s regardless
  of how many cores or IOCP loops are in play. 1 ms resolution moves that
  ceiling to ~28 000 dispatches/s and also reduces AdmitSocket latency under
  burst-connect loads (the 1000-connection failure). Bound by name to stay
  independent of the Multimedia units across compiler versions. }
function TimerBeginPeriod(uPeriod: UINT): UINT; stdcall;
  external 'winmm.dll' name 'timeBeginPeriod';
function TimerEndPeriod(uPeriod: UINT): UINT; stdcall;
  external 'winmm.dll' name 'timeEndPeriod';

// ─── TNghttp2IocpConn ───────────────────────────────────────────────────────

constructor TNghttp2IocpConn.Create(ALoop: TNghttp2IocpLoop;
  ASock: TSocketHandle; const APeerAddr: string);
begin
  inherited Create;
  FLoop     := ALoop;
  FSock     := ASock;
  FPeerAddr := APeerAddr;
  FPump     := TNghttp2ConnectionPump.Create(ALoop.FServer, ASock, APeerAddr);
end;

destructor TNghttp2IocpConn.Destroy;
begin
  FPump.Free;
  inherited;
end;

function TNghttp2IocpConn.HasPendingOps: Boolean;
begin
  Result := FReadPosted or FWritePosted;
end;

function TNghttp2IocpConn.PostRead: Boolean;
var
  LBuf:   TWsaBufRec;
  LBytes: DWORD;
  LFlags: DWORD;
  LRc:    Integer;
begin
  if FReadPosted or FClosing then Exit(True);

  FillChar(FReadOvl, SizeOf(FReadOvl), 0);
  // Zero LENGTH is the whole point: this transfers nothing and exists only so
  // its completion signals "readable". buf must still be non-nil for some
  // Winsock providers, so it points at the (unused) length field's address.
  LBuf.len := 0;
  LBuf.buf := PAnsiChar(@FReadOvl);
  LBytes := 0;
  LFlags := 0;

  LRc := WsaRecvOvl(FSock, @LBuf, 1, LBytes, LFlags, @FReadOvl, nil);
  if (LRc = 0) or (WsaGetLastErr = WSA_IO_PENDING_) then
  begin
    // Note both branches post: a zero-byte recv can complete INLINE (rc=0)
    // and still queue a completion packet, because the socket was associated
    // with the port without FILE_SKIP_COMPLETION_PORT_ON_SUCCESS. Treating
    // inline success as "no completion coming" would leak the flag and stall
    // the connection permanently.
    FReadPosted := True;
    Exit(True);
  end;
  Result := False;
end;

function TNghttp2IocpConn.PostWrite: Boolean;
var
  LBuf:   TWsaBufRec;
  LBytes: DWORD;
  LRc:    Integer;
begin
  if FWritePosted or FClosing then Exit(True);

  FillChar(FWriteOvl, SizeOf(FWriteOvl), 0);
  LBuf.len := 0;
  LBuf.buf := PAnsiChar(@FWriteOvl);
  LBytes := 0;

  // A zero-byte send completes when the socket can accept data — the IOCP
  // equivalent of EPOLLOUT, which has no direct completion-model analogue.
  LRc := WsaSendOvl(FSock, @LBuf, 1, LBytes, 0, @FWriteOvl, nil);
  if (LRc = 0) or (WsaGetLastErr = WSA_IO_PENDING_) then
  begin
    FWritePosted := True;
    Exit(True);
  end;
  Result := False;
end;

// ─── TNghttp2IocpLoopThread ─────────────────────────────────────────────────

constructor TNghttp2IocpLoopThread.Create(ALoop: TNghttp2IocpLoop);
begin
  FLoop := ALoop;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TNghttp2IocpLoopThread.Execute;
begin
  FLoop.RunLoop;
end;

// ─── TNghttp2IocpLoop ───────────────────────────────────────────────────────

constructor TNghttp2IocpLoop.Create(AEngine: TObject; AServer: TNghttp2Server;
  AIndex: Integer);
begin
  inherited Create;
  FEngine := AEngine;
  FServer := AServer;
  FIndex  := AIndex;
  FIocp   := 0;
  FConns  := TObjectList<TNghttp2IocpConn>.Create(True);
  FPendingLock := TCriticalSection.Create;
  FPendingSock := TList<TSocketHandle>.Create;
  FPendingAddr := TStringList.Create;
end;

destructor TNghttp2IocpLoop.Destroy;
begin
  Stop;
  FConns.Free;
  FPendingSock.Free;
  FPendingAddr.Free;
  FPendingLock.Free;
  if FIocp <> 0 then CloseHandle(FIocp);
  inherited;
end;

function TNghttp2IocpLoop.IsStopping: Boolean;
begin
  Result := TInterlocked.CompareExchange(FStopping, 0, 0) <> 0;
end;

procedure TNghttp2IocpLoop.Start;
begin
  // NumberOfConcurrentThreads = 1: this port is serviced by exactly one
  // thread, which is what keeps a pump on a single thread. See header note 1.
  FIocp := IocpCreate(INVALID_HANDLE_VALUE, 0, 0, 1);
  if FIocp = 0 then
    raise Exception.CreateFmt(
      'IOCP engine: CreateIoCompletionPort failed (%d)', [GetLastError]);
  FThread := TNghttp2IocpLoopThread.Create(Self);
end;

procedure TNghttp2IocpLoop.Stop;
begin
  if TInterlocked.Exchange(FStopping, 1) <> 0 then Exit;
  if FIocp <> 0 then
    IocpPostStatus(FIocp, 0, IOCP_KEY_STOP, nil);
  if FThread <> nil then
  begin
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
end;

procedure TNghttp2IocpLoop.Wake;
begin
  // The counterpart of the epoll engine's eventfd write: a worker that has
  // staged a response must be able to poke a loop parked in
  // GetQueuedCompletionStatus. Without it the reply waits for the timeout,
  // which cost the epoll engine 2.8x before it was noticed.
  if FIocp <> 0 then
    IocpPostStatus(FIocp, 0, IOCP_KEY_WAKE, nil);
end;

procedure TNghttp2IocpLoop.HandOff(ASock: TSocketHandle; const APeerAddr: string);
begin
  FPendingLock.Enter;
  try
    FPendingSock.Add(ASock);
    FPendingAddr.Add(APeerAddr);
  finally
    FPendingLock.Leave;
  end;
  Wake;
end;

procedure TNghttp2IocpLoop.AdmitPending;
var
  LSocks: array of TSocketHandle;
  LAddrs: array of string;
  I: Integer;
begin
  FPendingLock.Enter;
  try
    if FPendingSock.Count = 0 then Exit;
    SetLength(LSocks, FPendingSock.Count);
    SetLength(LAddrs, FPendingSock.Count);
    for I := 0 to FPendingSock.Count - 1 do
    begin
      LSocks[I] := FPendingSock[I];
      LAddrs[I] := FPendingAddr[I];
    end;
    FPendingSock.Clear;
    FPendingAddr.Clear;
  finally
    FPendingLock.Leave;
  end;

  // Outside the lock: building a pump runs application-visible code and must
  // not happen while the accept thread could be blocked behind us.
  for I := 0 to High(LSocks) do
    AdmitSocket(LSocks[I], LAddrs[I]);
end;

procedure TNghttp2IocpLoop.AdmitSocket(ASock: TSocketHandle;
  const APeerAddr: string);
var
  LConn: TNghttp2IocpConn;
begin
  if FServer.AtConnectionLimit then
  begin
    ShutdownSocketHandle(ASock);
    Exit;
  end;

  if not SetSocketNonBlocking(ASock, True) then
  begin
    ShutdownSocketHandle(ASock);
    Exit;
  end;

  LConn := TNghttp2IocpConn.Create(Self, ASock, APeerAddr);
  try
    LConn.Pump.NonBlocking := True;
    // Before Setup, so a response staged by the very first request cannot
    // beat the hook into place.
    LConn.Pump.SetWakeProc(Wake);
    if not LConn.Pump.Setup then
    begin
      LConn.Free;
      ShutdownSocketHandle(ASock);
      Exit;
    end;
  except
    LConn.Free;
    ShutdownSocketHandle(ASock);
    raise;
  end;

  // Associate AFTER Setup: Setup may write the initial SETTINGS, and a
  // completion arriving mid-Setup would service a half-built pump.
  if IocpCreate(THandle(ASock), FIocp, ULONG_PTR(LConn), 0) = 0 then
  begin
    LConn.Free;
    ShutdownSocketHandle(ASock);
    Exit;
  end;

  FConns.Add(LConn);
  if not LConn.PostRead then
  begin
    RetireConnection(LConn, False);
    Exit;
  end;
  UpdateInterest(LConn);
  PublishCounters;
end;

procedure TNghttp2IocpLoop.UpdateInterest(AConn: TNghttp2IocpConn);
begin
  if AConn.Closing then Exit;
  // Read interest is permanent, exactly as EPOLLIN is in the epoll engine.
  AConn.PostRead;
  // Write interest only while the pump has something it could not flush —
  // a standing zero-byte send would complete immediately and spin the loop.
  if AConn.Pump.WantsWritable then
    AConn.PostWrite;
end;

procedure TNghttp2IocpLoop.ServiceConnection(AConn: TNghttp2IocpConn);
var
  LStep:   TNghttp2PumpStep;
  LPasses: Integer;
begin
  if AConn.Closing then Exit;

  LPasses := 0;
  repeat
    try
      LStep := AConn.Pump.RunOnce;
    except
      // Never let a pump exception escape into the loop: one bad connection
      // would take down every other connection this loop owns.
      RetireConnection(AConn, False);
      Exit;
    end;
    Inc(LPasses);

    { psStop and psAbort are NOT interchangeable and collapsing them changes
      shutdown behaviour on a path no suite covers — the same warning carried
      on TNghttp2PumpStep itself. psStop means "leave, THEN send the farewell
      GOAWAY"; psAbort means the connection is already unusable and a farewell
      would be written into a dead socket. }
    if LStep = psStop then
    begin
      RetireConnection(AConn, True);
      Exit;
    end;
    if LStep = psAbort then
    begin
      RetireConnection(AConn, False);
      Exit;
    end;

    // Same hazard the epoll engine hit with TLS: the readiness signal
    // describes the SOCKET, while OpenSSL may hold whole records behind it.
    // One RunOnce per completion would strand those bytes until the peer
    // sent more, which under TLS it may never do.
  until (not AConn.Pump.HasBufferedInput) or (LPasses >= 32);

  UpdateInterest(AConn);
end;

procedure TNghttp2IocpLoop.RetireConnection(AConn: TNghttp2IocpConn;
  ASendFarewell: Boolean);
begin
  if AConn.Closing then Exit;
  AConn.Closing := True;
  // Paired with the subtraction in SweepClosing. The early exit above makes
  // this exactly one increment per connection. Interlocked because CloseAll
  // can reach here from the shutdown caller's thread.
  TInterlocked.Increment(FClosingCount);

  if ASendFarewell then
    try
      // Best effort — the pump decides whether a farewell is owed (a no-op
      // outside a drain), and non-blocking cannot guarantee it reaches the
      // wire before the socket closes.
      AConn.Pump.SendFarewell;
    except
      // A teardown failure must never escape into the loop.
    end;
  // Close the socket first: it cancels both outstanding operations, which is
  // what lets HasPendingOps drain. Freeing the object while the kernel still
  // owns an OVERLAPPED inside it corrupts memory long after the fact.
  if AConn.FSock <> INVALID_SOCKET_HANDLE then
  begin
    ShutdownSocketHandle(AConn.FSock);
    AConn.FSock := INVALID_SOCKET_HANDLE;
  end;
  // The object is not freed here. SweepClosing frees it once both completion
  // packets have been collected.
  PublishCounters;
end;

procedure TNghttp2IocpLoop.SweepClosing;
var
  I: Integer;
begin
  { FIX-IOCP-SWEEP-2. RunLoop calls this after EVERY completion — i.e. at
    least once per request — and the epoll engine has no equivalent walk at
    all (it frees a pump inline in RetireConnection; the deferred free here
    exists only because the kernel may still own an OVERLAPPED).

    Nothing is closing in steady state, so the counter turns an O(n) walk per
    completion into one integer test.

    Exactly +1 per retire and -1 per free, both interlocked, because
    TNghttp2Server.ForceCloseAllConnections reaches CloseAll on the SHUTDOWN
    caller's thread and a retire can therefore land mid-walk. No update is
    lost, so the count can never read low and strand a closing connection.
    Reading high is harmless — it costs one redundant walk. }
  if TInterlocked.CompareExchange(FClosingCount, 0, 0) <= 0 then Exit;

  for I := FConns.Count - 1 downto 0 do
    if FConns[I].Closing and (not FConns[I].HasPendingOps) then
    begin
      FConns.Delete(I);          // OwnsObjects=True → frees the connection
      TInterlocked.Decrement(FClosingCount);
    end;
end;

procedure TNghttp2IocpLoop.PublishCounters;
var
  I, LLive, LIdle: Integer;
begin
  LLive := 0; LIdle := 0;
  for I := 0 to FConns.Count - 1 do
    if not FConns[I].Closing then
    begin
      Inc(LLive);
      if FConns[I].Pump.Idle then Inc(LIdle);
    end;
  TInterlocked.Exchange(FLiveCount, LLive);
  TInterlocked.Exchange(FIdleCount, LIdle);
end;

function TNghttp2IocpLoop.LiveConnections: Integer;
begin
  Result := TInterlocked.CompareExchange(FLiveCount, 0, 0);
end;

function TNghttp2IocpLoop.AllIdle: Boolean;
begin
  Result := TInterlocked.CompareExchange(FLiveCount, 0, 0)
          = TInterlocked.CompareExchange(FIdleCount, 0, 0);
end;

procedure TNghttp2IocpLoop.CloseAll;
var
  I: Integer;
begin
  for I := 0 to FConns.Count - 1 do
    if not FConns[I].Closing then
      RetireConnection(FConns[I], False);
  Wake;
end;

procedure TNghttp2IocpLoop.RunLoop;
var
  LBytes: DWORD;
  LKey:   ULONG_PTR;
  LOvl:   POverlapped;
  LOk:    BOOL;
  LConn:  TNghttp2IocpConn;
  LIdx:   Integer;   // NOT an inline `for var`: FPC's Delphi mode rejects it
begin
  while not IsStopping do
  begin
    LBytes := 0; LKey := 0; LOvl := nil;
    LOk := IocpGetStatus(FIocp, LBytes, LKey, LOvl, IOCP_WAIT_MS);

    if (not LOk) and (LOvl = nil) then
    begin
      // Timeout, or the port failed. Neither is a connection event; fall
      // through to the housekeeping below.
      AdmitPending;
      SweepClosing;
      Continue;
    end;

    if LKey = IOCP_KEY_STOP then Break;

    if LKey = IOCP_KEY_WAKE then
    begin
      // A worker staged a response, or a socket was handed over.
      AdmitPending;

      { FIX-IOCP-SWEEP-1. Only NON-IDLE connections are serviced — the same
        filter Nghttp2.Engine.Epoll's SweepAndPublish applies, and for the
        same reason. It was missing here.

        A wake carries no indication of WHICH connection it belongs to, so
        walking the list is the only way to find the one holding a staged
        response. But servicing the IDLE ones too costs a recv syscall each
        (RunOnce always attempts a read in non-blocking mode), and a wake is
        posted once PER RESPONSE — so the unfiltered form spent
        O(connections-on-this-loop) syscalls on every single request. That is
        precisely the per-connection cost an event loop exists to remove, and
        it grew with connection count, which is why throughput FELL as
        connections rose (5 170 req/s at c=10 -> 1 131 at c=100).

        Testing Idle is a few field reads and no syscall.

        Connections holding unflushed output are not skipped in error: they
        report WantsWritable, UpdateInterest has already posted a zero-byte
        send for them, and their own write completion services them. }
      for LIdx := FConns.Count - 1 downto 0 do
        if (not FConns[LIdx].Closing) and (not FConns[LIdx].Pump.Idle) then
          ServiceConnection(FConns[LIdx]);

      SweepClosing;
      Continue;
    end;

    LConn := TNghttp2IocpConn(LKey);
    if LConn = nil then Continue;

    // Clear the flag for whichever probe completed BEFORE servicing, so
    // UpdateInterest can re-arm it. Identify by OVERLAPPED address — the
    // connection owns exactly two, so the comparison is unambiguous.
    if LOvl = @LConn.FReadOvl then
      LConn.FReadPosted := False
    else if LOvl = @LConn.FWriteOvl then
      LConn.FWritePosted := False;

    if not LOk then
    begin
      // The operation failed or was cancelled — the socket is going away.
      // A failed or cancelled probe means the socket is gone; no farewell
      // is deliverable into it.
      RetireConnection(LConn, False);
      SweepClosing;
      Continue;
    end;

    ServiceConnection(LConn);
    SweepClosing;
  end;

  // Teardown: retire everything, then wait for the kernel to give back every
  // OVERLAPPED before the objects holding them are freed.
  CloseAll;
  while True do
  begin
    SweepClosing;
    if FConns.Count = 0 then Break;
    LBytes := 0; LKey := 0; LOvl := nil;
    if not IocpGetStatus(FIocp, LBytes, LKey, LOvl, 50) then
      if LOvl = nil then
      begin
        // Nothing left in the queue. Anything still flagged is a completion
        // that will never arrive; clearing the flags lets the sweep finish
        // rather than hanging shutdown on a packet the kernel already
        // discarded with the socket.
        for LIdx := 0 to FConns.Count - 1 do
        begin
          FConns[LIdx].FReadPosted  := False;
          FConns[LIdx].FWritePosted := False;
        end;
        Continue;
      end;
    if LKey > IOCP_KEY_STOP then
    begin
      LConn := TNghttp2IocpConn(LKey);
      if LConn <> nil then
      begin
        if LOvl = @LConn.FReadOvl then LConn.FReadPosted := False
        else if LOvl = @LConn.FWriteOvl then LConn.FWritePosted := False;
      end;
    end;
  end;
end;

// ─── TNghttp2IocpEngine ─────────────────────────────────────────────────────

constructor TNghttp2IocpEngine.Create(AServer: TNghttp2Server);
var
  N, I: Integer;
begin
  inherited Create;
  FServer := AServer;
  N := AServer.EngineThreads;
  if N <= 0 then N := Nghttp2CpuCount;
  if N < 1 then N := 1;
  SetLength(FLoops, N);
  for I := 0 to N - 1 do
    FLoops[I] := TNghttp2IocpLoop.Create(Self, AServer, I);
end;

destructor TNghttp2IocpEngine.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FLoops) do
    FLoops[I].Free;
  SetLength(FLoops, 0);
  // Safety net in case Stop was not called before Destroy.
  if FTimerPeriodSet then
    TimerEndPeriod(1);
  inherited;
end;

function TNghttp2IocpEngine.LoopCount: Integer;
begin
  Result := Length(FLoops);
end;

function TNghttp2IocpEngine.DriverName: string;
begin
  Result := 'IOCP completion port';
end;

function TNghttp2IocpEngine.OwnsAccept: Boolean;
begin
  // See header note 2: no SO_REUSEPORT on Windows, so the server keeps its
  // listener and accept thread and feeds us through HandOff.
  Result := False;
end;

procedure TNghttp2IocpEngine.StopAccepting;
begin
  // Nothing to do — this engine owns no listener. The server closes its own.
end;

procedure TNghttp2IocpEngine.Start;
var
  I: Integer;
begin
  FTimerPeriodSet := TimerBeginPeriod(1) = TIMERR_NOERROR;
  for I := 0 to High(FLoops) do
    FLoops[I].Start;
end;

procedure TNghttp2IocpEngine.Stop;
var
  I: Integer;
begin
  for I := 0 to High(FLoops) do
    FLoops[I].Stop;
  if FTimerPeriodSet then
  begin
    TimerEndPeriod(1);
    FTimerPeriodSet := False;
  end;
end;

procedure TNghttp2IocpEngine.HandOff(ASock: TSocketHandle;
  const APeerAddr: string);
var
  LIdx: Integer;
begin
  if Length(FLoops) = 0 then
  begin
    ShutdownSocketHandle(ASock);
    Exit;
  end;
  // Round-robin. The kernel would spread these itself with a shared port;
  // with one port per loop that job is ours. Interlocked because the accept
  // thread is the only caller today but need not remain so.
  LIdx := TInterlocked.Increment(FNext);
  if LIdx < 0 then LIdx := -LIdx;
  FLoops[LIdx mod Length(FLoops)].HandOff(ASock, APeerAddr);
end;

procedure TNghttp2IocpEngine.CloseAll;
var
  I: Integer;
begin
  for I := 0 to High(FLoops) do
    FLoops[I].CloseAll;
end;

function TNghttp2IocpEngine.LiveConnections: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FLoops) do
    Inc(Result, FLoops[I].LiveConnections);
end;

function TNghttp2IocpEngine.AllIdle: Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FLoops) do
    if not FLoops[I].AllIdle then Exit(False);
  Result := True;
end;

function CreateIocpEngine(AServer: TNghttp2Server): INghttp2Engine;
begin
  Result := TNghttp2IocpEngine.Create(AServer);
end;

initialization
  // Same registration trick as the epoll engine: linking this unit is what
  // makes UseEventLoop resolve to IOCP. Nothing references it, so a build that
  // does not want it simply leaves it out.
  Nghttp2EngineFactory := CreateIocpEngine;

{$IFEND}

end.
