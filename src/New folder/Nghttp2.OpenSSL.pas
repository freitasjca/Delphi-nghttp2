unit Nghttp2.OpenSSL;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Nghttp2.OpenSSL
//  Minimal FFI bindings for OpenSSL, dynamically loaded at first use.
//
//  Scope: exactly what TLS + ALPN needs for HTTP/2 (h2). Not a general-purpose
//  OpenSSL wrapper — no BIO, no EVP, no X509 introspection. If callers need
//  those they can add them to a v1.1 extension unit.
//
//  Version support:
//    OpenSSL 3.x  (preferred — modern distros + macOS default)
//    OpenSSL 1.1.x (fallback — Debian 10/11, Ubuntu 20.04, RHEL 8)
//
//  Runtime library names (all searched, first-found wins):
//    Windows 64:  libssl-3-x64.dll  → libssl-1_1-x64.dll
//    Windows 32:  libssl-3.dll      → libssl-1_1.dll
//    macOS:       libssl.3.dylib    → libssl.1.1.dylib
//    Linux/BSD:   libssl.so.3       → libssl.so.1.1
//
//  Every FFI symbol is a `var` function pointer populated by NghttpsslLoad.
//  Static `external` linkage is deliberately avoided so callers can:
//    (a) build binaries that don't require OpenSSL at load time (h2c only)
//    (b) probe which version is available at runtime for logging
//
//  Thread-safety: OpenSSL 1.1.0+ auto-initializes its own thread callbacks
//  on first library entry. No manual CRYPTO_set_locking_callback wiring
//  needed (unlike the old 1.0.x API). Callers may still want to call
//  NghttpsslLoad() from a serial startup routine before spawning threads.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
  {$IF DEFINED(MSWINDOWS)}
  Windows;
  {$ELSE}
  DynLibs;
  {$IFEND}
{$ELSE}
  System.SysUtils, System.Classes,
  {$IF DEFINED(MSWINDOWS)}
  Winapi.Windows;
  {$ELSE}
  Posix.Dlfcn;
  {$IFEND}
{$IFEND}

type
  ENghttp2OpenSSL = class(Exception);

  // ─── Opaque handles ──────────────────────────────────────────────────────
  PSSL_CTX    = Pointer;
  PSSL        = Pointer;
  PSSL_METHOD = Pointer;

  // ─── ALPN server-side callback signature (openssl/ssl.h) ─────────────────
  // Returns SSL_TLSEXT_ERR_* to indicate whether a protocol was selected.
  // in_/inlen: length-prefixed list of client-advertised protocols
  //            (each entry = one length byte + N protocol bytes).
  // out_/outlen: OUT — pointer into `in_` for the selected entry, and its length.
  TAlpnSelectCb = function(
    ssl: PSSL;
    var out_: PByte;
    var outlen: Byte;
    const in_: PByte;
    inlen: Cardinal;
    arg: Pointer): Integer; cdecl;

  // ─── PEM password callback (openssl/pem.h) ──────────────────────────────
  // Fired when OpenSSL tries to read an encrypted PEM key. Copy the password
  // (as bytes, no null terminator required) into buf up to size, return
  // the number of bytes written. Return 0 or -1 on error → OpenSSL aborts
  // the key load.
  TPemPasswordCb = function(
    buf:    PAnsiChar;
    size:   Integer;
    rwflag: Integer;
    u:      Pointer): Integer; cdecl;

const
  // ─── SSL_get_error return values ─────────────────────────────────────────
  SSL_ERROR_NONE             = 0;
  SSL_ERROR_SSL              = 1;
  SSL_ERROR_WANT_READ        = 2;
  SSL_ERROR_WANT_WRITE       = 3;
  SSL_ERROR_WANT_X509_LOOKUP = 4;
  SSL_ERROR_SYSCALL          = 5;
  SSL_ERROR_ZERO_RETURN      = 6;
  SSL_ERROR_WANT_CONNECT     = 7;
  SSL_ERROR_WANT_ACCEPT      = 8;

  // ─── Certificate file types ──────────────────────────────────────────────
  SSL_FILETYPE_PEM  = 1;
  SSL_FILETYPE_ASN1 = 2;

  // ─── ALPN select callback return codes ───────────────────────────────────
  SSL_TLSEXT_ERR_OK            = 0;
  SSL_TLSEXT_ERR_ALERT_WARNING = 1;
  SSL_TLSEXT_ERR_ALERT_FATAL   = 2;
  SSL_TLSEXT_ERR_NOACK         = 3;

  // ─── SSL_CTX_set_verify mode flags (openssl/ssl.h) ───────────────────────
  SSL_VERIFY_NONE                 = $00;
  SSL_VERIFY_PEER                 = $01;
  SSL_VERIFY_FAIL_IF_NO_PEER_CERT = $02;
  SSL_VERIFY_CLIENT_ONCE          = $04;
  SSL_VERIFY_POST_HANDSHAKE       = $08;

var
  // ─── Method factories (unified TLS_*_method since 1.1.0) ────────────────
  TLS_server_method: function: PSSL_METHOD; cdecl;
  TLS_client_method: function: PSSL_METHOD; cdecl;

  // ─── SSL_CTX lifecycle + configuration ──────────────────────────────────
  SSL_CTX_new:                  function(method: PSSL_METHOD): PSSL_CTX; cdecl;
  SSL_CTX_free:                 procedure(ctx: PSSL_CTX); cdecl;
  SSL_CTX_use_certificate_file: function(ctx: PSSL_CTX;
                                         const filename: PAnsiChar;
                                         typ: Integer): Integer; cdecl;
  SSL_CTX_use_PrivateKey_file:  function(ctx: PSSL_CTX;
                                         const filename: PAnsiChar;
                                         typ: Integer): Integer; cdecl;
  SSL_CTX_check_private_key:    function(ctx: PSSL_CTX): Integer; cdecl;
  SSL_CTX_set_alpn_select_cb:   procedure(ctx: PSSL_CTX;
                                          cb: TAlpnSelectCb;
                                          arg: Pointer); cdecl;
  SSL_CTX_set_alpn_protos:      function(ctx: PSSL_CTX;
                                         const protos: PByte;
                                         protos_len: Cardinal): Integer; cdecl;
  // Client-side cert verification control. verify_cb can be nil for default
  // (built-in chain verification). Mode is a bitmask of SSL_VERIFY_* flags.
  SSL_CTX_set_verify:           procedure(ctx: PSSL_CTX;
                                          mode: Integer;
                                          verify_cb: Pointer); cdecl;
  // Server-side CA store for verifying peer (client) certs — mTLS.
  // Either CAfile (PEM bundle) or CApath (hashed dir) or both may be nil,
  // but at least one must be non-nil for meaningful verification.
  SSL_CTX_load_verify_locations: function(ctx: PSSL_CTX;
                                          const CAfile: PAnsiChar;
                                          const CApath: PAnsiChar): Integer; cdecl;

  // ─── PEM password callback wiring (for encrypted private keys) ──────────
  SSL_CTX_set_default_passwd_cb:          procedure(ctx: PSSL_CTX;
                                                    cb: TPemPasswordCb); cdecl;
  SSL_CTX_set_default_passwd_cb_userdata: procedure(ctx: PSSL_CTX;
                                                    u: Pointer); cdecl;

  // ─── Per-connection SSL object ───────────────────────────────────────────
  SSL_new:                function(ctx: PSSL_CTX): PSSL; cdecl;
  SSL_free:               procedure(ssl: PSSL); cdecl;
  SSL_set_fd:             function(ssl: PSSL; fd: Integer): Integer; cdecl;
  SSL_accept:             function(ssl: PSSL): Integer; cdecl;
  SSL_connect:            function(ssl: PSSL): Integer; cdecl;
  SSL_read:               function(ssl: PSSL; buf: Pointer; num: Integer): Integer; cdecl;
  SSL_write:              function(ssl: PSSL; const buf: Pointer; num: Integer): Integer; cdecl;
  SSL_shutdown:           function(ssl: PSSL): Integer; cdecl;
  SSL_get_error:          function(ssl: PSSL; ret_code: Integer): Integer; cdecl;
  SSL_get0_alpn_selected: procedure(ssl: PSSL;
                                    var data: PByte;
                                    var len: Cardinal); cdecl;

  // ─── Error introspection ─────────────────────────────────────────────────
  ERR_get_error:      function: Cardinal; cdecl;
  ERR_error_string_n: procedure(e: Cardinal; buf: PAnsiChar; len: NativeUInt); cdecl;

// Attempt to dynamically load OpenSSL. Idempotent — repeated calls return
// the cached result. Returns True if libssl was found and every required
// symbol resolved; False otherwise (partial success = failure).
//
// Callers should check IsLoaded before using any of the FFI vars. Attempting
// to call an FFI var when IsLoaded=False will crash on a nil dereference.
function NghttpsslLoad: Boolean;

// Diagnostic — after NghttpsslLoad returns False, describes what was tried.
// Windows: uses GetLastError to report the OS-level DLL-load failure
// (typically ERROR_MOD_NOT_FOUND = 126 = a dependency of the DLL wasn't
// found, most commonly the MSVC runtime). POSIX: reports dlerror().
function NghttpsslLoadError: string;

// Free the loaded libraries. Rarely needed — the OS reclaims them on process
// exit. Provided for completeness / long-running test suites that repeatedly
// load and unload.
procedure NghttpsslUnload;

// True after a successful NghttpsslLoad.
function NghttpsslIsLoaded: Boolean;

// Returns a description of what was loaded, e.g., "OpenSSL 3.x (libssl.so.3)"
// or "OpenSSL 1.1.x (libssl-1_1-x64.dll)". Empty string if not loaded.
function NghttpsslVersion: string;

// Convenience — turn the top ERR_get_error() code into a human-readable string.
// Returns '(no error)' if the error queue is empty.
function NghttpsslLastError: string;

implementation

const
{$IF DEFINED(MSWINDOWS)}
  {$IFDEF WIN64}
  LIBSSL_3_NAMES:    array[0..0] of string = ('libssl-3-x64.dll');
  LIBSSL_11_NAMES:   array[0..0] of string = ('libssl-1_1-x64.dll');
  LIBCRYPTO_3:       string = 'libcrypto-3-x64.dll';
  LIBCRYPTO_11:      string = 'libcrypto-1_1-x64.dll';
  {$ELSE}
  LIBSSL_3_NAMES:    array[0..0] of string = ('libssl-3.dll');
  LIBSSL_11_NAMES:   array[0..0] of string = ('libssl-1_1.dll');
  LIBCRYPTO_3:       string = 'libcrypto-3.dll';
  LIBCRYPTO_11:      string = 'libcrypto-1_1.dll';
  {$IFEND}
{$ELSEIF DEFINED(DARWIN) OR DEFINED(MACOS)}
  LIBSSL_3_NAMES:    array[0..1] of string = ('libssl.3.dylib',   '/opt/homebrew/lib/libssl.3.dylib');
  LIBSSL_11_NAMES:   array[0..1] of string = ('libssl.1.1.dylib', '/usr/local/opt/openssl@1.1/lib/libssl.1.1.dylib');
  LIBCRYPTO_3:       string = 'libcrypto.3.dylib';
  LIBCRYPTO_11:      string = 'libcrypto.1.1.dylib';
{$ELSE}
  LIBSSL_3_NAMES:    array[0..0] of string = ('libssl.so.3');
  LIBSSL_11_NAMES:   array[0..0] of string = ('libssl.so.1.1');
  LIBCRYPTO_3:       string = 'libcrypto.so.3';
  LIBCRYPTO_11:      string = 'libcrypto.so.1.1';
{$IFEND}

var
  GLibSSL:    THandle;
  GLibCrypto: THandle;
  GLoaded:    Boolean;
  GVersion:   string;
  GLoadLock:  Boolean;   // simple recursion guard (single-threaded init assumed)
  GLastLoadError: string;   // populated by TryLoad on failure — surfaced via NghttpsslLoadError

// ─── Cross-platform dynamic loading helpers ──────────────────────────────

{$IF DEFINED(MSWINDOWS)}
function DoLoadLib(const AName: string): THandle;
begin
  Result := LoadLibrary(PChar(AName));
end;

function DoGetSym(ALib: THandle; const AName: string): Pointer;
begin
  Result := GetProcAddress(ALib, PAnsiChar(AnsiString(AName)));
end;

procedure DoUnloadLib(ALib: THandle);
begin
  if ALib <> 0 then
    FreeLibrary(ALib);
end;
{$ELSE}
// Cross-cast between THandle and Pointer.
//
// On Delphi Linux (64-bit) `THandle = UInt64` and `Pointer = UInt64`, so
// their bit representations are identical. But the type system refuses
// EITHER an ordinal-to-Pointer cast OR a NativeUInt-intermediate cast
// (E2010 Incompatible types: UInt64 and Pointer). The only clean way to
// reinterpret without the type check is `PPointer(@X)^` — take the address
// of the variable (yielding an untyped pointer), reinterpret it as a
// pointer-to-Pointer, then dereference. Windows compilers accept it too.

// `Move` is the escape hatch — untyped raw memory copy that bypasses ALL
// type checks. Both `PPointer(@X)^` and `Pointer(NativeUInt(X))` still fail
// on Delphi Linux (E2010 through `inline` propagation); Move just copies
// SizeOf(Pointer) bytes and doesn't care what types the source/dest are.
// Non-inline on purpose: the type-check bypass depends on Move being an
// untyped-var-args RTL routine, which inline expansion would defeat.

function HandleToPointer(AHandle: THandle): Pointer;
begin
  Result := nil;
  Move(AHandle, Result, SizeOf(Result));
end;

function PointerToHandle(APtr: Pointer): THandle;
begin
  Result := 0;
  Move(APtr, Result, SizeOf(Result));
end;

function DoLoadLib(const AName: string): THandle;
begin
{$IF DEFINED(FPC)}
  Result := THandle(DynLibs.LoadLibrary(AName));
{$ELSE}
  Result := PointerToHandle(dlopen(PAnsiChar(AnsiString(AName)), RTLD_LAZY or RTLD_LOCAL));
{$IFEND}
end;

function DoGetSym(ALib: THandle; const AName: string): Pointer;
begin
{$IF DEFINED(FPC)}
  Result := DynLibs.GetProcedureAddress(TLibHandle(ALib), AName);
{$ELSE}
  Result := dlsym(HandleToPointer(ALib), PAnsiChar(AnsiString(AName)));
{$IFEND}
end;

procedure DoUnloadLib(ALib: THandle);
begin
  if ALib <> 0 then
{$IF DEFINED(FPC)}
    DynLibs.UnloadLibrary(TLibHandle(ALib));
{$ELSE}
    dlclose(HandleToPointer(ALib));
{$IFEND}
end;
{$IFEND}

// ─── Symbol resolution ────────────────────────────────────────────────────
// Returns True only if EVERY required symbol was found. Any missing symbol
// aborts the whole load — no partial-init state.
//
// OpenSSL exports are split across TWO libraries:
//   libssl    → SSL_*, TLS_*    (protocol layer)
//   libcrypto → ERR_*, EVP_*, X509_*, BIO_*    (cryptographic + utility layer)
// libssl imports from libcrypto but does NOT re-export libcrypto symbols,
// so GetProcAddress(libssl_handle, "ERR_get_error") correctly returns nil.
// Callers must target the correct handle for each symbol group.

function ResolveSymbols(ALibSsl, ALibCrypto: THandle): Boolean;

  function GetFrom(AHandle: THandle; const AName: string; out ADest: Pointer): Boolean;
  begin
    ADest  := DoGetSym(AHandle, AName);
    Result := ADest <> nil;
  end;

begin
  Result := False;

  // ── libssl exports ──────────────────────────────────────────────────────
  if not GetFrom(ALibSsl, 'TLS_server_method',            Pointer(@TLS_server_method))            then Exit;
  if not GetFrom(ALibSsl, 'TLS_client_method',            Pointer(@TLS_client_method))            then Exit;
  if not GetFrom(ALibSsl, 'SSL_CTX_new',                  Pointer(@SSL_CTX_new))                  then Exit;
  if not GetFrom(ALibSsl, 'SSL_CTX_free',                 Pointer(@SSL_CTX_free))                 then Exit;
  if not GetFrom(ALibSsl, 'SSL_CTX_use_certificate_file', Pointer(@SSL_CTX_use_certificate_file)) then Exit;
  if not GetFrom(ALibSsl, 'SSL_CTX_use_PrivateKey_file',  Pointer(@SSL_CTX_use_PrivateKey_file))  then Exit;
  if not GetFrom(ALibSsl, 'SSL_CTX_check_private_key',    Pointer(@SSL_CTX_check_private_key))    then Exit;
  if not GetFrom(ALibSsl, 'SSL_CTX_set_alpn_select_cb',   Pointer(@SSL_CTX_set_alpn_select_cb))   then Exit;
  if not GetFrom(ALibSsl, 'SSL_CTX_set_alpn_protos',      Pointer(@SSL_CTX_set_alpn_protos))      then Exit;
  if not GetFrom(ALibSsl, 'SSL_get0_alpn_selected',       Pointer(@SSL_get0_alpn_selected))       then Exit;
  if not GetFrom(ALibSsl, 'SSL_CTX_set_verify',                      Pointer(@SSL_CTX_set_verify))                      then Exit;
  if not GetFrom(ALibSsl, 'SSL_CTX_load_verify_locations',           Pointer(@SSL_CTX_load_verify_locations))           then Exit;
  if not GetFrom(ALibSsl, 'SSL_CTX_set_default_passwd_cb',           Pointer(@SSL_CTX_set_default_passwd_cb))           then Exit;
  if not GetFrom(ALibSsl, 'SSL_CTX_set_default_passwd_cb_userdata',  Pointer(@SSL_CTX_set_default_passwd_cb_userdata))  then Exit;

  if not GetFrom(ALibSsl, 'SSL_new',       Pointer(@SSL_new))       then Exit;
  if not GetFrom(ALibSsl, 'SSL_free',      Pointer(@SSL_free))      then Exit;
  if not GetFrom(ALibSsl, 'SSL_set_fd',    Pointer(@SSL_set_fd))    then Exit;
  if not GetFrom(ALibSsl, 'SSL_accept',    Pointer(@SSL_accept))    then Exit;
  if not GetFrom(ALibSsl, 'SSL_connect',   Pointer(@SSL_connect))   then Exit;
  if not GetFrom(ALibSsl, 'SSL_read',      Pointer(@SSL_read))      then Exit;
  if not GetFrom(ALibSsl, 'SSL_write',     Pointer(@SSL_write))     then Exit;
  if not GetFrom(ALibSsl, 'SSL_shutdown',  Pointer(@SSL_shutdown))  then Exit;
  if not GetFrom(ALibSsl, 'SSL_get_error', Pointer(@SSL_get_error)) then Exit;

  // ── libcrypto exports ───────────────────────────────────────────────────
  if not GetFrom(ALibCrypto, 'ERR_get_error',      Pointer(@ERR_get_error))      then Exit;
  if not GetFrom(ALibCrypto, 'ERR_error_string_n', Pointer(@ERR_error_string_n)) then Exit;

  Result := True;
end;

function OsLoadError: string;
begin
{$IF DEFINED(MSWINDOWS)}
  Result := SysErrorMessage(GetLastError);
{$ELSEIF NOT DEFINED(FPC)}
  Result := string(AnsiString(dlerror));
{$ELSE}
  Result := '(load error text not available on this platform)';
{$IFEND}
end;

function TryLoad(const ALibSslNames: array of string;
                 const ALibCryptoName: string;
                 const ALabel: string): Boolean;
var
  I: Integer;
  LSslTriedNames: string;
begin
  Result := False;

  // libcrypto must be loaded first on Windows so libssl can resolve it.
  // On Linux/macOS the dynamic linker follows libssl's NEEDED tag automatically,
  // but pre-loading libcrypto is still safe.
  GLibCrypto := DoLoadLib(ALibCryptoName);
  if GLibCrypto = 0 then
  begin
    GLastLoadError := Format('Failed to load %s: %s', [ALibCryptoName, OsLoadError]);
    Exit;
  end;

  LSslTriedNames := '';
  for I := Low(ALibSslNames) to High(ALibSslNames) do
  begin
    if LSslTriedNames <> '' then
      LSslTriedNames := LSslTriedNames + ', ';
    LSslTriedNames := LSslTriedNames + ALibSslNames[I];
    GLibSSL := DoLoadLib(ALibSslNames[I]);
    if GLibSSL <> 0 then Break;
  end;

  if GLibSSL = 0 then
  begin
    GLastLoadError := Format('Failed to load libssl (tried: %s). Last OS error: %s',
      [LSslTriedNames, OsLoadError]);
    DoUnloadLib(GLibCrypto);
    GLibCrypto := 0;
    Exit;
  end;

  if not ResolveSymbols(GLibSSL, GLibCrypto) then
  begin
    GLastLoadError := Format(
      'Loaded %s but failed to resolve a required symbol — likely an OpenSSL ' +
      'version older than 1.1.0 (unified TLS_*_method API required).',
      [ALibSslNames[Low(ALibSslNames)]]);
    DoUnloadLib(GLibSSL);
    DoUnloadLib(GLibCrypto);
    GLibSSL    := 0;
    GLibCrypto := 0;
    Exit;
  end;

  GVersion := ALabel;
  Result   := True;
end;

function NghttpsslLoad: Boolean;
var
  LErr3, LErr11: string;
{$IF DEFINED(MSWINDOWS)}
  LExeDir: string;
{$IFEND}
begin
  if GLoaded then Exit(True);
  if GLoadLock then Exit(False);   // recursion / re-entry guard
  GLoadLock := True;
  try
{$IF DEFINED(MSWINDOWS)}
    // Force LoadLibrary to search the .exe's directory BEFORE the system
    // directory. Without this, Windows' default DLL search order finds any
    // libssl-*.dll installed globally in C:\Windows\SysWOW64 (put there by
    // FortiClient, NVIDIA, ACBr, Delphi's own bin, etc.) — and our library
    // silently loads that stray copy instead of the one shipped next to the
    // application. Passing an empty string RESETS the extra search location;
    // we pass the .exe's folder explicitly so it wins over SysWOW64.
    LExeDir := ExtractFilePath(ParamStr(0));
    if LExeDir <> '' then
      SetDllDirectory(PChar(LExeDir));
{$IFEND}

    // Prefer 3.x when available; fall back to 1.1.x. Preserve BOTH errors
    // so the caller sees why each attempt failed (silent fallback loses
    // critical diagnostics like "3.x load failed with ERROR_MOD_NOT_FOUND
    // because msvcp140.dll is missing").
    if TryLoad(LIBSSL_3_NAMES, LIBCRYPTO_3, 'OpenSSL 3.x (' + LIBSSL_3_NAMES[Low(LIBSSL_3_NAMES)] + ')') then
    begin
      GLoaded := True;
      Exit(True);
    end;
    LErr3 := GLastLoadError;

    // ── DIAGNOSTIC (temporary): to force 3.x-only for debugging,
    // uncomment the two lines below. This surfaces the exact 3.x load
    // error instead of falling through to a possibly-broken 1.1.x DLL.
    //
    // GLastLoadError := '[OpenSSL 3.x attempt] ' + LErr3;
    // Exit(False);

    if TryLoad(LIBSSL_11_NAMES, LIBCRYPTO_11, 'OpenSSL 1.1.x (' + LIBSSL_11_NAMES[Low(LIBSSL_11_NAMES)] + ')') then
    begin
      GLoaded := True;
      Exit(True);
    end;
    LErr11 := GLastLoadError;

    GLoaded := False;
    GLastLoadError :=
      '[OpenSSL 3.x attempt] ' + LErr3 + sLineBreak +
      '[OpenSSL 1.1.x attempt] ' + LErr11;
    Result := False;
  finally
    GLoadLock := False;
  end;
end;

procedure NghttpsslUnload;
begin
  if not GLoaded then Exit;
  DoUnloadLib(GLibSSL);
  DoUnloadLib(GLibCrypto);
  GLibSSL    := 0;
  GLibCrypto := 0;
  GLoaded    := False;
  GVersion   := '';
end;

function NghttpsslIsLoaded: Boolean;
begin
  Result := GLoaded;
end;

function NghttpsslVersion: string;
begin
  Result := GVersion;
end;

function NghttpsslLoadError: string;
begin
  if GLoaded then
    Result := ''
  else if GLastLoadError = '' then
    Result := '(NghttpsslLoad was never called)'
  else
    Result := GLastLoadError;
end;

function NghttpsslLastError: string;
var
  LCode: Cardinal;
  LBuf:  array[0..255] of AnsiChar;
begin
  if not GLoaded then Exit('(OpenSSL not loaded)');
  LCode := ERR_get_error();
  if LCode = 0 then
    Exit('(no error)');
  FillChar(LBuf, SizeOf(LBuf), 0);
  ERR_error_string_n(LCode, @LBuf[0], SizeOf(LBuf) - 1);
  Result := string(AnsiString(PAnsiChar(@LBuf[0])));
end;

initialization
  GLoaded    := False;
  GLibSSL    := 0;
  GLibCrypto := 0;
  GVersion   := '';
  GLoadLock  := False;

finalization
  NghttpsslUnload;

end.
