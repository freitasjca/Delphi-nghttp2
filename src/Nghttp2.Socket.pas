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
//  Only IPv4 in v1. Blocking I/O. No select/poll — the server pumps one
//  thread per connection.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Sockets;
{$ELSEIF DEFINED(MSWINDOWS)}
  System.SysUtils, Winapi.WinSock2;
{$ELSE}
  System.SysUtils, Posix.Base, Posix.SysSocket, Posix.SysTypes,
  Posix.NetinetIn, Posix.ArpaInet, Posix.Unistd, Posix.Errno;
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

procedure InitSockets;
procedure ShutdownSockets;

// Bind + listen on all interfaces (0.0.0.0), IPv4, given port + backlog.
// Sets SO_REUSEADDR. Raises ENghttp2Socket on any step failure.
function CreateListenerSocket(APort: Word; ABacklog: Integer): TSocketHandle;

// Accept next incoming connection (blocking). Returns INVALID_SOCKET_HANDLE
// on error (which the caller uses as a signal to exit the accept loop, e.g.
// after a peer-side CloseSocketHandle on the listener during Stop).
// APeerAddr is filled with the client's dotted-quad IPv4 address.
function AcceptConnection(ALSock: TSocketHandle; out APeerAddr: string): TSocketHandle;

// Client-side TCP connect. AHost must be an IPv4 literal ("127.0.0.1", "10.0.0.5"
// etc.) — DNS resolution is out of scope for v1; add getaddrinfo later if needed.
// Raises ENghttp2Socket on socket()/connect() failure. On success returns a
// connected socket that the caller owns and must eventually CloseSocketHandle.
function ConnectToHost(const AHost: string; APort: Word): TSocketHandle;

// Blocking recv. Returns bytes read (1..ALen), 0 on peer close, -1 on error.
function SocketRecv(ASock: TSocketHandle; ABuf: Pointer; ALen: Integer): Integer;

// Blocking send. Returns bytes written (1..ALen) or -1 on error. May return
// short — use SocketSendAll for full-buffer writes.
function SocketSend(ASock: TSocketHandle; ABuf: Pointer; ALen: Integer): Integer;

// Loops over SocketSend until ALen bytes are written or an error occurs.
// Returns True iff every byte was written.
function SocketSendAll(ASock: TSocketHandle; ABuf: Pointer; ALen: Integer): Boolean;

// Hard close — no shutdown, socket becomes unusable immediately.
procedure CloseSocketHandle(ASock: TSocketHandle);

// Graceful close — half-close both directions, then close.
procedure ShutdownSocketHandle(ASock: TSocketHandle);

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

function CreateListenerSocket(APort: Word; ABacklog: Integer): TSocketHandle;
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

  Result := LSock;
end;
{$IFEND}

// ─── ConnectToHost ────────────────────────────────────────────────────────
// Cross-platform client TCP connect. Mirrors CreateListenerSocket's 3-branch
// FPC / MSWINDOWS / Delphi POSIX structure. IPv4 literal only in v1.

function ConnectToHost(const AHost: string; APort: Word): TSocketHandle;
{$IF DEFINED(FPC)}
var
  LSock: LongInt;
  LAddr: TInetSockAddr;
  LHostAnsi: AnsiString;
begin
  LSock := fpSocket(AF_INET, SOCK_STREAM, 0);
  if LSock < 0 then
    raise ENghttp2Socket.Create('fpSocket failed');

  FillChar(LAddr, SizeOf(LAddr), 0);
  LAddr.sin_family := AF_INET;
  LAddr.sin_port   := htons(APort);
  LHostAnsi        := AnsiString(AHost);
  LAddr.sin_addr.s_addr := StrToNetAddr(LHostAnsi).s_addr;

  if fpConnect(LSock, @LAddr, SizeOf(LAddr)) < 0 then
  begin
    CloseSocket(LSock);
    raise ENghttp2Socket.CreateFmt('fpConnect(%s:%d) failed', [AHost, APort]);
  end;
  Result := LSock;
end;
{$ELSEIF DEFINED(MSWINDOWS)}
var
  LSock: TSocket;
  LAddr: sockaddr_in;
  LHostAnsi: AnsiString;
  LWsaErr: Integer;
begin
  InitSockets;

  LSock := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if LSock = INVALID_SOCKET then
    raise ENghttp2Socket.CreateFmt('socket() failed: WSA=%d', [WSAGetLastError]);

  FillChar(LAddr, SizeOf(LAddr), 0);
  LAddr.sin_family := AF_INET;
  LAddr.sin_port   := htons(APort);
  LHostAnsi        := AnsiString(AHost);
  LAddr.sin_addr.S_addr := inet_addr(PAnsiChar(LHostAnsi));
  if LAddr.sin_addr.S_addr = INADDR_NONE then
  begin
    closesocket(LSock);
    raise ENghttp2Socket.CreateFmt(
      'inet_addr(%s) failed — pass an IPv4 literal (DNS not implemented in v1)',
      [AHost]);
  end;

  if Winapi.WinSock2.connect(LSock, TSockAddr(LAddr), SizeOf(LAddr)) = SOCKET_ERROR then
  begin
    // Capture WSA error BEFORE closesocket — closesocket clears the last
    // WSA error, leaving diagnostic messages like "WSA=0" that hide the real
    // failure code (typically 10061 ECONNREFUSED or 10060 ETIMEDOUT).
    LWsaErr := WSAGetLastError;
    closesocket(LSock);
    raise ENghttp2Socket.CreateFmt('connect(%s:%d) failed: WSA=%d',
      [AHost, APort, LWsaErr]);
  end;
  Result := LSock;
end;
{$ELSE}
var
  LSock: Integer;
  LAddr: sockaddr_in;
  LHostAnsi: AnsiString;
begin
  LSock := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if LSock < 0 then
    raise ENghttp2Socket.CreateFmt('socket() failed: errno=%d', [errno]);

  FillChar(LAddr, SizeOf(LAddr), 0);
  LAddr.sin_family := AF_INET;
  LAddr.sin_port   := htons(APort);
  LHostAnsi        := AnsiString(AHost);
  LAddr.sin_addr.s_addr := inet_addr(PAnsiChar(LHostAnsi));

  if connect(LSock, sockaddr(LAddr), SizeOf(LAddr)) < 0 then
  begin
    __close(LSock);
    raise ENghttp2Socket.CreateFmt('connect(%s:%d) failed: errno=%d',
      [AHost, APort, errno]);
  end;
  Result := LSock;
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

initialization
{$IF DEFINED(MSWINDOWS) AND NOT DEFINED(FPC)}
  InitSockets;
{$IFEND}

finalization
{$IF DEFINED(MSWINDOWS) AND NOT DEFINED(FPC)}
  ShutdownSockets;
{$IFEND}

end.
