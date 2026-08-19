unit Nghttp2.Tls;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Nghttp2.Tls
//  High-level TLS server helpers on top of Nghttp2.OpenSSL FFI.
//
//  Provides:
//    - TTlsServerContext — one SSL_CTX per server, loads PEM cert+key,
//      installs an ALPN select callback that ONLY negotiates 'h2'.
//    - TTlsConnection    — per-accepted-socket wrapper: SSL_accept handshake,
//      SSL_read/write helpers, graceful shutdown. Discards non-h2 clients.
//
//  Rationale for h2-only ALPN:
//    HTTP/2 over TLS (h2) requires ALPN per RFC 7540 §3.4. If we accept the
//    connection but don't negotiate h2, we'd be trapped in an HTTP/1.1
//    handshake we can't serve. Rejecting non-h2 clients at ALPN time is the
//    cleanest failure mode — the client falls back to plain HTTP or reports
//    an ALPN failure to the user.
//
//  Cross-platform: this unit uses only the FFI vars from Nghttp2.OpenSSL,
//  plus SysUtils/Classes. No platform-specific #ifdefs.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
  System.AnsiStrings,   { StrLen for PAnsiChar — SysUtils.StrLen is deprecated on Delphi 12 }
{$IFEND}
  Nghttp2.OpenSSL;

type
  ENghttp2Tls = class(Exception);

  { Outcome of a non-blocking TLS operation.

    The two WANT states are NOT errors. They name the readiness the caller
    must wait for before calling the same operation again, and getting them
    wrong is the classic event-loop TLS bug in both directions: treat
    tisWantRead as failure and healthy connections die at random under load;
    ignore it and the loop spins a core at 100%.

    Note that the direction TLS wants is not the direction the application
    wants. A WRITE can return tisWantRead — a renegotiation needs peer bytes
    before it can encrypt — and a READ can return tisWantWrite. An engine that
    registers readiness based on what the application asked for, rather than
    on what these values say, will hang on exactly those cases. }
  TTlsIoState = (
    tisOk,          // completed; for Read/Write see the out byte count
    tisWantRead,    // call again once the socket is readable
    tisWantWrite,   // call again once the socket is writable
    tisClosed,      // peer closed cleanly (TCP FIN or TLS close_notify)
    tisError        // fatal; tear the connection down
  );

  { Owns one SSL_CTX for the lifetime of the server. Load cert+key ONCE at
    startup; every accepted connection borrows the same context via
    TTlsConnection.Create(AContext, ASocket). }
  TTlsServerContext = class
  strict private
    FCtx:      PSSL_CTX;
    FPassword: AnsiString;    // holds password bytes so cb_userdata pointer stays valid
    function GetHandle: PSSL_CTX;
  public
    // Constructs an empty context. Call LoadCertificate + LoadPrivateKey
    // before serving. Raises ENghttp2Tls if OpenSSL isn't loadable.
    constructor Create;
    destructor  Destroy; override;

    // Set the password OpenSSL should use when decrypting an encrypted PEM
    // key. MUST be called BEFORE LoadPrivateKeyFile. The password is held on
    // the TTlsServerContext (via FPassword AnsiString) for the object's
    // lifetime — safe because SSL_CTX and TTlsServerContext have matching
    // scope. For unencrypted keys, don't call this.
    procedure SetPrivateKeyPassword(const APassword: string);

    // Load PEM-encoded cert + key from disk. On mismatch or missing file,
    // raises ENghttp2Tls with the OpenSSL error queue's top message appended.
    procedure LoadCertificateFile(const APath: string);
    procedure LoadPrivateKeyFile(const APath: string);

    // Called after both files are loaded — verifies the key matches the cert.
    // Raises on mismatch. Optional but recommended: SSL_accept would fail
    // with a cryptic error otherwise.
    procedure CheckKeyMatch;

    // Install the ALPN select callback that accepts ONLY 'h2'. Call after
    // LoadCertificateFile+LoadPrivateKeyFile, before serving. Idempotent.
    procedure EnableHttp2Alpn;

    // Enable mutual TLS — every accepted connection must present a client
    // certificate signed by the CA in ACaFile. Clients without a cert (or
    // with an untrusted one) get the handshake rejected. Combines two
    // OpenSSL calls: SSL_CTX_load_verify_locations to trust the CA, and
    // SSL_CTX_set_verify with PEER | FAIL_IF_NO_PEER_CERT.
    // Call after LoadCertificateFile+LoadPrivateKeyFile+EnableHttp2Alpn,
    // before serving.
    procedure EnableClientCertVerification(const ACaFile: string);

    property Handle: PSSL_CTX read GetHandle;
  end;

  { Per-accepted-socket TLS wrapper. Own lifecycle: Create → DoHandshake →
    Read/Write in a loop → Free. }
  { Memory-BIO TLS connection.

    OpenSSL is never given the socket. Ciphertext moves through two in-memory
    BIOs and this class performs every socket read and write itself:

      send:  SSL_write(plain) → BIO_read(FBioOut)  → socket
      recv:  socket → BIO_write(FBioIn) → SSL_read(plain)

    Previously this used SSL_set_fd, which let OpenSSL block inside its own
    read()/write(). That is fine for a thread-per-connection server and
    impossible for an event loop, because nothing outside OpenSSL can tell
    when the descriptor is ready or bound how long a call will park. Moving
    the socket I/O out here is the prerequisite for driving TLS from epoll or
    IOCP, and is the structure Delphi-Cross-Socket uses over its engines.

    Behaviour is unchanged for the current blocking pump: Read and Write keep
    the same signatures and the same "bytes, 0 on clean close, <0 on error"
    contract. }
  TTlsConnection = class
  strict private
    FCtx:    TTlsServerContext;
    FSocket: Integer;
    FSSL:    PSSL;
    FBioIn:  PBIO;   // ciphertext IN  — we write, OpenSSL reads
    FBioOut: PBIO;   // ciphertext OUT — OpenSSL writes, we read

    { Non-blocking mode state. Every field in this class must be declared
      before the first method — both dcc and fpc reject a field that follows
      a method within one visibility section (E2169 / "start a new visibility
      section first"). }
    FNonBlocking: Boolean;
    // Ciphertext pulled out of FBioOut that the socket has not accepted yet.
    // Required in non-blocking mode and meaningless outside it: a short write
    // must not lose the remainder, and it cannot be pushed back into the BIO.
    FOutPending: TBytes;
    FOutUsed:    Integer;   // bytes of FOutPending still to send, from index 0

    // Drains FBioOut to the socket. False on send failure.
    function FlushOut: Boolean;
    // Reads ciphertext from the socket into FBioIn.
    // >0 bytes fed · 0 peer closed · <0 socket error.
    function FeedIn: Integer;

    { ── Non-blocking counterparts ────────────────────────────────────────
      Deliberately separate routines rather than a mode branch inside the two
      above. The blocking pair is what every shipped suite exercises, and
      keeping it literally untouched is what lets the same suites validate
      this addition. }
    procedure SetNonBlocking(AValue: Boolean);
    // Appends everything in FBioOut to FOutPending, then sends as much as the
    // socket will take. tisOk = nothing left · tisWantWrite = remainder held.
    function FlushOutNB: TTlsIoState;
    // Non-blocking FeedIn. >0 fed · 0 peer closed · SOCKET_WOULD_BLOCK ·
    // -1 error.
    function FeedInNB: Integer;
  public
    constructor Create(const AContext: TTlsServerContext; ASocket: Integer);
    destructor  Destroy; override;

    // Runs SSL_accept, blocks until handshake completes or fails. Raises
    // ENghttp2Tls on failure. On success the client's ALPN choice is
    // available via NegotiatedProtocol — should equal 'h2'.
    procedure DoHandshake;

    // Returns the ALPN-selected protocol string (typically 'h2') or empty
    // if the client didn't send ALPN. Empty is a caller-decision failure —
    // for h2c-only servers running on the TLS port, reject the connection.
    function NegotiatedProtocol: string;

    // Blocking read/write helpers with the same semantics as our Nghttp2.Socket
    // SocketRecv/SocketSend (bytes returned, negative on error). Automatically
    // handle SSL_ERROR_WANT_READ/WANT_WRITE by retrying on the same fd.
    function Read(ABuf: Pointer; ALen: Integer): Integer;
    function Write(ABuf: Pointer; ALen: Integer): Integer;

    // Application bytes already decrypted and buffered inside OpenSSL, i.e.
    // readable without the socket becoming readable again. A pump that waits
    // on select() before every Read must check this first — one TLS record
    // can decrypt to more bytes than a single Read consumes, and select()
    // cannot see the remainder.
    function Pending: Integer;

    // Best-effort graceful close (SSL_shutdown). Doesn't wait for the peer's
    // close_notify — that's a caller-optional politeness.
    procedure Shutdown;

    { ── Non-blocking API — for an event-loop engine ──────────────────────
      Setting NonBlocking also puts the underlying socket into the matching
      mode, so the flag and the descriptor can never disagree. Mixing the two
      APIs on one connection is not supported: pick a mode before the
      handshake and stay in it. }
    property NonBlocking: Boolean read FNonBlocking write SetNonBlocking;

    { One resumable step of SSL_accept. Call again on the readiness it
      returns; tisOk means the handshake is complete and NegotiatedProtocol
      is meaningful.

      Note tisWantWrite after a *successful* SSL_accept: the final handshake
      flight was produced but the socket did not take all of it. The
      handshake is not done until those bytes leave, so the engine must
      flush before treating the connection as established. }
    function HandshakeStep: TTlsIoState;

    // Non-blocking Read/Write. ARead/AWritten are only meaningful on tisOk.
    function ReadNB(ABuf: Pointer; ALen: Integer; out ARead: Integer): TTlsIoState;
    function WriteNB(ABuf: Pointer; ALen: Integer; out AWritten: Integer): TTlsIoState;

    // True while ciphertext is held waiting for the socket to drain. An
    // engine must keep watching for writability until this goes false, or
    // the tail of a response is never sent.
    function HasPendingOutput: Boolean;

    // Push held ciphertext after a writable event. Same states as FlushOutNB.
    function FlushPendingOutput: TTlsIoState;

    property SSL: PSSL read FSSL;
  end;

// ─── Standalone ALPN select callback (server-side) ───────────────────────
// Referenced by TTlsServerContext.EnableHttp2Alpn. Exposed here in the
// interface so callers who want a customised ALPN policy can reference
// the reusable 'h2 preferred' scanner from a wrapper of their own.
function AlpnSelectH2Only(
  ssl: PSSL;
  var out_: PByte;
  var outlen: Byte;
  const in_: PByte;
  inlen: Cardinal;
  arg: Pointer): Integer; cdecl;

// ============================================================================
// Client-side TLS
// ============================================================================

type
  { Owns one SSL_CTX for the lifetime of a client (or client-pool). Configure
    once at startup — set cert verification mode, install ALPN 'h2' advertise —
    then create per-request TTlsClientConnection instances against it. }
  TTlsClientContext = class
  strict private
    FCtx:      PSSL_CTX;
    FPassword: AnsiString;    // key-password holder — same lifetime rule as server
    function GetHandle: PSSL_CTX;
  public
    // Constructs an empty client context. Raises ENghttp2Tls if OpenSSL
    // isn't loadable. Cert verification is ENABLED by default (SSL_VERIFY_PEER)
    // — call SetInsecure to disable for testing against self-signed certs.
    constructor Create;
    destructor  Destroy; override;

    // Disable server certificate verification. Use ONLY for local testing
    // against self-signed certs — production clients must verify.
    procedure SetInsecure;

    // Advertise 'h2' as the sole ALPN protocol. The server picks it (if it
    // supports h2) or declines. We fail hard on any other selection —
    // there's no HTTP/1.1 fallback in this client.
    procedure EnableHttp2Alpn;

    // mTLS — present a client certificate + key during TLS handshake. Server
    // must trust this cert's issuer (via SSL_CTX_load_verify_locations on
    // its side) or handshake fails. Password is optional (empty = key is
    // not encrypted). Call BEFORE using this context in Connect.
    procedure SetClientCertificate(const ACertFile, AKeyFile: string;
      const AKeyPassword: string = '');

    property Handle: PSSL_CTX read GetHandle;
  end;

  { Per-connection TLS wrapper on the client side. Own lifecycle: Create →
    DoHandshake → Read/Write in a loop → Free. Same shape as TTlsConnection
    (server) but calls SSL_connect instead of SSL_accept. }
  // Client side of the same memory-BIO design as TTlsConnection — see the
  // comment there for why OpenSSL is kept away from the socket.
  TTlsClientConnection = class
  strict private
    FCtx:    TTlsClientContext;
    FSocket: Integer;
    FSSL:    PSSL;
    FBioIn:  PBIO;
    FBioOut: PBIO;
    function FlushOut: Boolean;
    function FeedIn: Integer;
  public
    constructor Create(const AContext: TTlsClientContext; ASocket: Integer);
    destructor  Destroy; override;

    // Runs SSL_connect, blocks until handshake completes or fails.
    // Raises ENghttp2Tls on failure.
    procedure DoHandshake;

    // Returns the ALPN-selected protocol string (typically 'h2'). Empty if
    // the server didn't select anything from our advertised list — treat as
    // failure and abandon the connection (no HTTP/1.1 fallback here).
    function NegotiatedProtocol: string;

    // Same I/O contract as TTlsConnection.Read/Write — bytes returned,
    // negative on error. SSL_ERROR_WANT_READ/WANT_WRITE handled internally.
    function Read(ABuf: Pointer; ALen: Integer): Integer;
    function Write(ABuf: Pointer; ALen: Integer): Integer;

    // Best-effort SSL_shutdown before socket close.
    procedure Shutdown;

    property SSL: PSSL read FSSL;
  end;

implementation

uses
  { Memory-BIO TLS performs its own socket I/O — see TTlsConnection. Kept in
    the implementation section: nothing in the interface names a socket type,
    so the dependency stays private. Safe direction either way — Nghttp2.Socket
    knows nothing about TLS. }
  Nghttp2.Socket;

// ─── Error helpers ───────────────────────────────────────────────────────

function SslErrorName(ACode: Integer): string;
begin
  case ACode of
    SSL_ERROR_NONE:             Result := 'NONE';
    SSL_ERROR_SSL:              Result := 'SSL';
    SSL_ERROR_WANT_READ:        Result := 'WANT_READ';
    SSL_ERROR_WANT_WRITE:       Result := 'WANT_WRITE';
    SSL_ERROR_WANT_X509_LOOKUP: Result := 'WANT_X509_LOOKUP';
    SSL_ERROR_SYSCALL:          Result := 'SYSCALL';
    SSL_ERROR_ZERO_RETURN:      Result := 'ZERO_RETURN';
    SSL_ERROR_WANT_CONNECT:     Result := 'WANT_CONNECT';
    SSL_ERROR_WANT_ACCEPT:      Result := 'WANT_ACCEPT';
  else                          Result := 'UNKNOWN(' + IntToStr(ACode) + ')';
  end;
end;

procedure RaiseTls(const AWhere: string; AResult: Integer; ASsl: PSSL);
var
  LSslErr: Integer;
  LErrStr: string;
begin
  LErrStr := NghttpsslLastError;
  if ASsl <> nil then
  begin
    LSslErr := SSL_get_error(ASsl, AResult);
    raise ENghttp2Tls.CreateFmt('%s failed: SSL_get_error=%d (%s), ERR=%s',
      [AWhere, LSslErr, SslErrorName(LSslErr), LErrStr]);
  end
  else
    raise ENghttp2Tls.CreateFmt('%s failed: ERR=%s', [AWhere, LErrStr]);
end;

// ─── ALPN select callback ────────────────────────────────────────────────
// Client sends a length-prefixed list of protocol names:
//   [len1][proto1_bytes][len2][proto2_bytes]...[lenN][protoN_bytes]
// We scan for 'h2' (2 bytes: 'h','2'). If found, set out_ to point into the
// input buffer at that entry (OpenSSL is fine with in-place references —
// it copies before returning to the client). If not found, return NOACK
// which causes OpenSSL to skip the ALPN extension entirely — the client
// then sees no ALPN response and typically aborts the connection.

function AlpnSelectH2Only(
  ssl: PSSL;
  var out_: PByte;
  var outlen: Byte;
  const in_: PByte;
  inlen: Cardinal;
  arg: Pointer): Integer; cdecl;
var
  LPos: Cardinal;
  LLen: Byte;
  LP:   PByte;
begin
  LPos := 0;
  while LPos < inlen do
  begin
    LP   := PByte(NativeUInt(in_) + LPos);
    LLen := LP^;
    if (LPos + 1 + LLen > inlen) then
      Break;   // malformed — bail out
    if (LLen = 2)
       and (PByte(NativeUInt(LP) + 1)^ = Ord('h'))
       and (PByte(NativeUInt(LP) + 2)^ = Ord('2')) then
    begin
      out_   := PByte(NativeUInt(LP) + 1);   // skip the length byte
      outlen := LLen;
      Exit(SSL_TLSEXT_ERR_OK);
    end;
    Inc(LPos, 1 + LLen);
  end;
  // Client didn't offer h2 — refuse ALPN. Depending on client this either
  // proceeds without ALPN (curl in some modes) or fails hard (Chrome, etc.).
  // Either way we don't get an HTTP/1.1 client that we can't serve.
  Result := SSL_TLSEXT_ERR_NOACK;
end;

// ─── PEM password callback ──────────────────────────────────────────────
// Fired by OpenSSL when decoding an encrypted private key. The `u` param is
// the userdata pointer we installed via SSL_CTX_set_default_passwd_cb_userdata
// — pointing at the AnsiString bytes on TTlsServerContext.FPassword.
// Copies up to `size` bytes of the password into `buf`, returns the byte
// count. Returning 0 aborts the key load with an "invalid password" error.

function PemPasswordCallback(
  buf:    PAnsiChar;
  size:   Integer;
  rwflag: Integer;   // 0 = read (decrypting existing key), 1 = write (writing new key)
  u:      Pointer): Integer; cdecl;
var
  LPwd: PAnsiChar;
  LLen: Integer;
begin
  LPwd := PAnsiChar(u);
  if (LPwd = nil) or (LPwd^ = #0) then Exit(0);

{$IFDEF FPC}
  LLen := StrLen(LPwd);
{$ELSE}
  // System.SysUtils.StrLen is deprecated on Delphi 12+ ("Moved to the
  // AnsiStrings unit"). Qualify explicitly to silence W1000 — the
  // non-qualified name resolves via LAST-imported-unit rules and may pick
  // the SysUtils version even with System.AnsiStrings in uses.
  LLen := System.AnsiStrings.StrLen(LPwd);
{$ENDIF}
  if LLen > size then LLen := size;
  Move(LPwd^, buf^, LLen);
  Result := LLen;
end;

// ─── TTlsServerContext ──────────────────────────────────────────────────

constructor TTlsServerContext.Create;
begin
  inherited Create;
  if not NghttpsslLoad then
    raise ENghttp2Tls.CreateFmt(
      'OpenSSL could not be loaded: %s' + sLineBreak +
      'Install libssl-3-x64.dll + libcrypto-3-x64.dll (or the 1.1.x equivalents) ' +
      'and ensure they are on the runtime DLL search path (next to the exe is easiest). ' +
      'Also install the Microsoft Visual C++ Runtime Redistributable — the OpenSSL DLLs ' +
      'depend on msvcp140.dll / vcruntime140.dll from that redist.',
      [NghttpsslLoadError]);

  FCtx := SSL_CTX_new(TLS_server_method());
  if FCtx = nil then
    RaiseTls('SSL_CTX_new', 0, nil);
end;

destructor TTlsServerContext.Destroy;
begin
  if FCtx <> nil then
  begin
    SSL_CTX_free(FCtx);
    FCtx := nil;
  end;
  inherited;
end;

function TTlsServerContext.GetHandle: PSSL_CTX;
begin
  Result := FCtx;
end;

procedure TTlsServerContext.SetPrivateKeyPassword(const APassword: string);
begin
  // Hold the password as an AnsiString on Self so the pointer we hand to
  // OpenSSL stays valid across the LoadPrivateKeyFile call (the callback
  // fires from inside PEM_read_bio_PrivateKey during that load).
  FPassword := AnsiString(APassword);

  SSL_CTX_set_default_passwd_cb(FCtx, @PemPasswordCallback);
  // Pointer(FPassword) yields a PAnsiChar to the string's first byte, or nil
  // if the AnsiString is empty. Either way, the callback handles both.
  SSL_CTX_set_default_passwd_cb_userdata(FCtx, Pointer(FPassword));
end;

procedure TTlsServerContext.LoadCertificateFile(const APath: string);
var
  LPathAnsi: AnsiString;
begin
  LPathAnsi := AnsiString(APath);
  if SSL_CTX_use_certificate_file(FCtx, PAnsiChar(LPathAnsi), SSL_FILETYPE_PEM) <> 1 then
    raise ENghttp2Tls.CreateFmt(
      'SSL_CTX_use_certificate_file(%s) failed: %s', [APath, NghttpsslLastError]);
end;

procedure TTlsServerContext.LoadPrivateKeyFile(const APath: string);
var
  LPathAnsi: AnsiString;
begin
  LPathAnsi := AnsiString(APath);
  if SSL_CTX_use_PrivateKey_file(FCtx, PAnsiChar(LPathAnsi), SSL_FILETYPE_PEM) <> 1 then
    raise ENghttp2Tls.CreateFmt(
      'SSL_CTX_use_PrivateKey_file(%s) failed: %s', [APath, NghttpsslLastError]);
end;

procedure TTlsServerContext.CheckKeyMatch;
begin
  if SSL_CTX_check_private_key(FCtx) <> 1 then
    raise ENghttp2Tls.CreateFmt(
      'SSL_CTX_check_private_key: cert and key don''t match — %s',
      [NghttpsslLastError]);
end;

procedure TTlsServerContext.EnableHttp2Alpn;
begin
  SSL_CTX_set_alpn_select_cb(FCtx, @AlpnSelectH2Only, nil);
end;

procedure TTlsServerContext.EnableClientCertVerification(const ACaFile: string);
var
  LCaAnsi: AnsiString;
begin
  LCaAnsi := AnsiString(ACaFile);
  if SSL_CTX_load_verify_locations(FCtx, PAnsiChar(LCaAnsi), nil) <> 1 then
    raise ENghttp2Tls.CreateFmt(
      'SSL_CTX_load_verify_locations(%s) failed: %s' + sLineBreak +
      'Ensure the CA file exists and is a valid PEM-encoded X.509 certificate.',
      [ACaFile, NghttpsslLastError]);

  // PEER = ask the client for a cert.
  // FAIL_IF_NO_PEER_CERT = reject the handshake if it doesn't send one.
  // (SSL_VERIFY_PEER alone lets anonymous clients through — not what mTLS means.)
  SSL_CTX_set_verify(FCtx,
    SSL_VERIFY_PEER or SSL_VERIFY_FAIL_IF_NO_PEER_CERT,
    nil);
end;

// ─── TTlsConnection ─────────────────────────────────────────────────────

constructor TTlsConnection.Create(const AContext: TTlsServerContext; ASocket: Integer);
begin
  inherited Create;
  if AContext = nil then
    raise ENghttp2Tls.Create('TTlsConnection.Create: AContext is nil');

  FCtx    := AContext;
  FSocket := ASocket;

  FSSL := SSL_new(AContext.Handle);
  if FSSL = nil then
    RaiseTls('SSL_new', 0, nil);

  FBioIn  := BIO_new(BIO_s_mem());
  FBioOut := BIO_new(BIO_s_mem());
  if (FBioIn = nil) or (FBioOut = nil) then
  begin
    SSL_free(FSSL);   // frees any BIO already attached; these are not yet
    FSSL := nil;
    RaiseTls('BIO_new', 0, nil);
  end;

  // SSL takes ownership of both BIOs — SSL_free releases them, so they must
  // never be freed separately.
  SSL_set_bio(FSSL, FBioIn, FBioOut);
end;

function TTlsConnection.FlushOut: Boolean;
var
  LBuf: array[0..16383] of Byte;   // one TLS record max is ~16 KB + overhead
  LLen: Integer;
begin
  Result := True;
  if FSSL = nil then Exit;
  // BIO_read returns <=0 when the buffer is empty, which is the normal exit.
  repeat
    LLen := BIO_read(FBioOut, @LBuf[0], SizeOf(LBuf));
    if LLen <= 0 then Break;
    if not SocketSendAll(TSocketHandle(FSocket), @LBuf[0], LLen) then
      Exit(False);
  until False;
end;

function TTlsConnection.FeedIn: Integer;
var
  LBuf: array[0..16383] of Byte;
begin
  Result := SocketRecv(TSocketHandle(FSocket), @LBuf[0], SizeOf(LBuf));
  if Result <= 0 then Exit;        // 0 = peer closed, <0 = socket error
  if BIO_write(FBioIn, @LBuf[0], Result) <= 0 then
    Exit(-1);
end;

// ─── Non-blocking transport helpers ──────────────────────────────────────

procedure TTlsConnection.SetNonBlocking(AValue: Boolean);
begin
  if FNonBlocking = AValue then Exit;
  // Flag and descriptor are set together on purpose. Held apart they drift,
  // and the failure is silent: the NB routines run against a still-blocking
  // socket and park an engine thread that is meant to serve many connections.
  if not SetSocketNonBlocking(TSocketHandle(FSocket), AValue) then
    raise ENghttp2Tls.Create('SetSocketNonBlocking failed');
  FNonBlocking := AValue;
end;

function TTlsConnection.HasPendingOutput: Boolean;
begin
  Result := FOutUsed > 0;
end;

function TTlsConnection.FlushOutNB: TTlsIoState;
var
  LBuf: array[0..16383] of Byte;
  LLen: Integer;
begin
  if FSSL = nil then Exit(tisError);

  // Drain the BIO first, unconditionally. OpenSSL's output must be taken out
  // in order and cannot be pushed back, so it accumulates here rather than
  // being left in the BIO — the only place a short write can be remembered.
  repeat
    LLen := BIO_read(FBioOut, @LBuf[0], SizeOf(LBuf));
    if LLen <= 0 then Break;
    if Length(FOutPending) < FOutUsed + LLen then
      SetLength(FOutPending, FOutUsed + LLen + 8192);
    Move(LBuf[0], FOutPending[FOutUsed], LLen);
    Inc(FOutUsed, LLen);
  until False;

  Result := FlushPendingOutput;
end;

function TTlsConnection.FlushPendingOutput: TTlsIoState;
var
  LSent: Integer;
begin
  while FOutUsed > 0 do
  begin
    LSent := SocketSendNB(TSocketHandle(FSocket), @FOutPending[0], FOutUsed);
    if LSent = SOCKET_WOULD_BLOCK then
      Exit(tisWantWrite);
    if LSent <= 0 then
      Exit(tisError);
    Dec(FOutUsed, LSent);
    if FOutUsed > 0 then
      // Short write: shuffle the tail down. Cheap at these sizes, and it
      // keeps every other routine free of an offset it would have to respect.
      Move(FOutPending[LSent], FOutPending[0], FOutUsed);
  end;
  Result := tisOk;
end;

function TTlsConnection.FeedInNB: Integer;
var
  LBuf: array[0..16383] of Byte;
begin
  Result := SocketRecvNB(TSocketHandle(FSocket), @LBuf[0], SizeOf(LBuf));
  if Result <= 0 then Exit;          // 0 closed · -1 error · -2 would block
  if BIO_write(FBioIn, @LBuf[0], Result) <= 0 then
    Exit(-1);
end;

destructor TTlsConnection.Destroy;
begin
  if FSSL <> nil then
  begin
    SSL_free(FSSL);
    FSSL := nil;
  end;
  inherited;
end;

procedure TTlsConnection.DoHandshake;
var
  LRet, LErr, LFed: Integer;
begin
  { With memory BIOs SSL_accept can no longer reach the socket itself, so it
    returns WANT_READ/WANT_WRITE instead of blocking. Each pass: let OpenSSL
    advance as far as it can, push whatever handshake bytes it produced, and
    feed it more from the peer. Flushing on every pass matters — OpenSSL
    often has output ready even when it reports WANT_READ, and withholding it
    deadlocks both sides waiting on each other. }
  repeat
    LRet := SSL_accept(FSSL);

    if not FlushOut then
      RaiseTls('SSL_accept (send)', 0, nil);

    if LRet = 1 then
      Exit;                       // handshake complete

    LErr := SSL_get_error(FSSL, LRet);
    case LErr of
      SSL_ERROR_WANT_READ:
        begin
          LFed := FeedIn;
          if LFed <= 0 then
            RaiseTls('SSL_accept (peer closed during handshake)', LRet, FSSL);
        end;
      SSL_ERROR_WANT_WRITE:
        ;                         // already flushed above; loop again
    else
      RaiseTls('SSL_accept', LRet, FSSL);
    end;
  until False;
end;

function TTlsConnection.NegotiatedProtocol: string;
var
  LData: PByte;
  LLen:  Cardinal;
begin
  LData := nil;
  LLen  := 0;
  SSL_get0_alpn_selected(FSSL, LData, LLen);
  if (LData = nil) or (LLen = 0) then
    Exit('');
  SetString(Result, PAnsiChar(LData), LLen);
end;

function TTlsConnection.Read(ABuf: Pointer; ALen: Integer): Integer;
var
  LErr, LFed: Integer;
begin
  repeat
    Result := SSL_read(FSSL, ABuf, ALen);
    if Result > 0 then Exit;

    LErr := SSL_get_error(FSSL, Result);
    case LErr of
      SSL_ERROR_WANT_READ:
        begin
          // SSL_read can itself produce output (session tickets, a
          // renegotiation, an alert), so push before blocking on the peer.
          if not FlushOut then Exit(-1);
          LFed := FeedIn;
          if LFed <= 0 then Exit(LFed);   // 0 = closed, <0 = socket error
        end;
      SSL_ERROR_WANT_WRITE:
        if not FlushOut then Exit(-1);
      SSL_ERROR_ZERO_RETURN:
        Exit(0);                          // clean TLS close_notify
    else
      Exit(-1);
    end;
  until False;
end;

function TTlsConnection.Write(ABuf: Pointer; ALen: Integer): Integer;
var
  LErr, LFed: Integer;
begin
  repeat
    Result := SSL_write(FSSL, ABuf, ALen);
    if Result > 0 then
    begin
      // The ciphertext is only in FBioOut at this point — nothing has reached
      // the socket until this flush. Reporting success without it would tell
      // the caller bytes were sent that are still sitting in memory.
      if not FlushOut then Exit(-1);
      Exit;
    end;

    LErr := SSL_get_error(FSSL, Result);
    case LErr of
      SSL_ERROR_WANT_WRITE:
        if not FlushOut then Exit(-1);
      SSL_ERROR_WANT_READ:
        begin
          // Renegotiation: OpenSSL needs peer input before it can encrypt.
          if not FlushOut then Exit(-1);
          LFed := FeedIn;
          if LFed <= 0 then Exit(-1);
        end;
    else
      Exit(-1);
    end;
  until False;
end;

function TTlsConnection.Pending: Integer;
begin
  if FSSL = nil then
    Exit(0);
  { Two buffers can hold readable data now, and a pump that waits on select()
    must know about both: plaintext already decrypted inside SSL, and
    ciphertext sitting in FBioIn that has not been decrypted yet. Reporting
    only the former would let the pump wait on a socket that has nothing more
    to give while a whole record sits undecrypted. }
  Result := SSL_pending(FSSL) + BIO_pending(FBioIn);
end;

// ─── Non-blocking handshake / read / write ───────────────────────────────

function TTlsConnection.HandshakeStep: TTlsIoState;
var
  LRet, LErr, LFed: Integer;
begin
  repeat
    LRet := SSL_accept(FSSL);

    // Flush every pass, before inspecting the result. OpenSSL frequently has
    // a flight ready while reporting WANT_READ, and holding it back deadlocks
    // both ends — each waiting for the other to speak first.
    Result := FlushOutNB;
    if Result = tisError then Exit;

    if LRet = 1 then
    begin
      // Handshake agreed, but if the closing flight is still buffered the
      // peer has not seen it. Reporting tisOk here would let the engine send
      // application data that arrives before the handshake completes.
      if HasPendingOutput then Exit(tisWantWrite);
      Exit(tisOk);
    end;

    LErr := SSL_get_error(FSSL, LRet);
    case LErr of
      SSL_ERROR_WANT_READ:
        begin
          LFed := FeedInNB;
          if LFed = SOCKET_WOULD_BLOCK then Exit(tisWantRead);
          if LFed = 0 then Exit(tisClosed);
          if LFed < 0 then Exit(tisError);
          // Bytes are in FBioIn now. Loop rather than return tisWantRead —
          // the engine would wait for socket readability that has already
          // been consumed, and a handshake completed by those very bytes
          // would hang until the peer happened to send more.
        end;
      SSL_ERROR_WANT_WRITE:
        // FlushOutNB above already pushed what it could, so this is genuine
        // socket backpressure. (With memory BIOs it is close to unreachable:
        // a memory BIO grows rather than filling.)
        Exit(tisWantWrite);
    else
      Exit(tisError);
    end;
  until False;
end;

function TTlsConnection.ReadNB(ABuf: Pointer; ALen: Integer;
  out ARead: Integer): TTlsIoState;
var
  LErr, LFed: Integer;
begin
  ARead := 0;
  repeat
    ARead := SSL_read(FSSL, ABuf, ALen);
    if ARead > 0 then Exit(tisOk);

    LErr := SSL_get_error(FSSL, ARead);
    ARead := 0;
    case LErr of
      SSL_ERROR_WANT_READ:
        begin
          // A read can still owe the peer bytes (session tickets, an alert,
          // a renegotiation flight). Push before waiting on the peer.
          if FlushOutNB = tisError then Exit(tisError);
          LFed := FeedInNB;
          if LFed = SOCKET_WOULD_BLOCK then Exit(tisWantRead);
          if LFed = 0 then Exit(tisClosed);
          if LFed < 0 then Exit(tisError);
          // Fed — loop and let OpenSSL decrypt.
        end;
      SSL_ERROR_WANT_WRITE:
        begin
          Result := FlushOutNB;
          if Result <> tisOk then Exit;   // tisWantWrite or tisError
        end;
      SSL_ERROR_ZERO_RETURN:
        Exit(tisClosed);                  // clean close_notify
    else
      Exit(tisError);
    end;
  until False;
end;

function TTlsConnection.WriteNB(ABuf: Pointer; ALen: Integer;
  out AWritten: Integer): TTlsIoState;
var
  LErr, LFed: Integer;
begin
  AWritten := 0;

  // Anything held from a previous short write goes first — TLS records must
  // reach the peer in order, so new plaintext cannot overtake it.
  Result := FlushPendingOutput;
  if Result <> tisOk then Exit;

  repeat
    AWritten := SSL_write(FSSL, ABuf, ALen);
    if AWritten > 0 then
    begin
      // The ciphertext is only in FBioOut at this point. Unlike the blocking
      // Write, a partial socket write here is NOT a failure: FlushOutNB keeps
      // the remainder and the caller watches for writability.
      Result := FlushOutNB;
      if Result = tisError then Exit;
      Exit(tisOk);                       // accepted in full by OpenSSL
    end;

    LErr := SSL_get_error(FSSL, AWritten);
    AWritten := 0;
    case LErr of
      SSL_ERROR_WANT_WRITE:
        begin
          Result := FlushOutNB;
          if Result <> tisOk then Exit;
        end;
      SSL_ERROR_WANT_READ:
        begin
          // Renegotiation: OpenSSL needs peer input before it can encrypt.
          // This is the case an engine gets wrong by assuming a write only
          // ever waits on writability.
          if FlushOutNB = tisError then Exit(tisError);
          LFed := FeedInNB;
          if LFed = SOCKET_WOULD_BLOCK then Exit(tisWantRead);
          if LFed = 0 then Exit(tisClosed);
          if LFed < 0 then Exit(tisError);
        end;
      SSL_ERROR_ZERO_RETURN:
        Exit(tisClosed);
    else
      Exit(tisError);
    end;
  until False;
end;

procedure TTlsConnection.Shutdown;
begin
  if FSSL = nil then Exit;
  SSL_shutdown(FSSL);   // best effort; ignore return code
  { close_notify lands in FBioOut, not on the wire — with memory BIOs nothing
    is sent until we push it. Without this the peer never sees the alert and
    reads a bare connection reset instead of a clean TLS close. Still best
    effort: the socket may already be gone, and that is not worth reporting.

    In non-blocking mode this is one attempt, not a guarantee: FlushOutNB may
    leave the alert queued behind a full send buffer. That is the right trade
    at teardown — close_notify is a courtesy, and parking an engine thread on
    a peer that has stopped reading is not. }
  if FNonBlocking then
    FlushOutNB
  else
    FlushOut;
end;

// ─── TTlsClientContext ──────────────────────────────────────────────────

constructor TTlsClientContext.Create;
begin
  inherited Create;
  if not NghttpsslLoad then
    raise ENghttp2Tls.CreateFmt(
      'OpenSSL could not be loaded: %s' + sLineBreak +
      'Install libssl-3-x64.dll + libcrypto-3-x64.dll (or the 1.1.x equivalents) ' +
      'and ensure they are on the runtime DLL search path (next to the exe is easiest).',
      [NghttpsslLoadError]);

  FCtx := SSL_CTX_new(TLS_client_method());
  if FCtx = nil then
    RaiseTls('SSL_CTX_new (client)', 0, nil);

  // Default: verify server cert. Callers explicitly opt into insecure mode.
  SSL_CTX_set_verify(FCtx, SSL_VERIFY_PEER, nil);
end;

destructor TTlsClientContext.Destroy;
begin
  if FCtx <> nil then
  begin
    SSL_CTX_free(FCtx);
    FCtx := nil;
  end;
  inherited;
end;

function TTlsClientContext.GetHandle: PSSL_CTX;
begin
  Result := FCtx;
end;

procedure TTlsClientContext.SetInsecure;
begin
  SSL_CTX_set_verify(FCtx, SSL_VERIFY_NONE, nil);
end;

procedure TTlsClientContext.SetClientCertificate(const ACertFile, AKeyFile: string;
  const AKeyPassword: string);
var
  LCertAnsi, LKeyAnsi: AnsiString;
begin
  // Password FIRST (before key load), same rule as server side.
  if AKeyPassword <> '' then
  begin
    FPassword := AnsiString(AKeyPassword);
    SSL_CTX_set_default_passwd_cb(FCtx, @PemPasswordCallback);
    SSL_CTX_set_default_passwd_cb_userdata(FCtx, Pointer(FPassword));
  end;

  LCertAnsi := AnsiString(ACertFile);
  if SSL_CTX_use_certificate_file(FCtx, PAnsiChar(LCertAnsi), SSL_FILETYPE_PEM) <> 1 then
    raise ENghttp2Tls.CreateFmt(
      'SSL_CTX_use_certificate_file(%s) [client-side mTLS] failed: %s',
      [ACertFile, NghttpsslLastError]);

  LKeyAnsi := AnsiString(AKeyFile);
  if SSL_CTX_use_PrivateKey_file(FCtx, PAnsiChar(LKeyAnsi), SSL_FILETYPE_PEM) <> 1 then
    raise ENghttp2Tls.CreateFmt(
      'SSL_CTX_use_PrivateKey_file(%s) [client-side mTLS] failed: %s',
      [AKeyFile, NghttpsslLastError]);

  if SSL_CTX_check_private_key(FCtx) <> 1 then
    raise ENghttp2Tls.CreateFmt(
      'SSL_CTX_check_private_key [client-side mTLS]: cert and key don''t match — %s',
      [NghttpsslLastError]);
end;

procedure TTlsClientContext.EnableHttp2Alpn;
var
  LProtos: array[0..2] of Byte;
  LRet:    Integer;
begin
  // Wire format for ALPN protos: length-prefixed list of protocol names.
  // Advertising only 'h2': [0x02, 'h', '2'] = 3 bytes total.
  LProtos[0] := 2;
  LProtos[1] := Ord('h');
  LProtos[2] := Ord('2');
  // Returns 0 on success (peculiar convention — most OpenSSL funcs return 1)
  LRet := SSL_CTX_set_alpn_protos(FCtx, @LProtos[0], Length(LProtos));
  if LRet <> 0 then
    RaiseTls('SSL_CTX_set_alpn_protos', LRet, nil);
end;

// ─── TTlsClientConnection ──────────────────────────────────────────────

constructor TTlsClientConnection.Create(const AContext: TTlsClientContext; ASocket: Integer);
begin
  inherited Create;
  if AContext = nil then
    raise ENghttp2Tls.Create('TTlsClientConnection.Create: AContext is nil');

  FCtx    := AContext;
  FSocket := ASocket;

  FSSL := SSL_new(AContext.Handle);
  if FSSL = nil then
    RaiseTls('SSL_new (client)', 0, nil);

  FBioIn  := BIO_new(BIO_s_mem());
  FBioOut := BIO_new(BIO_s_mem());
  if (FBioIn = nil) or (FBioOut = nil) then
  begin
    SSL_free(FSSL);
    FSSL := nil;
    RaiseTls('BIO_new (client)', 0, nil);
  end;

  // SSL owns both BIOs from here; SSL_free releases them.
  SSL_set_bio(FSSL, FBioIn, FBioOut);
end;

function TTlsClientConnection.FlushOut: Boolean;
var
  LBuf: array[0..16383] of Byte;
  LLen: Integer;
begin
  Result := True;
  if FSSL = nil then Exit;
  repeat
    LLen := BIO_read(FBioOut, @LBuf[0], SizeOf(LBuf));
    if LLen <= 0 then Break;
    if not SocketSendAll(TSocketHandle(FSocket), @LBuf[0], LLen) then
      Exit(False);
  until False;
end;

function TTlsClientConnection.FeedIn: Integer;
var
  LBuf: array[0..16383] of Byte;
begin
  Result := SocketRecv(TSocketHandle(FSocket), @LBuf[0], SizeOf(LBuf));
  if Result <= 0 then Exit;
  if BIO_write(FBioIn, @LBuf[0], Result) <= 0 then
    Exit(-1);
end;

destructor TTlsClientConnection.Destroy;
begin
  if FSSL <> nil then
  begin
    SSL_free(FSSL);
    FSSL := nil;
  end;
  inherited;
end;

procedure TTlsClientConnection.DoHandshake;
var
  LRet, LErr, LFed: Integer;
begin
  // Same pump as the server side: advance, flush what OpenSSL produced, feed
  // it more. Flushing on every pass is required — withholding output while
  // OpenSSL reports WANT_READ deadlocks both ends.
  repeat
    LRet := SSL_connect(FSSL);

    if not FlushOut then
      RaiseTls('SSL_connect (send)', 0, nil);

    if LRet = 1 then
      Exit;

    LErr := SSL_get_error(FSSL, LRet);
    case LErr of
      SSL_ERROR_WANT_READ:
        begin
          LFed := FeedIn;
          if LFed <= 0 then
            RaiseTls('SSL_connect (peer closed during handshake)', LRet, FSSL);
        end;
      SSL_ERROR_WANT_WRITE:
        ;
    else
      RaiseTls('SSL_connect', LRet, FSSL);
    end;
  until False;
end;

function TTlsClientConnection.NegotiatedProtocol: string;
var
  LData: PByte;
  LLen:  Cardinal;
begin
  LData := nil;
  LLen  := 0;
  SSL_get0_alpn_selected(FSSL, LData, LLen);
  if (LData = nil) or (LLen = 0) then
    Exit('');
  SetString(Result, PAnsiChar(LData), LLen);
end;

function TTlsClientConnection.Read(ABuf: Pointer; ALen: Integer): Integer;
var
  LErr, LFed: Integer;
begin
  repeat
    Result := SSL_read(FSSL, ABuf, ALen);
    if Result > 0 then Exit;

    LErr := SSL_get_error(FSSL, Result);
    case LErr of
      SSL_ERROR_WANT_READ:
        begin
          if not FlushOut then Exit(-1);
          LFed := FeedIn;
          if LFed <= 0 then Exit(LFed);
        end;
      SSL_ERROR_WANT_WRITE:
        if not FlushOut then Exit(-1);
      SSL_ERROR_ZERO_RETURN:
        Exit(0);
    else
      Exit(-1);
    end;
  until False;
end;

function TTlsClientConnection.Write(ABuf: Pointer; ALen: Integer): Integer;
var
  LErr, LFed: Integer;
begin
  repeat
    Result := SSL_write(FSSL, ABuf, ALen);
    if Result > 0 then
    begin
      // Nothing has left the process until this flush — the ciphertext is
      // still only in FBioOut.
      if not FlushOut then Exit(-1);
      Exit;
    end;

    LErr := SSL_get_error(FSSL, Result);
    case LErr of
      SSL_ERROR_WANT_WRITE:
        if not FlushOut then Exit(-1);
      SSL_ERROR_WANT_READ:
        begin
          if not FlushOut then Exit(-1);
          LFed := FeedIn;
          if LFed <= 0 then Exit(-1);
        end;
    else
      Exit(-1);
    end;
  until False;
end;

procedure TTlsClientConnection.Shutdown;
begin
  if FSSL = nil then Exit;
  SSL_shutdown(FSSL);
  // close_notify only reaches the wire if we push it — see TTlsConnection.
  FlushOut;
end;

end.
