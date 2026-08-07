unit Nghttp2.Native;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Nghttp2.Native
//  Minimal FFI bindings for libnghttp2 (https://nghttp2.org/).
//
//  Scope: server-side + client-side HTTP/2 (h2c cleartext + h2 via caller-
//  supplied TLS). HPACK is handled by the library; callers only marshal
//  name-value pairs across the boundary. Push, altsvc, and window-update
//  fine-tuning are intentionally NOT declared here — add them if needed.
//
//  ── DYNAMIC LOADING (2026-08-06) ─────────────────────────────────────────
//  Every FFI symbol is a `var` function pointer populated by NghttpLoad.
//  There is NO static link-time dependency on libnghttp2 — the DLL is
//  resolved at runtime via SafeLoadLibrary + GetProcAddress, mirroring
//  the Nghttp2.OpenSSL.pas pattern in this same library.
//
//  Rationale: eliminates the Delphi Linux `-lnghttp2` linker requirement
//  (which forced users to install `libnghttp2-dev` and sync the SDK File
//  Cache before their app would even build).  Now users install ONLY the
//  runtime library (nghttp2.dll / libnghttp2.so.14 / libnghttp2.dylib)
//  and the app resolves it at startup.  If loading fails, NghttpLoad
//  returns False and NghttpLoadError returns a diagnostic string.
//
//  Callers MUST invoke NghttpLoad() from a serial startup routine before
//  spawning threads (e.g. inside Horse's InternalListen, before the accept
//  loop starts).  Calling any FFI var with IsLoaded=False will crash on
//  a nil dereference.
//
//  All calls are cdecl. C `size_t` maps to NativeUInt, `ssize_t` to NativeInt;
//  both are pointer-sized on both 32-bit and 64-bit targets. Byte buffers use
//  PByte rather than PAnsiChar — HTTP/2 headers can contain any octet and
//  are not null-terminated in nghttp2's API.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  { FPC: DynLibs is FPC's cross-platform DLL loader.  Windows unit only
    needed for GetLastError / SysErrorMessage on that platform. }
  SysUtils, DynLibs
  {$IFDEF MSWINDOWS}, Windows{$ENDIF};
{$ELSE}
  { Delphi: System.SysUtils provides SafeLoadLibrary + POSIX shims for
    GetProcAddress/FreeLibrary.  On Windows HMODULE/GetProcAddress/FreeLibrary
    live in Winapi.Windows.  Posix.Dlfcn used on POSIX for dlerror only. }
  System.SysUtils
  {$IF DEFINED(MSWINDOWS)}
  , Winapi.Windows
  {$ELSE}
  , Posix.Dlfcn
  {$IFEND};
{$IFEND}

const
  // ── DLL name matrix per platform ────────────────────────────────────────
  // On Linux the SONAME (with .14) is the correct target — package managers
  // ship symlinks like `libnghttp2.so -> libnghttp2.so.14.x.y` but the plain
  // `.so` symlink is only present when the -dev package is installed. The
  // versioned SONAME is always present with the runtime library.
{$IF DEFINED(MSWINDOWS)}
  LIBNGHTTP2_NAMES: array[0..0] of string = ('nghttp2.dll');
{$ELSEIF DEFINED(DARWIN) OR DEFINED(MACOS)}
  LIBNGHTTP2_NAMES: array[0..2] of string = (
    'libnghttp2.dylib',
    '/opt/homebrew/lib/libnghttp2.dylib',      // Homebrew ARM64
    '/usr/local/opt/nghttp2/lib/libnghttp2.dylib' // Homebrew Intel
  );
{$ELSE}
  LIBNGHTTP2_NAMES: array[0..1] of string = (
    'libnghttp2.so.14',   // Debian/Ubuntu/RHEL SONAME as of libnghttp2 1.x
    'libnghttp2.so'       // fallback — usually a -dev symlink to the above
  );
{$IFEND}

  // Frame types (RFC 7540 §6)
  NGHTTP2_DATA          = 0;
  NGHTTP2_HEADERS       = 1;
  NGHTTP2_PRIORITY      = 2;
  NGHTTP2_RST_STREAM    = 3;
  NGHTTP2_SETTINGS      = 4;
  NGHTTP2_PUSH_PROMISE  = 5;
  NGHTTP2_PING          = 6;
  NGHTTP2_GOAWAY        = 7;
  NGHTTP2_WINDOW_UPDATE = 8;
  NGHTTP2_CONTINUATION  = 9;

  // Frame flags (context-dependent — same bit means different things per frame type)
  NGHTTP2_FLAG_NONE        = $00;
  NGHTTP2_FLAG_END_STREAM  = $01;   // DATA, HEADERS
  NGHTTP2_FLAG_ACK         = $01;   // SETTINGS, PING
  NGHTTP2_FLAG_END_HEADERS = $04;   // HEADERS, PUSH_PROMISE, CONTINUATION
  NGHTTP2_FLAG_PADDED      = $08;   // DATA, HEADERS, PUSH_PROMISE
  NGHTTP2_FLAG_PRIORITY    = $20;   // HEADERS

  // Data source flags — returned from read_callback via *data_flags out-arg
  NGHTTP2_DATA_FLAG_NONE          = $00;
  NGHTTP2_DATA_FLAG_EOF           = $01;
  NGHTTP2_DATA_FLAG_NO_END_STREAM = $02;
  NGHTTP2_DATA_FLAG_NO_COPY       = $04;

  // Error codes returned by library functions and expected from callbacks
  NGHTTP2_NO_ERROR                       = 0;
  NGHTTP2_ERR_INVALID_ARGUMENT           = -501;
  NGHTTP2_ERR_BUFFER_ERROR               = -502;
  NGHTTP2_ERR_UNSUPPORTED_VERSION        = -503;
  NGHTTP2_ERR_WOULDBLOCK                 = -504;
  NGHTTP2_ERR_PROTO                      = -505;
  NGHTTP2_ERR_INVALID_FRAME              = -506;
  NGHTTP2_ERR_EOF                        = -507;
  NGHTTP2_ERR_DEFERRED                   = -508;
  NGHTTP2_ERR_STREAM_ID_NOT_AVAILABLE    = -509;
  NGHTTP2_ERR_STREAM_CLOSED              = -510;
  NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE  = -521;
  NGHTTP2_ERR_CALLBACK_FAILURE           = -902;
  NGHTTP2_ERR_NOMEM                      = -901;

  // SETTINGS parameter IDs (RFC 7540 §6.5.2)
  NGHTTP2_SETTINGS_HEADER_TABLE_SIZE      = $01;
  NGHTTP2_SETTINGS_ENABLE_PUSH            = $02;
  NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS = $03;
  NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE    = $04;
  NGHTTP2_SETTINGS_MAX_FRAME_SIZE         = $05;
  NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE   = $06;

  // Header-field flags (nghttp2_nv.flags)
  NGHTTP2_NV_FLAG_NONE           = $00;
  NGHTTP2_NV_FLAG_NO_INDEX       = $01;
  NGHTTP2_NV_FLAG_NO_COPY_NAME   = $02;
  NGHTTP2_NV_FLAG_NO_COPY_VALUE  = $04;

type
  // ─── Opaque handles ────────────────────────────────────────────────────
  Pnghttp2_session           = type Pointer;
  Pnghttp2_session_callbacks = type Pointer;
  Pnghttp2_option            = type Pointer;

  // ─── Name-value pair (HPACK header) ────────────────────────────────────
  Pnghttp2_nv = ^Tnghttp2_nv;
  Tnghttp2_nv = record
    name:     PByte;
    value:    PByte;
    namelen:  NativeUInt;
    valuelen: NativeUInt;
    flags:    Byte;
  end;

  // ─── Frame header (first 9 bytes of every frame) ───────────────────────
  Pnghttp2_frame_hd = ^Tnghttp2_frame_hd;
  Tnghttp2_frame_hd = record
    length:    NativeUInt;
    stream_id: Int32;
    ftype:     Byte;         // C name is 'type' — reserved word in Pascal
    flags:     Byte;
    reserved:  Byte;
  end;

  // ─── Frame — opaque; hd is at offset 0 (all frame types share this prefix) ──
  //     The trailing per-type union payload is not modelled — access only .hd
  //     via the header, or use the SETTINGS/HEADERS/DATA-specific accessors
  //     from libnghttp2 if needed later.
  Pnghttp2_frame = ^Tnghttp2_frame;
  Tnghttp2_frame = record
    hd: Tnghttp2_frame_hd;
  end;

  // ─── Data source discriminated union — we always use ptr, never fd ─────
  Pnghttp2_data_source = ^Tnghttp2_data_source;
  Tnghttp2_data_source = record
    case Integer of
      0: (fd:  Integer);
      1: (ptr: Pointer);
  end;

  // ─── Callback types ────────────────────────────────────────────────────
  //     All callbacks receive the session's user_data pointer that was
  //     supplied to nghttp2_session_server_new. The provider casts that
  //     back to its per-connection session-state object.

  Tnghttp2_send_callback = function(
    session: Pnghttp2_session;
    const data: PByte; length: NativeUInt;
    flags: Integer;
    user_data: Pointer): NativeInt; cdecl;

  Tnghttp2_on_frame_recv_callback = function(
    session: Pnghttp2_session;
    const frame: Pnghttp2_frame;
    user_data: Pointer): Integer; cdecl;

  Tnghttp2_on_stream_close_callback = function(
    session: Pnghttp2_session;
    stream_id: Int32;
    error_code: UInt32;
    user_data: Pointer): Integer; cdecl;

  Tnghttp2_on_header_callback = function(
    session: Pnghttp2_session;
    const frame: Pnghttp2_frame;
    const name:  PByte; namelen:  NativeUInt;
    const value: PByte; valuelen: NativeUInt;
    flags: Byte;
    user_data: Pointer): Integer; cdecl;

  Tnghttp2_on_begin_headers_callback = function(
    session: Pnghttp2_session;
    const frame: Pnghttp2_frame;
    user_data: Pointer): Integer; cdecl;

  Tnghttp2_on_data_chunk_recv_callback = function(
    session: Pnghttp2_session;
    flags: Byte;
    stream_id: Int32;
    const data: PByte; len: NativeUInt;
    user_data: Pointer): Integer; cdecl;

  Tnghttp2_data_source_read_callback = function(
    session: Pnghttp2_session;
    stream_id: Int32;
    buf: PByte; length: NativeUInt;
    data_flags: PUInt32;
    source: Pointer;             // Pnghttp2_data_source
    user_data: Pointer): NativeInt; cdecl;

  Pnghttp2_data_provider = ^Tnghttp2_data_provider;
  Tnghttp2_data_provider = record
    source:        Tnghttp2_data_source;
    read_callback: Tnghttp2_data_source_read_callback;
  end;

  // ─── SETTINGS entry — array element passed to nghttp2_submit_settings ──
  Pnghttp2_settings_entry = ^Tnghttp2_settings_entry;
  Tnghttp2_settings_entry = record
    settings_id: Int32;
    value:       UInt32;
  end;

  // ─── Version info struct returned by nghttp2_version ─────────────────────
  Pnghttp2_info = ^Tnghttp2_info;
  Tnghttp2_info = record
    age:         Integer;
    version_num: Integer;
    version_str: PAnsiChar;
    proto_str:   PAnsiChar;
  end;

  // ─── Priority spec (client submit_request argument — can be nil) ─────────
  // Layout matches libnghttp2's nghttp2_priority_spec exactly. Callers who
  // want default priority (recommended for most cases) simply pass nil for
  // the pri_spec argument to nghttp2_submit_request.
  Pnghttp2_priority_spec = ^Tnghttp2_priority_spec;
  Tnghttp2_priority_spec = record
    stream_id: Int32;
    weight:    Int32;
    exclusive: Byte;
  end;

  // ─── Client-side callback types ──────────────────────────────────────────
  // Symmetric to the server-side callbacks — the same C signatures apply
  // regardless of session role. Type aliases exist here purely for
  // readability at call sites.
  Tnghttp2_before_frame_send_callback = Tnghttp2_on_frame_recv_callback;
  Tnghttp2_on_frame_send_callback     = Tnghttp2_on_frame_recv_callback;

  // ── DLL handle type (matches Nghttp2.OpenSSL.pas TDllHandle) ──────────────
  // Windows + FPC use pointer-sized ordinals; Delphi POSIX uses HMODULE
  // (NativeUInt).  Kept per-unit to avoid a cross-unit dependency at the
  // FFI-binding layer.
{$IF DEFINED(FPC)}
  TDllHandle = TLibHandle;
{$ELSE}
  TDllHandle = HMODULE;
{$IFEND}

var
  // ─── Session lifecycle ────────────────────────────────────────────────
  nghttp2_session_server_new: function(
    out session: Pnghttp2_session;
    callbacks: Pnghttp2_session_callbacks;
    user_data: Pointer): Integer; cdecl;

  nghttp2_session_client_new: function(
    out session: Pnghttp2_session;
    callbacks: Pnghttp2_session_callbacks;
    user_data: Pointer): Integer; cdecl;

  nghttp2_session_del: procedure(session: Pnghttp2_session); cdecl;

  nghttp2_session_want_read:  function(session: Pnghttp2_session): Integer; cdecl;
  nghttp2_session_want_write: function(session: Pnghttp2_session): Integer; cdecl;

  nghttp2_session_terminate_session: function(
    session: Pnghttp2_session;
    error_code: UInt32): Integer; cdecl;

  // ─── I/O (mem_recv / mem_send — no send_callback in v1 for simplicity) ─
  nghttp2_session_mem_recv: function(
    session: Pnghttp2_session;
    const data: PByte; datalen: NativeUInt): NativeInt; cdecl;

  nghttp2_session_mem_send: function(
    session: Pnghttp2_session;
    out data_ptr: PByte): NativeInt; cdecl;

  // ─── Callback registration ────────────────────────────────────────────
  nghttp2_session_callbacks_new: function(
    out callbacks_ptr: Pnghttp2_session_callbacks): Integer; cdecl;

  nghttp2_session_callbacks_del: procedure(
    callbacks: Pnghttp2_session_callbacks); cdecl;

  nghttp2_session_callbacks_set_send_callback: procedure(
    callbacks: Pnghttp2_session_callbacks;
    cb: Tnghttp2_send_callback); cdecl;

  nghttp2_session_callbacks_set_on_frame_recv_callback: procedure(
    callbacks: Pnghttp2_session_callbacks;
    cb: Tnghttp2_on_frame_recv_callback); cdecl;

  nghttp2_session_callbacks_set_on_stream_close_callback: procedure(
    callbacks: Pnghttp2_session_callbacks;
    cb: Tnghttp2_on_stream_close_callback); cdecl;

  nghttp2_session_callbacks_set_on_header_callback: procedure(
    callbacks: Pnghttp2_session_callbacks;
    cb: Tnghttp2_on_header_callback); cdecl;

  nghttp2_session_callbacks_set_on_begin_headers_callback: procedure(
    callbacks: Pnghttp2_session_callbacks;
    cb: Tnghttp2_on_begin_headers_callback); cdecl;

  nghttp2_session_callbacks_set_on_data_chunk_recv_callback: procedure(
    callbacks: Pnghttp2_session_callbacks;
    cb: Tnghttp2_on_data_chunk_recv_callback); cdecl;

  nghttp2_session_callbacks_set_before_frame_send_callback: procedure(
    callbacks: Pnghttp2_session_callbacks;
    cb: Tnghttp2_before_frame_send_callback); cdecl;

  nghttp2_session_callbacks_set_on_frame_send_callback: procedure(
    callbacks: Pnghttp2_session_callbacks;
    cb: Tnghttp2_on_frame_send_callback); cdecl;

  // ─── Submit outgoing frames ───────────────────────────────────────────
  nghttp2_submit_settings: function(
    session: Pnghttp2_session;
    flags: Byte;
    const iv: Pnghttp2_settings_entry;
    niv: NativeUInt): Integer; cdecl;

  nghttp2_submit_response: function(
    session: Pnghttp2_session;
    stream_id: Int32;
    const nva: Pnghttp2_nv; nvlen: NativeUInt;
    const data_prd: Pnghttp2_data_provider): Integer; cdecl;

  nghttp2_submit_request: function(
    session:           Pnghttp2_session;
    const pri_spec:    Pnghttp2_priority_spec;
    const nva:         Pnghttp2_nv; nvlen: NativeUInt;
    const data_prd:    Pnghttp2_data_provider;
    stream_user_data:  Pointer): Int32; cdecl;

  nghttp2_submit_rst_stream: function(
    session: Pnghttp2_session;
    flags: Byte;
    stream_id: Int32;
    error_code: UInt32): Integer; cdecl;

  nghttp2_submit_goaway: function(
    session: Pnghttp2_session;
    flags: Byte;
    last_stream_id: Int32;
    error_code: UInt32;
    const opaque_data: PByte; opaque_data_len: NativeUInt): Integer; cdecl;

  nghttp2_submit_ping: function(
    session:           Pnghttp2_session;
    flags:             Byte;
    const opaque_data: PByte): Integer; cdecl;

  // ─── HTTP/2 trailers (M2, 2026-08-07) ─────────────────────────────────
  //  Submits a HEADERS frame with END_STREAM after DATA frames. Required
  //  for gRPC (grpc-status is always a trailer).
  //
  //  Preconditions per nghttp2 docs:
  //    - stream_id must be a stream previously started by submit_response
  //      (server) or submit_request (client) whose data_provider hasn't
  //      yet signalled END_STREAM
  //    - the data_provider's read_callback must have returned
  //      NGHTTP2_DATA_FLAG_EOF | NGHTTP2_DATA_FLAG_NO_END_STREAM to keep
  //      the stream half-open so trailers can follow
  //
  //  Returns 0 on success or a negative NGHTTP2_ERR_* code on failure.
  nghttp2_submit_trailer: function(
    session:   Pnghttp2_session;
    stream_id: Int32;
    const nva: Pnghttp2_nv; nvlen: NativeUInt): Integer; cdecl;

  // ─── Per-stream user data ──────────────────────────────────────────────
  nghttp2_session_set_stream_user_data: function(
    session:           Pnghttp2_session;
    stream_id:         Int32;
    stream_user_data:  Pointer): Integer; cdecl;

  nghttp2_session_get_stream_user_data: function(
    session:    Pnghttp2_session;
    stream_id:  Int32): Pointer; cdecl;

  // ─── Introspection ────────────────────────────────────────────────────
  nghttp2_version:  function(least_version: Integer): Pnghttp2_info; cdecl;
  nghttp2_strerror: function(lib_error_code: Integer): PAnsiChar; cdecl;

// ─── Dynamic loader API (public) ───────────────────────────────────────────

// Attempt to dynamically load libnghttp2. Idempotent — repeated calls return
// the cached result. Returns True if the DLL was found and every symbol
// resolved; False otherwise (partial success = failure).
//
// Callers should invoke this from a serial startup routine before threads
// are spawned. Calling any FFI var with IsLoaded=False will crash on a nil
// dereference.
function NghttpLoad: Boolean;

// Diagnostic — after NghttpLoad returns False, describes what was tried:
// which DLL name(s), OS-level error (GetLastError / dlerror), and if any
// symbol resolution failed, which one.
function NghttpLoadError: string;

// True after a successful NghttpLoad.
function NghttpIsLoaded: Boolean;

// Free the loaded library. Rarely needed — the OS reclaims on process exit.
// Provided for completeness / long-running test suites that repeatedly
// load and unload.
procedure NghttpUnload;

// Convenience: after successful load, returns the libnghttp2 version string
// (e.g. "1.62.1"). Returns empty string if not loaded.
function NghttpVersion: string;

implementation

const
  HANDLE_ZERO: TDllHandle = 0;

var
  GLib: TDllHandle;
  GLoaded: Boolean;
  GLastLoadError: string;
  GVersion: string;

// ─── Cross-platform / cross-compiler dynamic loading helpers ────────────
// Mirrors Nghttp2.OpenSSL.pas — same three shims.

function DoLoadLib(const AName: string): TDllHandle;
begin
{$IF DEFINED(FPC)}
  Result := DynLibs.LoadLibrary(AName);
{$ELSE}
  // SafeLoadLibrary: cross-platform in System.SysUtils. On Windows =
  // LoadLibraryEx with SEM_NOOPENFILEERRORBOX; on POSIX = dlopen wrapper.
  // Returns 0 on failure (both platforms).
  Result := SafeLoadLibrary(AName);
{$IFEND}
end;

function DoGetSym(ALib: TDllHandle; const AName: string): Pointer;
begin
{$IF DEFINED(FPC)}
  Result := DynLibs.GetProcedureAddress(ALib, AName);
{$ELSEIF DEFINED(MSWINDOWS)}
  // Winapi.Windows.GetProcAddress signature: (HMODULE, LPCSTR) where
  // LPCSTR = PAnsiChar.
  Result := GetProcAddress(ALib, PAnsiChar(AnsiString(AName)));
{$ELSE}
  // Delphi POSIX shim (System.SysUtils): GetProcAddress(HMODULE, PChar)
  // where PChar = PWideChar on modern Delphi. The shim converts internally.
  Result := GetProcAddress(ALib, PChar(AName));
{$IFEND}
end;

procedure DoUnloadLib(ALib: TDllHandle);
begin
  if ALib = HANDLE_ZERO then Exit;
{$IF DEFINED(FPC)}
  DynLibs.UnloadLibrary(ALib);
{$ELSE}
  FreeLibrary(ALib);
{$IFEND}
end;

// ─── OS-level error reporting ────────────────────────────────────────────

function LastOsLoadError: string;
begin
{$IF DEFINED(MSWINDOWS)}
  Result := SysErrorMessage(GetLastError);
{$ELSEIF DEFINED(FPC)}
  // FPC's DynLibs surfaces the last error via a text getter on POSIX.
  Result := '(no OS-level error accessor on this platform)';
{$ELSE}
  // Delphi POSIX exposes dlerror via Posix.Dlfcn.dlerror.
  Result := string(dlerror);
{$IFEND}
end;

// ─── Symbol resolution ────────────────────────────────────────────────────
// Returns True only if EVERY required symbol was found. Any missing symbol
// aborts the whole load — no partial-init state.

function ResolveSymbols(ALib: TDllHandle): Boolean;

  function GetFrom(const AName: string; out ADest: Pointer): Boolean;
  begin
    ADest  := DoGetSym(ALib, AName);
    Result := ADest <> nil;
    if not Result then
      GLastLoadError := Format(
        'libnghttp2 loaded but required symbol "%s" not found', [AName]);
  end;

begin
  Result := False;

  // Session lifecycle
  if not GetFrom('nghttp2_session_server_new',
                 Pointer(@nghttp2_session_server_new)) then Exit;
  if not GetFrom('nghttp2_session_client_new',
                 Pointer(@nghttp2_session_client_new)) then Exit;
  if not GetFrom('nghttp2_session_del',
                 Pointer(@nghttp2_session_del)) then Exit;
  if not GetFrom('nghttp2_session_want_read',
                 Pointer(@nghttp2_session_want_read)) then Exit;
  if not GetFrom('nghttp2_session_want_write',
                 Pointer(@nghttp2_session_want_write)) then Exit;
  if not GetFrom('nghttp2_session_terminate_session',
                 Pointer(@nghttp2_session_terminate_session)) then Exit;

  // I/O
  if not GetFrom('nghttp2_session_mem_recv',
                 Pointer(@nghttp2_session_mem_recv)) then Exit;
  if not GetFrom('nghttp2_session_mem_send',
                 Pointer(@nghttp2_session_mem_send)) then Exit;

  // Callback registration
  if not GetFrom('nghttp2_session_callbacks_new',
                 Pointer(@nghttp2_session_callbacks_new)) then Exit;
  if not GetFrom('nghttp2_session_callbacks_del',
                 Pointer(@nghttp2_session_callbacks_del)) then Exit;
  if not GetFrom('nghttp2_session_callbacks_set_send_callback',
                 Pointer(@nghttp2_session_callbacks_set_send_callback)) then Exit;
  if not GetFrom('nghttp2_session_callbacks_set_on_frame_recv_callback',
                 Pointer(@nghttp2_session_callbacks_set_on_frame_recv_callback)) then Exit;
  if not GetFrom('nghttp2_session_callbacks_set_on_stream_close_callback',
                 Pointer(@nghttp2_session_callbacks_set_on_stream_close_callback)) then Exit;
  if not GetFrom('nghttp2_session_callbacks_set_on_header_callback',
                 Pointer(@nghttp2_session_callbacks_set_on_header_callback)) then Exit;
  if not GetFrom('nghttp2_session_callbacks_set_on_begin_headers_callback',
                 Pointer(@nghttp2_session_callbacks_set_on_begin_headers_callback)) then Exit;
  if not GetFrom('nghttp2_session_callbacks_set_on_data_chunk_recv_callback',
                 Pointer(@nghttp2_session_callbacks_set_on_data_chunk_recv_callback)) then Exit;
  if not GetFrom('nghttp2_session_callbacks_set_before_frame_send_callback',
                 Pointer(@nghttp2_session_callbacks_set_before_frame_send_callback)) then Exit;
  if not GetFrom('nghttp2_session_callbacks_set_on_frame_send_callback',
                 Pointer(@nghttp2_session_callbacks_set_on_frame_send_callback)) then Exit;

  // Submit outgoing frames
  if not GetFrom('nghttp2_submit_settings',
                 Pointer(@nghttp2_submit_settings)) then Exit;
  if not GetFrom('nghttp2_submit_response',
                 Pointer(@nghttp2_submit_response)) then Exit;
  if not GetFrom('nghttp2_submit_request',
                 Pointer(@nghttp2_submit_request)) then Exit;
  if not GetFrom('nghttp2_submit_rst_stream',
                 Pointer(@nghttp2_submit_rst_stream)) then Exit;
  if not GetFrom('nghttp2_submit_goaway',
                 Pointer(@nghttp2_submit_goaway)) then Exit;
  if not GetFrom('nghttp2_submit_ping',
                 Pointer(@nghttp2_submit_ping)) then Exit;
  if not GetFrom('nghttp2_submit_trailer',
                 Pointer(@nghttp2_submit_trailer)) then Exit;

  // Per-stream user data
  if not GetFrom('nghttp2_session_set_stream_user_data',
                 Pointer(@nghttp2_session_set_stream_user_data)) then Exit;
  if not GetFrom('nghttp2_session_get_stream_user_data',
                 Pointer(@nghttp2_session_get_stream_user_data)) then Exit;

  // Introspection
  if not GetFrom('nghttp2_version',  Pointer(@nghttp2_version))  then Exit;
  if not GetFrom('nghttp2_strerror', Pointer(@nghttp2_strerror)) then Exit;

  Result := True;
end;

// ─── Public API ──────────────────────────────────────────────────────────

function NghttpLoad: Boolean;
var
  I: Integer;
  Attempted: string;
  LInfo: Pnghttp2_info;
begin
  if GLoaded then Exit(True);

  Attempted := '';
  for I := Low(LIBNGHTTP2_NAMES) to High(LIBNGHTTP2_NAMES) do
  begin
    if Attempted <> '' then Attempted := Attempted + ', ';
    Attempted := Attempted + LIBNGHTTP2_NAMES[I];
    GLib := DoLoadLib(LIBNGHTTP2_NAMES[I]);
    if GLib <> HANDLE_ZERO then Break;
  end;

  if GLib = HANDLE_ZERO then
  begin
    GLastLoadError := Format(
      'libnghttp2 not found — tried [%s]. OS error: %s',
      [Attempted, LastOsLoadError]);
    Exit(False);
  end;

  if not ResolveSymbols(GLib) then
  begin
    // ResolveSymbols already populated GLastLoadError with the missing symbol.
    DoUnloadLib(GLib);
    GLib := HANDLE_ZERO;
    Exit(False);
  end;

  // Success — cache the version string for NghttpVersion accessor.
  // nghttp2_version(0) returns a pointer to an nghttp2_info struct owned by
  // the library (never nil, never needs freeing per nghttp2 docs).
  LInfo := nghttp2_version(0);
  if (LInfo <> nil) and (LInfo^.version_str <> nil) then
    GVersion := string(AnsiString(LInfo^.version_str))
  else
    GVersion := '(unknown)';

  GLoaded := True;
  GLastLoadError := '';
  Result := True;
end;

function NghttpLoadError: string;
begin
  if GLoaded then
    Result := ''
  else if GLastLoadError = '' then
    Result := '(NghttpLoad was never called)'
  else
    Result := GLastLoadError;
end;

function NghttpIsLoaded: Boolean;
begin
  Result := GLoaded;
end;

function NghttpVersion: string;
begin
  if GLoaded then Result := GVersion else Result := '';
end;

procedure NghttpUnload;
begin
  if not GLoaded then Exit;
  DoUnloadLib(GLib);
  GLib := HANDLE_ZERO;
  GLoaded := False;
  GVersion := '';
  // Function-pointer vars retain their stale pointers; that's fine because
  // NghttpIsLoaded=False will prevent callers from invoking them. Callers
  // must re-check IsLoaded after Unload if they intend to Load again.
end;

initialization
  GLib := HANDLE_ZERO;
  GLoaded := False;

finalization
  NghttpUnload;

end.
