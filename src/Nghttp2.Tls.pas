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
  TTlsConnection = class
  strict private
    FCtx:    TTlsServerContext;
    FSocket: Integer;
    FSSL:    PSSL;
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

    // Best-effort graceful close (SSL_shutdown). Doesn't wait for the peer's
    // close_notify — that's a caller-optional politeness.
    procedure Shutdown;

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
  TTlsClientConnection = class
  strict private
    FCtx:    TTlsClientContext;
    FSocket: Integer;
    FSSL:    PSSL;
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

  if SSL_set_fd(FSSL, ASocket) <> 1 then
  begin
    SSL_free(FSSL);
    FSSL := nil;
    RaiseTls('SSL_set_fd', 0, nil);
  end;
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
  LRet: Integer;
begin
  LRet := SSL_accept(FSSL);
  if LRet <> 1 then
    RaiseTls('SSL_accept', LRet, FSSL);
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
begin
  Result := SSL_read(FSSL, ABuf, ALen);
end;

function TTlsConnection.Write(ABuf: Pointer; ALen: Integer): Integer;
begin
  Result := SSL_write(FSSL, ABuf, ALen);
end;

procedure TTlsConnection.Shutdown;
begin
  if FSSL <> nil then
    SSL_shutdown(FSSL);   // best effort; ignore return code
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

  if SSL_set_fd(FSSL, ASocket) <> 1 then
  begin
    SSL_free(FSSL);
    FSSL := nil;
    RaiseTls('SSL_set_fd (client)', 0, nil);
  end;
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
  LRet: Integer;
begin
  LRet := SSL_connect(FSSL);
  if LRet <> 1 then
    RaiseTls('SSL_connect', LRet, FSSL);
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
begin
  Result := SSL_read(FSSL, ABuf, ALen);
end;

function TTlsClientConnection.Write(ABuf: Pointer; ALen: Integer): Integer;
begin
  Result := SSL_write(FSSL, ABuf, ALen);
end;

procedure TTlsClientConnection.Shutdown;
begin
  if FSSL <> nil then
    SSL_shutdown(FSSL);
end;

end.
