unit Nghttp2.Socket;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Nghttp2.Socket
//  Minimal cross-platform TCP socket wrapper — just enough for the accept
//  loop and a per-connection blocking recv/send pump.
//
//  Three code paths (mutually exclusive):
//    FPC       → uses the FPC Sockets unit (fpSocket/fpBind/fpListen/…)
//    Delphi Win → Winapi.WinSock2
//    Delphi POSIX → Posix.SysSocket + friends
//
//  IPv4 listener is always created. An optional AF_INET6 listener is created
//  alongside it when the OS supports IPv6 (CreateListenerSocket6 returns
//  INVALID_SOCKET_HANDLE with an AError string when IPv6 is unavailable,
//  instead of raising, so the server starts cleanly on IPv4-only hosts).
//
//  Two I/O modes live here side by side:
//    - Blocking (SocketRecv / SocketSend / SocketSendAll) — what the
//      thread-per-connection pump has always used. Untouched.
//    - Non-blocking (SocketRecvNB / SocketSendNB + SetSocketNonBlocking),
//      which report SOCKET_WOULD_BLOCK as a value distinct from both error
//      and peer-close. Required by an event-loop engine, where "not ready
//      yet" is the normal case and must never be confused with a dead peer.
// ============================================================================

interface

uses
{$IF DEFINED(FPC) AND DEFINED(UNIX)}
  SysUtils, Sockets, BaseUnix;   { [CL1] the resolver is libc's own
                                   getaddrinfo, bound in the implementation -
                                   netdb (fcl-net) is deliberately NOT used }
{$ELSEIF DEFINED(FPC)}
  SysUtils, Sockets, WinSock2;
{$ELSEIF DEFINED(MSWINDOWS)}
  System.SysUtils, Winapi.WinSock2;
{$ELSE}
  System.SysUtils, Posix.Base, Posix.SysSocket, Posix.SysTypes,
  Posix.NetinetIn, Posix.ArpaInet, Posix.Unistd, Posix.Errno,
  Posix.SysPoll, Posix.Signal,
  Posix.NetDB,   { [CL1] getaddrinfo / freeaddrinfo / addrinfo }
  Posix.Fcntl;   { fcntl + O_NONBLOCK for SetSocketNonBlocking }
{$IFEND}

type
{$IF DEFINED(FPC)}
  TSocketHandle = LongInt;
{$ELSEIF DEFINED(MSWINDOWS)}
  TSocketHandle = TSocket;
{$ELSE}
  TSocketHandle = Integer;
{$IFEND}

  ENghttp2Socket = class(Exception);

const
{$IF DEFINED(MSWINDOWS) AND NOT DEFINED(FPC)}
  INVALID_SOCKET_HANDLE = TSocketHandle(INVALID_SOCKET);
{$ELSE}
  INVALID_SOCKET_HANDLE = TSocketHandle(-1);
{$IFEND}

  { Returned by the *NB variants when the operation would have blocked.
    Deliberately distinct from both 0 (peer closed) and -1 (real error): on a
    non-blocking socket EAGAIN is the single most common outcome, and an
    engine that read it as either of the other two would tear down healthy
    connections at random under load. }
  SOCKET_WOULD_BLOCK = -2;

procedure InitSockets;
procedure ShutdownSockets;

{ Bind + listen on all interfaces (0.0.0.0), IPv4, given port + backlog.
  Sets SO_REUSEADDR. Raises ENghttp2Socket on any step failure.

  AReusePort adds SO_REUSEPORT, which lets SEVERAL sockets bind the same port
  and has the kernel load-balance incoming connections across them. That is
  how N event-loop threads each get their own listener and their own accept
  queue, with no shared accept thread and no cross-thread handoff.

  It must be set BEFORE bind — which is why it is a parameter here rather than
  something a caller can apply to a listener it already owns. Linux only in
  practice; on platforms without it the setsockopt fails and is ignored, so the
  caller gets an ordinary single-owner listener. }
function CreateListenerSocket(APort: Word; ABacklog: Integer;
  AReusePort: Boolean = False): TSocketHandle;

// Accept next incoming connection (blocking). Returns INVALID_SOCKET_HANDLE
// on error (which the caller uses as a signal to exit the accept loop, e.g.
// after a peer-side CloseSocketHandle on the listener during Stop).
// APeerAddr is filled with the client's dotted-quad IPv4 address.
function AcceptConnection(ALSock: TSocketHandle; out APeerAddr: string): TSocketHandle;

{ Bind + listen on all IPv6 interfaces (::), given port + backlog.
  Sets SO_REUSEADDR and IPV6_V6ONLY=1 so the AF_INET listener on the same
  port is not disturbed. Returns INVALID_SOCKET_HANDLE and sets AError when
  IPv6 is unavailable — never raises — so the caller can start the server
  on IPv4-only hosts without special-casing. }
function CreateListenerSocket6(APort: Word; ABacklog: Integer;
  out AError: string): TSocketHandle;

// Like AcceptConnection but for an AF_INET6 listener socket.
// APeerAddr is filled with the peer's IPv6 address in colon-hex notation.
function AcceptConnection6(ALSock: TSocketHandle; out APeerAddr: string): TSocketHandle;

// Client-side TCP connect.
//
// [CL1] On Delphi (Windows and POSIX) AHost may be a host NAME or an IP
// literal: getaddrinfo is asked for AF_UNSPEC, and the returned list is walked
// in order until one address connects, so an IPv6-only peer works without the
// caller knowing. The resolver's ordering decides v4-vs-v6 preference.
//
// ON FPC + UNIX the same is true, through libc's getaddrinfo bound directly
// (see the FFI block in the implementation). netdb is deliberately not used:
// without -dFPC_USE_LIBC it runs its own DNS client, whose unit header warns
// it "hardly does any error checking".
//
// ON FPC + WINDOWS AHost must still be an IPv4 literal: FPC's winsock2 unit
// declares no getaddrinfo (checked against 3.2.2 sources), so there is nothing
// to call without hand-binding ws2_32. A name raises ENghttp2Socket saying so
// rather than silently connecting somewhere else.
//
// Raises ENghttp2Socket on resolve, socket or connect failure — the message
// always names the host. On success returns a connected socket that the caller
// owns and must eventually CloseSocketHandle.
function ConnectToHost(const AHost: string; APort: Word): TSocketHandle;

// Waits up to ATimeoutMS for the socket to become readable.
//   >0 = readable (recv will not block)
//    0 = timed out
//   <0 = error (socket closed, invalid handle, …)
// Used by the connection pump so a thread parked waiting for client bytes
// still wakes periodically to flush responses that worker threads completed
// while it was blocked. Pass 0 for a non-blocking poll.
function SocketWaitReadable(ASock: TSocketHandle; ATimeoutMS: Integer): Integer;

// Same contract, for writability. Needed once a send can come up short: the
// caller must park until the kernel drains its send buffer rather than spin.
function SocketWaitWritable(ASock: TSocketHandle; ATimeoutMS: Integer): Integer;

{ Disable Nagle's algorithm on a connected socket. False on failure.

  NOT optional for a request/response protocol. Nagle holds a small write
  back waiting for more data to coalesce; the peer's delayed-ACK holds the
  acknowledgement waiting for data to piggyback on. Together they deadlock
  until a timer fires — 40 ms on Linux — and an HTTP/2 response frame is
  exactly the small write that triggers it.

  Measured before this existed: 226 req/s on a Linux loopback (~44 ms per
  request), against ~31 700 req/s for the Horse epoll provider on the same
  box. The FPC 94-check suite also ran ~2 000 ms here versus 117 ms for the
  identical suite on Windows — 17x, on the same code, because Windows
  loopback does not exhibit the same delayed-ACK stall. That asymmetry is why
  this went unnoticed: every Windows number looked healthy.

  Both Delphi-Cross-Socket and mORMot set this on every accepted socket. }
function SetSocketNoDelay(ASock: TSocketHandle): Boolean;

// Switch a socket between blocking and non-blocking mode. False on failure.
// Every socket handed to an event-loop engine must be non-blocking, or one
// slow peer stalls every other connection sharing that engine thread.
function SetSocketNonBlocking(ASock: TSocketHandle; AEnable: Boolean): Boolean;

// True when the most recent socket call failed only because it would have
// blocked. EINTR counts: a signal-interrupted call has not failed either, and
// the caller's response to both is the same — go back to the poller.
function SocketLastErrorIsWouldBlock: Boolean;

// Blocking recv. Returns bytes read (1..ALen), 0 on peer close, -1 on error.
function SocketRecv(ASock: TSocketHandle; ABuf: Pointer; ALen: Integer): Integer;

// Blocking send. Returns bytes written (1..ALen) or -1 on error. May return
// short — use SocketSendAll for full-buffer writes.
function SocketSend(ASock: TSocketHandle; ABuf: Pointer; ALen: Integer): Integer;

// Loops over SocketSend until ALen bytes are written or an error occurs.
// Returns True iff every byte was written.
function SocketSendAll(ASock: TSocketHandle; ABuf: Pointer; ALen: Integer): Boolean;

// Non-blocking recv. Bytes read · 0 peer closed · -1 error ·
// SOCKET_WOULD_BLOCK nothing available right now.
function SocketRecvNB(ASock: TSocketHandle; ABuf: Pointer; ALen: Integer): Integer;

// Non-blocking send. Bytes written (may be SHORT — that is not an error and
// is the normal signal that the send buffer is full) · -1 error ·
// SOCKET_WOULD_BLOCK nothing could be written at all.
function SocketSendNB(ASock: TSocketHandle; ABuf: Pointer; ALen: Integer): Integer;

// Hard close — no shutdown, socket becomes unusable immediately.
procedure CloseSocketHandle(ASock: TSocketHandle);

// Graceful close — half-close both directions, then close.
// NB despite the name this is the HARD path. STRACE-CONFIRMED 2026-08-19: on a
// socket whose response was just written, SHUT_RDWR + close destroys it —
// SHUT_RD discards the receive queue, close() with anything unread emits RST,
// and the RST discards the unsent SEND queue.
procedure ShutdownSocketHandle(ASock: TSocketHandle);

{ FIX-DRAIN-RST-2 (re-applied 2026-08-19 on strace evidence). Lingering close:
  FIN, drain the peer to EOF within a budget, then close.

  The measurement that motivates it, case A, one connection, failing run:

    56.664089  sendto(4, HEADERS  92) = 92
    56.664153  sendto(4, GOAWAY   17) = 17
    56.664206  sendto(4, DATA 25 bytes, the JSON body) = 25
    56.664409  shutdown(4, SHUT_RDWR) = 0     <- 203 us after the last write
    56.664458  close(4)               = 0

  Every write returns its full byte count, so the complete response reaches the
  kernel — and is then thrown away ~250 us later. Same thread as the writes.

  RESULT CODES exist because the first attempt at this fix changed nothing and
  there was no way to tell whether it had even run to completion:
    0  peer's FIN observed — the good exit, our bytes were read
    1  budget expired with the peer still connected
   -1  socket error while draining
  The caller logs this; judge the fix on the strace and this code, NOT on the
  delivery rate, which is noisy and has misled twice. }
function CloseSocketGraceful(ASock: TSocketHandle; ATimeoutMS: Integer): Integer;

implementation

// ─── Init / shutdown (Windows needs WSAStartup) ──────────────────────────

{$IF DEFINED(MSWINDOWS) AND NOT DEFINED(FPC)}
var
  GWSAStarted: Boolean = False;
{$IFEND}

procedure InitSockets;
{$IF DEFINED(MSWINDOWS) AND NOT DEFINED(FPC)}
var
  LWsaData: TWSAData;
begin
  if GWSAStarted then Exit;
  if WSAStartup($0202, LWsaData) <> 0 then
    raise ENghttp2Socket.Create('WSAStartup failed');
  GWSAStarted := True;
end;
{$ELSE}
begin
  // FPC and Delphi POSIX: nothing to do.
end;
{$IFEND}

procedure ShutdownSockets;
{$IF DEFINED(MSWINDOWS) AND NOT DEFINED(FPC)}
begin
  if GWSAStarted then
  begin
    WSACleanup;
    GWSAStarted := False;
  end;
end;
{$ELSE}
begin
end;
{$IFEND}

// ─── CreateListenerSocket ─────────────────────────────────────────────────

function CreateListenerSocket(APort: Word; ABacklog: Integer;
  AReusePort: Boolean = False): TSocketHandle;
{$IF DEFINED(FPC)}
var
  LSock: LongInt;
  LAddr: TInetSockAddr;
  LReuse: LongInt;
begin
  LSock := fpSocket(AF_INET, SOCK_STREAM, 0);
  if LSock < 0 then
    raise ENghttp2Socket.Create('fpSocket failed');

  LReuse := 1;
  fpSetSockOpt(LSock, SOL_SOCKET, SO_REUSEADDR, @LReuse, SizeOf(LReuse));
  if AReusePort then
    // SO_REUSEPORT = 15 on Linux. Spelled out because FPC's headers do not
    // export it consistently across versions, and a wrong constant here binds
    // successfully while silently giving every loop the same accept queue.
    fpSetSockOpt(LSock, SOL_SOCKET, 15, @LReuse, SizeOf(LReuse));

  FillChar(LAddr, SizeOf(LAddr), 0);
  LAddr.sin_family := AF_INET;
  LAddr.sin_port   := htons(APort);
  LAddr.sin_addr.s_addr := 0;   // INADDR_ANY

  if fpBind(LSock, @LAddr, SizeOf(LAddr)) <> 0 then
  begin
    CloseSocket(LSock);
    raise ENghttp2Socket.CreateFmt('fpBind :%d failed (errno=%d)', [APort, SocketError]);
  end;

  if fpListen(LSock, ABacklog) <> 0 then
  begin
    CloseSocket(LSock);
    raise ENghttp2Socket.Create('fpListen failed');
  end;

  Result := LSock;
end;
{$ELSEIF DEFINED(MSWINDOWS)}
var
  LSock: TSocket;
  LAddr: sockaddr_in;
  LReuse: Integer;
begin
  InitSockets;

  LSock := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if LSock = INVALID_SOCKET then
    raise ENghttp2Socket.CreateFmt('socket() failed: WSA=%d', [WSAGetLastError]);

  LReuse := 1;
  setsockopt(LSock, SOL_SOCKET, SO_REUSEADDR, @LReuse, SizeOf(LReuse));
  // Windows has no SO_REUSEPORT; SO_REUSEADDR there already permits the
  // rebind. AReusePort is accepted and ignored so callers need no branch.

  FillChar(LAddr, SizeOf(LAddr), 0);
  LAddr.sin_family := AF_INET;
  LAddr.sin_port   := htons(APort);
  LAddr.sin_addr.S_addr := INADDR_ANY;

  if bind(LSock, TSockAddr(LAddr), SizeOf(LAddr)) = SOCKET_ERROR then
  begin
    closesocket(LSock);
    raise ENghttp2Socket.CreateFmt('bind :%d failed: WSA=%d', [APort, WSAGetLastError]);
  end;

  if listen(LSock, ABacklog) = SOCKET_ERROR then
  begin
    closesocket(LSock);
    raise ENghttp2Socket.CreateFmt('listen failed: WSA=%d', [WSAGetLastError]);
  end;

  Result := LSock;
end;
{$ELSE}
var
  LSock: Integer;
  LAddr: sockaddr_in;
  LReuse: Integer;
begin
  LSock := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if LSock < 0 then
    raise ENghttp2Socket.CreateFmt('socket() failed: errno=%d', [errno]);

  LReuse := 1;
  // Delphi POSIX declares setsockopt with `const option_value` (untyped
  // const, wants an lvalue) — different from Winsock's PAnsiChar pointer
  // signature. Pass LReuse directly, not @LReuse (that's the pointer that
  // triggers E2036 "Variable required" on the Linux/macOS cross-compile).
  setsockopt(LSock, SOL_SOCKET, SO_REUSEADDR, LReuse, SizeOf(LReuse));
  if AReusePort then
    // 15 = SO_REUSEPORT on Linux. Same reasoning as the FPC branch; and note
    // the untyped-const setsockopt signature documented above — LReuse, not
    // @LReuse.
    setsockopt(LSock, SOL_SOCKET, 15, LReuse, SizeOf(LReuse));

  FillChar(LAddr, SizeOf(LAddr), 0);
  LAddr.sin_family := AF_INET;
  LAddr.sin_port   := htons(APort);
  LAddr.sin_addr.s_addr := 0;   // INADDR_ANY

  if bind(LSock, sockaddr(LAddr), SizeOf(LAddr)) < 0 then
  begin
    __close(LSock);
    raise ENghttp2Socket.CreateFmt('bind :%d failed: errno=%d', [APort, errno]);
  end;

  if listen(LSock, ABacklog) < 0 then
  begin
    __close(LSock);
    raise ENghttp2Socket.CreateFmt('listen failed: errno=%d', [errno]);
  end;

  Result := LSock;
end;
{$IFEND}

// ─── AcceptConnection ─────────────────────────────────────────────────────

{$IF DEFINED(FPC)}
function AcceptConnection(ALSock: TSocketHandle; out APeerAddr: string): TSocketHandle;
var
  LAddr: TInetSockAddr;
  LLen:  LongInt;
  LSock: LongInt;
  LIP:   LongWord;
begin
  APeerAddr := '';
  LLen := SizeOf(LAddr);
  LSock := fpAccept(ALSock, @LAddr, @LLen);
  if LSock < 0 then Exit(INVALID_SOCKET_HANDLE);

  LIP := LAddr.sin_addr.s_addr;   // network byte order
  APeerAddr := Format('%d.%d.%d.%d',
    [ LIP         and $FF,
     (LIP shr 8)  and $FF,
     (LIP shr 16) and $FF,
     (LIP shr 24) and $FF ]);

  // Nagle off before the first byte is served. See SetSocketNoDelay:
  // left on, a small response frame stalls ~40 ms against the peer's
  // delayed ACK, which measured as 226 req/s on Linux loopback.
  SetSocketNoDelay(LSock);
  Result := LSock;
end;
{$ELSEIF DEFINED(MSWINDOWS)}
function AcceptConnection(ALSock: TSocketHandle; out APeerAddr: string): TSocketHandle;
var
  LAddr: sockaddr_in;
  LLen:  Integer;
  LSock: TSocket;
  LIP:   LongWord;
begin
  APeerAddr := '';
  LLen := SizeOf(LAddr);
  LSock := accept(ALSock, @LAddr, @LLen);
  if LSock = INVALID_SOCKET then Exit(INVALID_SOCKET_HANDLE);

  LIP := LAddr.sin_addr.S_addr;
  APeerAddr := Format('%d.%d.%d.%d',
    [ LIP         and $FF,
     (LIP shr 8)  and $FF,
     (LIP shr 16) and $FF,
     (LIP shr 24) and $FF ]);

  // Nagle off before the first byte is served. See SetSocketNoDelay:
  // left on, a small response frame stalls ~40 ms against the peer's
  // delayed ACK, which measured as 226 req/s on Linux loopback.
  SetSocketNoDelay(LSock);
  Result := LSock;
end;
{$ELSE}
function AcceptConnection(ALSock: TSocketHandle; out APeerAddr: string): TSocketHandle;
var
  LAddr: sockaddr_in;
  LLen:  socklen_t;
  LSock: Integer;
  LIP:   LongWord;
begin
  APeerAddr := '';
  LLen := SizeOf(LAddr);
  LSock := accept(ALSock, sockaddr(LAddr), LLen);
  if LSock < 0 then Exit(INVALID_SOCKET_HANDLE);

  LIP := LAddr.sin_addr.s_addr;
  APeerAddr := Format('%d.%d.%d.%d',
    [ LIP         and $FF,
     (LIP shr 8)  and $FF,
     (LIP shr 16) and $FF,
     (LIP shr 24) and $FF ]);

  // Nagle off before the first byte is served. See SetSocketNoDelay:
  // left on, a small response frame stalls ~40 ms against the peer's
  // delayed ACK, which measured as 226 req/s on Linux loopback.
  SetSocketNoDelay(LSock);
  Result := LSock;
end;
{$IFEND}

// ─── IPv6 types and constants (implementation-local) ─────────────────────

type
  { Portable sockaddr_in6 layout (28 bytes on every platform).
    Defined here rather than relying on platform-specific unit types, which
    differ between FPC versions and Delphi POSIX/Windows SDK headers. }
  TSockAddr6 = packed record
    sin6_family:   Word;                     { 2 — AF_INET6 }
    sin6_port:     Word;                     { 2 — port, network byte order }
    sin6_flowinfo: LongWord;                 { 4 — flow label + traffic class }
    sin6_addr:     array [0..15] of Byte;    { 16 — IPv6 address (in6_addr) }
    sin6_scope_id: LongWord;                 { 4 — scope id }
  end;                                       { total = 28 }

const
  { IANA-stable — never changes. }
  NGH2_IPPROTO_IPV6 = 41;
{$IF DEFINED(MSWINDOWS) AND NOT DEFINED(FPC)}
const
  NGH2_IPV6_V6ONLY = 27;   { ws2def.h }
{$ELSE}
const
  NGH2_IPV6_V6ONLY = 26;   { netinet/in.h (Linux, macOS, BSDs) }
{$IFEND}

// ─── CreateListenerSocket6 ────────────────────────────────────────────────

function CreateListenerSocket6(APort: Word; ABacklog: Integer;
  out AError: string): TSocketHandle;
{$IF DEFINED(FPC)}
var
  LSock:   LongInt;
  LAddr6:  TSockAddr6;
  LReuse:  LongInt;
  LV6Only: LongInt;
begin
  AError := '';

  LSock := fpSocket(AF_INET6, SOCK_STREAM, 0);
  if LSock < 0 then
  begin
    AError := Format('fpSocket(AF_INET6) failed (errno=%d)', [SocketError]);
    Exit(INVALID_SOCKET_HANDLE);
  end;

  LReuse := 1;
  fpSetSockOpt(LSock, SOL_SOCKET, SO_REUSEADDR, @LReuse, SizeOf(LReuse));

  { IPV6_V6ONLY=1: only pure IPv6 peers connect. Without this the kernel may
    present IPv4-mapped addresses (::ffff:x.x.x.x) and collide with the
    AF_INET socket already bound to the same port on dual-stack hosts. }
  LV6Only := 1;
  fpSetSockOpt(LSock, NGH2_IPPROTO_IPV6, NGH2_IPV6_V6ONLY,
               @LV6Only, SizeOf(LV6Only));

  FillChar(LAddr6, SizeOf(LAddr6), 0);
  LAddr6.sin6_family := AF_INET6;
  LAddr6.sin6_port   := htons(APort);
  { sin6_addr all-zeros = in6addr_any ('::') — accept on every interface. }

  if fpBind(LSock, PSockAddr(@LAddr6), SizeOf(LAddr6)) <> 0 then
  begin
    CloseSocket(LSock);
    AError := Format('fpBind(AF_INET6) :%d failed (errno=%d)',
                     [APort, SocketError]);
    Exit(INVALID_SOCKET_HANDLE);
  end;

  if fpListen(LSock, ABacklog) <> 0 then
  begin
    CloseSocket(LSock);
    AError := 'fpListen(AF_INET6) failed';
    Exit(INVALID_SOCKET_HANDLE);
  end;

  Result := LSock;
end;
{$ELSEIF DEFINED(MSWINDOWS)}
var
  LSock:   TSocket;
  LAddr6:  TSockAddr6;
  LReuse:  Integer;
  LV6Only: Integer;
begin
  AError := '';
  InitSockets;

  LSock := socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP);
  if LSock = INVALID_SOCKET then
  begin
    AError := Format('socket(AF_INET6) failed: WSA=%d', [WSAGetLastError]);
    Exit(INVALID_SOCKET_HANDLE);
  end;

  LReuse := 1;
  setsockopt(LSock, SOL_SOCKET, SO_REUSEADDR, @LReuse, SizeOf(LReuse));

  LV6Only := 1;
  setsockopt(LSock, NGH2_IPPROTO_IPV6, NGH2_IPV6_V6ONLY,
             @LV6Only, SizeOf(LV6Only));

  FillChar(LAddr6, SizeOf(LAddr6), 0);
  LAddr6.sin6_family := AF_INET6;
  LAddr6.sin6_port   := htons(APort);

  { PSockAddr(@LAddr6)^ : pass the address of our 28-byte struct as the
    16-byte TSockAddr var-param; SizeOf(LAddr6)=28 tells the kernel how
    many bytes to read — the standard C (struct sockaddr *)&sin6 pattern. }
  if bind(LSock, PSockAddr(@LAddr6)^, SizeOf(LAddr6)) = SOCKET_ERROR then
  begin
    closesocket(LSock);
    AError := Format('bind(AF_INET6) :%d failed: WSA=%d',
                     [APort, WSAGetLastError]);
    Exit(INVALID_SOCKET_HANDLE);
  end;

  if listen(LSock, ABacklog) = SOCKET_ERROR then
  begin
    closesocket(LSock);
    AError := Format('listen(AF_INET6) failed: WSA=%d', [WSAGetLastError]);
    Exit(INVALID_SOCKET_HANDLE);
  end;

  Result := LSock;
end;
{$ELSE}
var
  LSock:   Integer;
  LAddr6:  TSockAddr6;
  LV6Only: Integer;
begin
  AError := '';

  LSock := socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP);
  if LSock < 0 then
  begin
    AError := Format('socket(AF_INET6) failed: errno=%d', [errno]);
    Exit(INVALID_SOCKET_HANDLE);
  end;

  setsockopt(LSock, SOL_SOCKET, SO_REUSEADDR, 1, SizeOf(Integer));

  LV6Only := 1;
  setsockopt(LSock, NGH2_IPPROTO_IPV6, NGH2_IPV6_V6ONLY,
             LV6Only, SizeOf(LV6Only));

  FillChar(LAddr6, SizeOf(LAddr6), 0);
  LAddr6.sin6_family := AF_INET6;
  LAddr6.sin6_port   := htons(APort);

  { sockaddr(Pointer(@LAddr6)^) : the C (struct sockaddr *)&sin6 idiom for
    Delphi POSIX, where bind takes 'const addr: sockaddr'. Delphi passes the
    address of the var we give it; SizeOf(LAddr6)=28 covers the full struct. }
  if bind(LSock, sockaddr(Pointer(@LAddr6)^), SizeOf(LAddr6)) < 0 then
  begin
    __close(LSock);
    AError := Format('bind(AF_INET6) :%d failed: errno=%d', [APort, errno]);
    Exit(INVALID_SOCKET_HANDLE);
  end;

  if listen(LSock, ABacklog) < 0 then
  begin
    __close(LSock);
    AError := Format('listen(AF_INET6) failed: errno=%d', [errno]);
    Exit(INVALID_SOCKET_HANDLE);
  end;

  Result := LSock;
end;
{$IFEND}

// ─── AcceptConnection6 ────────────────────────────────────────────────────
//
// Formats the peer address as eight colon-separated groups of four hex
// digits (e.g. "0000:0000:0000:0000:0000:0000:0000:0001" for ::1). Not
// compressed, but unambiguous and requires no inet_ntop FFI binding.

{$IF DEFINED(FPC)}
function AcceptConnection6(ALSock: TSocketHandle; out APeerAddr: string): TSocketHandle;
var
  LAddr6: TSockAddr6;
  LLen:   LongInt;
  LSock:  LongInt;
  I:      Integer;
  W:      Word;
begin
  APeerAddr := '';
  LLen  := SizeOf(LAddr6);
  LSock := fpAccept(ALSock, PSockAddr(@LAddr6), @LLen);
  if LSock < 0 then Exit(INVALID_SOCKET_HANDLE);

  for I := 0 to 7 do
  begin
    if I > 0 then APeerAddr := APeerAddr + ':';
    W := (Word(LAddr6.sin6_addr[I * 2]) shl 8) or LAddr6.sin6_addr[I * 2 + 1];
    APeerAddr := APeerAddr + LowerCase(IntToHex(Integer(W), 4));
  end;

  SetSocketNoDelay(LSock);
  Result := LSock;
end;
{$ELSEIF DEFINED(MSWINDOWS)}
function AcceptConnection6(ALSock: TSocketHandle; out APeerAddr: string): TSocketHandle;
var
  LAddr6: TSockAddr6;
  LLen:   Integer;
  LSock:  TSocket;
  I:      Integer;
  W:      Word;
begin
  APeerAddr := '';
  LLen  := SizeOf(LAddr6);
  LSock := accept(ALSock, PSockAddr(@LAddr6), @LLen);
  if LSock = INVALID_SOCKET then Exit(INVALID_SOCKET_HANDLE);

  for I := 0 to 7 do
  begin
    if I > 0 then APeerAddr := APeerAddr + ':';
    W := (Word(LAddr6.sin6_addr[I * 2]) shl 8) or LAddr6.sin6_addr[I * 2 + 1];
    APeerAddr := APeerAddr + LowerCase(IntToHex(Integer(W), 4));
  end;

  SetSocketNoDelay(LSock);
  Result := LSock;
end;
{$ELSE}
function AcceptConnection6(ALSock: TSocketHandle; out APeerAddr: string): TSocketHandle;
var
  LAddr6: TSockAddr6;
  LLen:   socklen_t;
  LSock:  Integer;
  I:      Integer;
  W:      Word;
begin
  APeerAddr := '';
  LLen  := SizeOf(LAddr6);
  LSock := accept(ALSock, sockaddr(Pointer(@LAddr6)^), LLen);
  if LSock < 0 then Exit(INVALID_SOCKET_HANDLE);

  for I := 0 to 7 do
  begin
    if I > 0 then APeerAddr := APeerAddr + ':';
    W := (Word(LAddr6.sin6_addr[I * 2]) shl 8) or LAddr6.sin6_addr[I * 2 + 1];
    APeerAddr := APeerAddr + LowerCase(IntToHex(Integer(W), 4));
  end;

  SetSocketNoDelay(LSock);
  Result := LSock;
end;
{$IFEND}

{$IF DEFINED(FPC) AND DEFINED(UNIX)}
{ [CL1] libc's resolver, bound here rather than reached through netdb.

  Why not netdb: unless the host application is built with -dFPC_USE_LIBC, its
  ResolveName runs netdb's own DNS client, and that unit's header warns it
  "hardly does any error checking" and "could easily be exploited by someone
  sending malicious UDP packets". Binding libc directly gives every FPC build
  the platform resolver — the same one the Delphi branches use — with no build
  flag to remember, and drops the fcl-net package dependency.

  PACKRECORDS C is load-bearing. On 64-bit, the 4-byte ai_addrlen is followed
  by 4 bytes of padding before the first pointer; a packed record would read
  ai_addr from the wrong offset and hand connect() garbage.

  The FIELD ORDER differs by platform: Linux declares ai_addr before
  ai_canonname, the BSDs and macOS put ai_canonname first. Getting this
  backwards passes a char* to connect(). }
{$PACKRECORDS C}
type
  PNgAddrInfo = ^TNgAddrInfo;
  TNgAddrInfo = record
    ai_flags:     Integer;
    ai_family:    Integer;
    ai_socktype:  Integer;
    ai_protocol:  Integer;
    ai_addrlen:   LongWord;        { socklen_t - 32-bit on Linux and the BSDs }
  {$IF DEFINED(LINUX) OR DEFINED(ANDROID)}
    ai_addr:      psockaddr;
    ai_canonname: PAnsiChar;
  {$ELSE}
    ai_canonname: PAnsiChar;
    ai_addr:      psockaddr;
  {$IFEND}
    ai_next:      PNgAddrInfo;
  end;
{$PACKRECORDS DEFAULT}

function ng_getaddrinfo(ANode, AService: PAnsiChar; AHints: PNgAddrInfo;
  var ARes: PNgAddrInfo): Integer; cdecl; external 'c' name 'getaddrinfo';
procedure ng_freeaddrinfo(ARes: PNgAddrInfo); cdecl;
  external 'c' name 'freeaddrinfo';
function ng_gai_strerror(ACode: Integer): PAnsiChar; cdecl;
  external 'c' name 'gai_strerror';
{$IFEND}

// ─── ConnectToHost ────────────────────────────────────────────────────────
// Cross-platform client TCP connect. Mirrors CreateListenerSocket's 3-branch
// FPC / MSWINDOWS / Delphi POSIX structure.
//
// [CL1] The Delphi branches resolve through getaddrinfo and try every address
// returned, in order, until one connects. Both were previously hand-building
// an AF_INET sockaddr from a dotted-quad string, which is why a name could not
// work and — on POSIX — why a malformed literal became a connect to
// 255.255.255.255 (inet_addr's failure value went in unchecked).
//
// Why the whole list rather than the first entry: a dual-stack host commonly
// returns an IPv6 address first, and on a machine whose IPv6 route is dead
// that entry fails while the IPv4 one behind it works. Taking only the first
// address is the classic cause of "works in curl, fails in my program".

function ConnectToHost(const AHost: string; APort: Word): TSocketHandle;
{$IF DEFINED(FPC) AND DEFINED(UNIX)}
var
  LHints:     TNgAddrInfo;
  LRes, LCur: PNgAddrInfo;
  LHostAnsi, LPortAnsi: AnsiString;
  LRc:        Integer;
  LSock:      LongInt;
begin
  { Same shape as the Delphi branches: ask for AF_UNSPEC and walk the whole
    list, because a dual-stack host commonly returns IPv6 first and that entry
    fails on a machine whose v6 route is dead. libc also parses literals, so
    there is no separate literal path to keep in step. }
  FillChar(LHints, SizeOf(LHints), 0);
  LHints.ai_family   := AF_UNSPEC;
  LHints.ai_socktype := SOCK_STREAM;
  { ai_protocol stays 0 - "any protocol for this socket type", which for
    SOCK_STREAM is TCP. IPPROTO_TCP is not reliably in scope from Sockets on
    every Unix target, and 0 says the same thing to getaddrinfo. }

  LHostAnsi := AnsiString(AHost);
  LPortAnsi := AnsiString(IntToStr(APort));
  LRes      := nil;

  LRc := ng_getaddrinfo(PAnsiChar(LHostAnsi), PAnsiChar(LPortAnsi),
                        @LHints, LRes);
  if (LRc <> 0) or (LRes = nil) then
    raise ENghttp2Socket.CreateFmt('cannot resolve "%s": %s',
      [AHost, string(AnsiString(ng_gai_strerror(LRc)))]);

  Result := INVALID_SOCKET_HANDLE;
  try
    LCur := LRes;
    while LCur <> nil do
    begin
      LSock := fpSocket(LCur^.ai_family, LCur^.ai_socktype, LCur^.ai_protocol);
      if LSock >= 0 then
      begin
        if fpConnect(LSock, LCur^.ai_addr, LCur^.ai_addrlen) >= 0 then
        begin
          Result := LSock;
          Break;
        end;
        CloseSocket(LSock);
      end;
      LCur := LCur^.ai_next;
    end;
  finally
    ng_freeaddrinfo(LRes);
  end;

  if Result = INVALID_SOCKET_HANDLE then
    raise ENghttp2Socket.CreateFmt(
      'connect(%s:%d) failed - every resolved address refused the connection',
      [AHost, APort]);

  // Same reason as the server side — a client that stalls 40 ms per request
  // makes every measurement taken with it meaningless.
  SetSocketNoDelay(Result);
end;
{$ELSEIF DEFINED(FPC)}
var
  LSock: LongInt;
  LAddr: TInetSockAddr;
  LHostAnsi: AnsiString;
  LNetAddr: in_addr;
begin
  { [CL1] FPC on Windows resolves nothing: netdb is Unix-only (its
    implementation uses BaseUnix unconditionally) and FPC's winsock2 unit
    declares no getaddrinfo at all - verified against the 3.2.2 sources. The
    remaining option is hand-binding ws2_32's getaddrinfo, which is not worth
    doing blind; do it on a machine that can compile and run it.

    What DID change: StrToNetAddr's result is now checked, so a host NAME
    raises instead of silently connecting to 0.0.0.0. }
  LHostAnsi := AnsiString(AHost);
  LNetAddr  := StrToNetAddr(LHostAnsi);
  if LNetAddr.s_addr = 0 then
    raise ENghttp2Socket.CreateFmt(
      'cannot connect to "%s" - on FPC/Windows this must be an IPv4 literal; ' +
      'no resolver is available there (CL1)', [AHost]);

  LSock := fpSocket(AF_INET, SOCK_STREAM, 0);
  if LSock < 0 then
    raise ENghttp2Socket.Create('fpSocket failed');

  FillChar(LAddr, SizeOf(LAddr), 0);
  LAddr.sin_family      := AF_INET;
  LAddr.sin_port        := htons(APort);
  LAddr.sin_addr.s_addr := LNetAddr.s_addr;

  if fpConnect(LSock, psockaddr(@LAddr), SizeOf(LAddr)) < 0 then
  begin
    CloseSocket(LSock);
    raise ENghttp2Socket.CreateFmt('fpConnect(%s:%d) failed', [AHost, APort]);
  end;
  // Same reason as the server side — a client that stalls 40 ms per request
  // makes every measurement taken with it meaningless.
  SetSocketNoDelay(LSock);
  Result := LSock;
end;
{$ELSEIF DEFINED(MSWINDOWS)}
var
  LHints:    addrinfo;
  LRes, LCur: Paddrinfo;
  LHostAnsi, LPortAnsi: AnsiString;
  LSock:     TSocket;
  LRc:       Integer;
  LWsaErr:   Integer;
begin
  InitSockets;

  FillChar(LHints, SizeOf(LHints), 0);
  LHints.ai_family   := AF_UNSPEC;      // v4 or v6 — the resolver orders them
  LHints.ai_socktype := SOCK_STREAM;
  LHints.ai_protocol := IPPROTO_TCP;

  LHostAnsi := AnsiString(AHost);
  LPortAnsi := AnsiString(IntToStr(APort));
  LRes      := nil;

  LRc := getaddrinfo(MarshaledAString(PAnsiChar(LHostAnsi)),
                     MarshaledAString(PAnsiChar(LPortAnsi)), LHints, LRes);
  if (LRc <> 0) or (LRes = nil) then
    raise ENghttp2Socket.CreateFmt(
      'cannot resolve "%s": getaddrinfo=%d', [AHost, LRc]);

  Result  := INVALID_SOCKET_HANDLE;
  LWsaErr := 0;
  try
    LCur := LRes;
    while LCur <> nil do
    begin
      LSock := socket(LCur^.ai_family, LCur^.ai_socktype, LCur^.ai_protocol);
      if LSock = INVALID_SOCKET then
        LWsaErr := WSAGetLastError
      else
      begin
        if Winapi.WinSock2.connect(LSock, LCur^.ai_addr^,
             Integer(LCur^.ai_addrlen)) <> SOCKET_ERROR then
        begin
          Result := LSock;
          Break;
        end;
        // Capture WSA error BEFORE closesocket — closesocket clears the last
        // WSA error, leaving diagnostic messages like "WSA=0" that hide the
        // real failure code (typically 10061 ECONNREFUSED or 10060 ETIMEDOUT).
        LWsaErr := WSAGetLastError;
        closesocket(LSock);
      end;
      LCur := LCur^.ai_next;
    end;
  finally
    // freeaddrinfo takes the record by reference, not the pointer.
    freeaddrinfo(LRes^);
  end;

  if Result = INVALID_SOCKET_HANDLE then
    raise ENghttp2Socket.CreateFmt('connect(%s:%d) failed: WSA=%d',
      [AHost, APort, LWsaErr]);

  // Same reason as the server side — a client that stalls 40 ms per request
  // makes every measurement taken with it meaningless.
  SetSocketNoDelay(Result);
end;
{$ELSE}
var
  LHints:    addrinfo;
  LRes, LCur: Paddrinfo;
  LHostAnsi, LPortAnsi: AnsiString;
  LSock:     Integer;
  LRc:       Integer;
  LErr:      Integer;
begin
  { NOTE: Posix.NetDB's declarations could not be checked in the dev container
    (this Delphi install ships Windows RTL sources only). The logic is the same
    walk as the Windows branch; if the Linux build rejects a name here, fix the
    spelling against the local Posix.NetDB and leave the structure alone. }
  FillChar(LHints, SizeOf(LHints), 0);
  LHints.ai_family   := AF_UNSPEC;
  LHints.ai_socktype := SOCK_STREAM;
  LHints.ai_protocol := IPPROTO_TCP;

  LHostAnsi := AnsiString(AHost);
  LPortAnsi := AnsiString(IntToStr(APort));
  LRes      := nil;

  LRc := getaddrinfo(MarshaledAString(PAnsiChar(LHostAnsi)),
                     MarshaledAString(PAnsiChar(LPortAnsi)), LHints, LRes);
  if (LRc <> 0) or (LRes = nil) then
    raise ENghttp2Socket.CreateFmt(
      'cannot resolve "%s": getaddrinfo=%d', [AHost, LRc]);

  Result := INVALID_SOCKET_HANDLE;
  LErr   := 0;
  try
    LCur := LRes;
    while LCur <> nil do
    begin
      LSock := socket(LCur^.ai_family, LCur^.ai_socktype, LCur^.ai_protocol);
      if LSock < 0 then
        LErr := errno
      else
      begin
        if connect(LSock, LCur^.ai_addr^, LCur^.ai_addrlen) >= 0 then
        begin
          Result := LSock;
          Break;
        end;
        LErr := errno;
        __close(LSock);
      end;
      LCur := LCur^.ai_next;
    end;
  finally
    freeaddrinfo(LRes^);
  end;

  if Result = INVALID_SOCKET_HANDLE then
    raise ENghttp2Socket.CreateFmt('connect(%s:%d) failed: errno=%d',
      [AHost, APort, LErr]);

  // Same reason as the server side — a client that stalls 40 ms per request
  // makes every measurement taken with it meaningless.
  SetSocketNoDelay(Result);
end;
{$IFEND}

// ─── SocketWaitReadable / SocketWaitWritable ─────────────────────────────
// poll()-based readiness wait with a millisecond timeout. Four platform
// branches mirror the structure of CreateListenerSocket above.
//
// poll() is used instead of select() on every POSIX branch for one reason:
// POSIX fd_set is a fixed-width bitmask (FD_SETSIZE = 1024 on Linux). An fd
// at or past that limit would silently corrupt the stack-allocated bitmask,
// so the old select() code short-circuited to "ready" for high-numbered fds.
// That bypassed the timeout entirely — DoRead went straight to a blocking
// recv() with no deadline, which caused ReadChunk to hang indefinitely when
// the server stalled (e.g. HTTP/2 flow-control window exhausted). poll() has
// no fd-number limit and always honours the timeout, fixing CL3b.
//
// Windows uses select() with its count+handle fd_set — no fd limit there, so
// that branch is unchanged.

function SocketWaitImpl(ASock: TSocketHandle; AForWrite: Boolean;
  ATimeoutMS: Integer): Integer;
{$IF DEFINED(FPC) AND DEFINED(UNIX)}
var
  LPollFD: TPollFD;
begin
  if ASock = INVALID_SOCKET_HANDLE then Exit(-1);
  LPollFD.fd := ASock;
  if AForWrite then
    LPollFD.events := POLLOUT
  else
    LPollFD.events := POLLIN;
  LPollFD.revents := 0;
  Result := fpPoll(@LPollFD, 1, ATimeoutMS);
end;
{$ELSEIF DEFINED(FPC)}
var
  LFDSet:   TFDSet;
  LTimeVal: TTimeVal;
begin
  if ASock = INVALID_SOCKET_HANDLE then Exit(-1);
  LTimeVal.tv_sec  := ATimeoutMS div 1000;
  LTimeVal.tv_usec := 1000 * (ATimeoutMS mod 1000);
  // Same hand-populated one-socket set as the Delphi/Windows branch below,
  // for the same reason spelled out there. Identical record layout.
  LFDSet.fd_count    := 1;
  LFDSet.fd_array[0] := ASock;
  if AForWrite then
    Result := select(0, nil, @LFDSet, nil, @LTimeVal)
  else
    Result := select(0, @LFDSet, nil, nil, @LTimeVal);
end;
{$ELSEIF DEFINED(MSWINDOWS)}
var
  LFDSet:   TFDSet;
  LTimeVal: TTimeVal;
begin
  if ASock = INVALID_SOCKET_HANDLE then Exit(-1);
  LTimeVal.tv_sec  := ATimeoutMS div 1000;
  LTimeVal.tv_usec := 1000 * (ATimeoutMS mod 1000);
  // Populated by hand rather than via FD_ZERO/FD_SET: in Winapi.WinSock2
  // FD_SET is the record TYPE, so FD_SET(sock, set) parses as a typecast and
  // fails with E2029. Windows fd_set is just a count plus a handle array, so
  // a one-socket set is these two assignments — which is precisely what
  // FD_ZERO followed by FD_SET would produce.
  LFDSet.fd_count    := 1;
  LFDSet.fd_array[0] := ASock;
  // nfds is ignored on Windows.
  if AForWrite then
    Result := select(0, nil, @LFDSet, nil, @LTimeVal)
  else
    Result := select(0, @LFDSet, nil, nil, @LTimeVal);
end;
{$ELSE}
var
  LPollFD: pollfd;
begin
  if ASock = INVALID_SOCKET_HANDLE then Exit(-1);
  LPollFD.fd := ASock;
  if AForWrite then
    LPollFD.events := POLLOUT
  else
    LPollFD.events := POLLIN;
  LPollFD.revents := 0;
  Result := poll(@LPollFD, 1, ATimeoutMS);
end;
{$IFEND}

function SocketWaitReadable(ASock: TSocketHandle; ATimeoutMS: Integer): Integer;
begin
  Result := SocketWaitImpl(ASock, False, ATimeoutMS);
end;

function SocketWaitWritable(ASock: TSocketHandle; ATimeoutMS: Integer): Integer;
begin
  Result := SocketWaitImpl(ASock, True, ATimeoutMS);
end;

// ─── SetSocketNonBlocking / SocketLastErrorIsWouldBlock ──────────────────

{$IF DEFINED(MSWINDOWS)}
const
  { Winsock's FIONBIO is $8004667E, which does not fit a signed Integer, and
    ioctlsocket takes its command as one. Written as an explicit typecast of
    the literal so the value is the same bit pattern on every compiler — the
    or-composed form in the WinSock headers types itself as unsigned and then
    trips range checking at the call. }
  NGH_FIONBIO = Integer($8004667E);
{$IFEND}

function SetSocketNoDelay(ASock: TSocketHandle): Boolean;
const
  { Spelled out rather than taken from the platform headers: IPPROTO_TCP and
    TCP_NODELAY carry the same values on Linux, macOS and Windows, but live in
    different units under each compiler and are not always exported. Two
    literals are more portable here than four conditional imports. }
  NGH_IPPROTO_TCP = 6;
  NGH_TCP_NODELAY = 1;
var
  LOn: Integer;
begin
  if ASock = INVALID_SOCKET_HANDLE then Exit(False);
  LOn := 1;
{$IF DEFINED(FPC)}
  Result := fpSetSockOpt(ASock, NGH_IPPROTO_TCP, NGH_TCP_NODELAY,
                         @LOn, SizeOf(LOn)) = 0;
{$ELSEIF DEFINED(MSWINDOWS)}
  Result := setsockopt(ASock, NGH_IPPROTO_TCP, NGH_TCP_NODELAY,
                       PAnsiChar(@LOn), SizeOf(LOn)) = 0;
{$ELSE}
  // Delphi POSIX takes option_value as an untyped const — an lvalue, not a
  // pointer. Passing @LOn here is the E2036 "Variable required" trap already
  // documented on SO_REUSEADDR above.
  Result := setsockopt(ASock, NGH_IPPROTO_TCP, NGH_TCP_NODELAY,
                       LOn, SizeOf(LOn)) = 0;
{$IFEND}
end;

function SetSocketNonBlocking(ASock: TSocketHandle; AEnable: Boolean): Boolean;
{$IF DEFINED(MSWINDOWS)}
var
  LArg: u_long;
begin
  if ASock = INVALID_SOCKET_HANDLE then Exit(False);
  if AEnable then LArg := 1 else LArg := 0;
  Result := ioctlsocket(ASock, NGH_FIONBIO, LArg) = 0;
end;
{$ELSEIF DEFINED(FPC)}
var
  LFlags: LongInt;
begin
  if ASock = INVALID_SOCKET_HANDLE then Exit(False);
  LFlags := fpFcntl(ASock, F_GETFL, 0);
  if LFlags < 0 then Exit(False);
  if AEnable then
    LFlags := LFlags or O_NONBLOCK
  else
    LFlags := LFlags and not O_NONBLOCK;
  Result := fpFcntl(ASock, F_SETFL, LFlags) >= 0;
end;
{$ELSE}
var
  LFlags: Integer;
begin
  if ASock = INVALID_SOCKET_HANDLE then Exit(False);
  LFlags := fcntl(ASock, F_GETFL);
  if LFlags < 0 then Exit(False);
  if AEnable then
    LFlags := LFlags or O_NONBLOCK
  else
    LFlags := LFlags and not O_NONBLOCK;
  Result := fcntl(ASock, F_SETFL, LFlags) >= 0;
end;
{$IFEND}

function SocketLastErrorIsWouldBlock: Boolean;
{$IF DEFINED(MSWINDOWS)}
var
  LErr: Integer;
begin
  LErr := WSAGetLastError;
  Result := (LErr = WSAEWOULDBLOCK) or (LErr = WSAEINTR);
end;
{$ELSEIF DEFINED(FPC)}
var
  LErr: LongInt;
begin
  LErr := SocketError;
  // EAGAIN and EWOULDBLOCK are the same value on Linux but not required to be
  // by POSIX, so both are tested.
  Result := (LErr = ESysEAGAIN) or (LErr = ESysEWOULDBLOCK) or (LErr = ESysEINTR);
end;
{$ELSE}
var
  LErr: Integer;
begin
  LErr := errno;
  Result := (LErr = EAGAIN) or (LErr = EWOULDBLOCK) or (LErr = EINTR);
end;
{$IFEND}

// ─── SocketRecv / SocketSend / SocketSendAll ─────────────────────────────

function SocketRecv(ASock: TSocketHandle; ABuf: Pointer; ALen: Integer): Integer;
begin
{$IF DEFINED(FPC)}
  Result := fpRecv(ASock, ABuf, ALen, 0);
{$ELSEIF DEFINED(MSWINDOWS)}
  Result := recv(ASock, ABuf^, ALen, 0);
{$ELSE}
  Result := recv(ASock, ABuf^, ALen, 0);
{$IFEND}
end;

function SocketSend(ASock: TSocketHandle; ABuf: Pointer; ALen: Integer): Integer;
begin
{$IF DEFINED(FPC)}
  Result := fpSend(ASock, ABuf, ALen, 0);
{$ELSEIF DEFINED(MSWINDOWS)}
  Result := send(ASock, ABuf^, ALen, 0);
{$ELSE}
  Result := send(ASock, ABuf^, ALen, 0);
{$IFEND}
end;

function SocketSendAll(ASock: TSocketHandle; ABuf: Pointer; ALen: Integer): Boolean;
var
  LSent, LWritten: Integer;
begin
  LSent := 0;
  while LSent < ALen do
  begin
    LWritten := SocketSend(ASock, Pointer(NativeUInt(ABuf) + NativeUInt(LSent)), ALen - LSent);
    if LWritten <= 0 then Exit(False);
    Inc(LSent, LWritten);
  end;
  Result := True;
end;

// ─── SocketRecvNB / SocketSendNB ─────────────────────────────────────────
// Thin wrappers over the blocking calls: the syscall is identical, only the
// socket's own mode decides whether it blocks. The caller must have run
// SetSocketNonBlocking first — on a blocking socket these behave exactly like
// their blocking counterparts and simply never report SOCKET_WOULD_BLOCK.
//
// The whole job here is turning one overloaded -1 into two distinct answers.

function SocketRecvNB(ASock: TSocketHandle; ABuf: Pointer; ALen: Integer): Integer;
begin
  Result := SocketRecv(ASock, ABuf, ALen);
  if (Result < 0) and SocketLastErrorIsWouldBlock then
    Result := SOCKET_WOULD_BLOCK;
end;

function SocketSendNB(ASock: TSocketHandle; ABuf: Pointer; ALen: Integer): Integer;
begin
  Result := SocketSend(ASock, ABuf, ALen);
  if (Result < 0) and SocketLastErrorIsWouldBlock then
    Result := SOCKET_WOULD_BLOCK;
end;

// ─── CloseSocketHandle / ShutdownSocketHandle ────────────────────────────

procedure CloseSocketHandle(ASock: TSocketHandle);
begin
  if ASock = INVALID_SOCKET_HANDLE then Exit;
{$IF DEFINED(FPC)}
  CloseSocket(ASock);
{$ELSEIF DEFINED(MSWINDOWS)}
  closesocket(ASock);
{$ELSE}
  __close(ASock);
{$IFEND}
end;

procedure ShutdownSocketHandle(ASock: TSocketHandle);
begin
  if ASock = INVALID_SOCKET_HANDLE then Exit;
{$IF DEFINED(FPC)}
  fpShutdown(ASock, 2);   // SHUT_RDWR
  CloseSocket(ASock);
{$ELSEIF DEFINED(MSWINDOWS)}
  shutdown(ASock, SD_BOTH);
  closesocket(ASock);
{$ELSE}
  shutdown(ASock, SHUT_RDWR);
  __close(ASock);
{$IFEND}
end;

function CloseSocketGraceful(ASock: TSocketHandle; ATimeoutMS: Integer): Integer;
var
  LBuf:   array[0..1023] of Byte;
  LLeft:  Integer;
  LSlice: Integer;
  LRc:    Integer;
begin
  Result := 1;                       // assume the budget expires
  if ASock = INVALID_SOCKET_HANDLE then Exit(0);

  // FIN only. SHUT_WR leaves queued output to drain; it is the half that
  // SHUT_RDWR gets wrong for a socket that has just been written to.
{$IF DEFINED(FPC)}
  fpShutdown(ASock, 1);   // SHUT_WR
{$ELSEIF DEFINED(MSWINDOWS)}
  shutdown(ASock, SD_SEND);
{$ELSE}
  shutdown(ASock, SHUT_WR);
{$IFEND}

  { Drain until the peer's own FIN arrives. Two jobs: it empties the receive
    queue so close() has no reason to emit RST, and the peer's FIN is the only
    real evidence our bytes were read. Bytes read here are discarded — the
    session is over. }
  LLeft := ATimeoutMS;
  if LLeft < 0 then LLeft := 0;
  while LLeft > 0 do
  begin
    LSlice := LLeft;
    if LSlice > 25 then LSlice := 25;

    LRc := SocketWaitReadable(ASock, LSlice);
    if LRc < 0 then begin Result := -1; Break; end;
    if LRc > 0 then
    begin
      LRc := SocketRecv(ASock, @LBuf[0], SizeOf(LBuf));
      if LRc = 0 then begin Result := 0; Break; end;     // peer FIN
      if LRc < 0 then begin Result := -1; Break; end;
      Continue;                      // real data: keep draining, same budget
    end;

    Dec(LLeft, LSlice);
  end;

  CloseSocketHandle(ASock);
end;


initialization
{$IF DEFINED(MSWINDOWS) AND NOT DEFINED(FPC)}
  InitSockets;
{$IFEND}
{$IF DEFINED(UNIX) OR DEFINED(POSIX)}
  { Ignore SIGPIPE, whose default action is to TERMINATE THE PROCESS.

    Writing to a socket whose peer has closed is an ordinary, expected event
    for a server — a client that got its response and hung up, a connection
    reset mid-write. Left at the default, any such write kills the whole
    server: every connection, not just that one. Observed as exit code 141
    (128 + SIGPIPE) with no exception and no message, because a signal death
    produces neither. With it ignored, the write simply returns EPIPE and the
    existing error paths handle it.

    Here, in the transport, rather than in each app-type unit. The Daemon
    shapes across every provider already do this, but the Console shape — the
    default, and what the test binaries use — did not, so whether a peer
    hangup could kill the process depended on how the binary was packaged.
    Setting it once at the socket layer covers server, client and every shape.

    Also covers OpenSSL: SSL_write goes through write(2) underneath, so a
    per-call MSG_NOSIGNAL would not have protected the TLS path. }
  {$IF DEFINED(FPC)}
  fpSignal(SIGPIPE, signalhandler(SIG_IGN));
  {$ELSE}
  signal(SIGPIPE, TSignalHandler(SIG_IGN));
  {$IFEND}
{$IFEND}

finalization
{$IF DEFINED(MSWINDOWS) AND NOT DEFINED(FPC)}
  ShutdownSockets;
{$IFEND}

end.
