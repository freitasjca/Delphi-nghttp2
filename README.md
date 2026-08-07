# Delphi-nghttp2

**Server + client bindings for [libnghttp2](https://nghttp2.org/) in Object Pascal (Delphi + FPC).**

Low-level HTTP/2 transport primitives — session state, HPACK, streams, callbacks — packaged as a standalone library. Use it directly to build HTTP/2 servers/clients in Delphi, or via the higher-level [`horse-provider-nghttp2`](https://github.com/freitasjca/horse-provider-nghttp2) glue for the [Horse](https://github.com/HashLoad/horse) web framework.

Parallels the ecosystem's proven pattern:

| Transport library | Horse glue |
|---|---|
| [`Delphi-Cross-Socket`](https://github.com/winddriver/Delphi-Cross-Socket) | `horse-provider-crosssocket` |
| [`mORMot2`](https://github.com/synopse/mORMot2) | `horse-provider-mormot` |
| **`Delphi-nghttp2`** *(this repo)* | `horse-provider-nghttp2` |

---

## Roadmap

| Layer | State |
|---|---|
| Server-side FFI + session runtime | **v0.1 ✓** (extracted from `horse-provider-nghttp2` 2026-08-05) |
| TCP accept loop + cross-platform sockets | **v0.1 ✓** |
| Client-side FFI (`nghttp2_session_client_new`, `nghttp2_submit_request`, …) | **v0.1 ✓** |
| `TNghttp2Client` — synchronous request/response API | **v0.1 ✓** |
| Native HTTP/2 test client (`horse-provider-nghttp2/samples/tests/HorseNghttp2TestClient.dpr`) | **v0.1 ✓** (94/94 pass) |
| **TLS + ALPN — server side** (`TTlsServerContext`, `TTlsConnection`) | **v1.1 ✓** |
| **TLS + ALPN — client side** (`TTlsClientContext`, `TTlsClientConnection`) | **v1.1 ✓** |
| **OpenSSL 3.x + 1.1.x FFI with auto-detect + `SetDllDirectory` for local libs** | **v1.1 ✓** |
| Password-protected private keys (`SSL_CTX_set_default_passwd_cb`) | v2 |
| mTLS (client cert verification) | v2 |
| Reusable session pool for high-concurrency clients | v2 |
| Async client API (non-blocking `SubmitRequest`) | v2 |

---

## Requirements

- **Delphi 10.4 Sydney or later** (for inline `var`, `System.Threading`). Older versions gated by `{$IF CompilerVersion >= 32.0}`.
- **Free Pascal 3.2+ / Lazarus 2.0+** (for FPC support — `{$MODE DELPHI}`).
- **libnghttp2 ≥ 1.40** at runtime — install via system package manager:
  - Debian/Ubuntu: `apt install libnghttp2-14 libnghttp2-dev`
  - Fedora/RHEL: `dnf install libnghttp2 libnghttp2-devel`
  - macOS: `brew install nghttp2`
  - Windows: download `nghttp2.dll` from https://github.com/nghttp2/nghttp2/releases or via vcpkg
- **Platforms:** Windows (Win32/Win64), Linux (x86_64, ARM64 via SONAME), macOS (Intel + Apple Silicon).

The library loads libnghttp2 by its stable SONAME (`libnghttp2.so.14` on Linux, `libnghttp2.dylib` on macOS, `nghttp2.dll` on Windows). No binaries bundled — the platform's package manager owns the file.

---

## Install (Boss)

```
boss install github.com/freitasjca/Delphi-nghttp2
```

Or add to `boss.json`:

```json
"dependencies": {
  "github.com/freitasjca/Delphi-nghttp2": "^0.1"
}
```

---

## Layout

```
src/
  Nghttp2.Native.pas       — FFI bindings (server + client symbols)
  Nghttp2.Types.pas        — INghttp2Connection + INghttp2Stream interfaces
  Nghttp2.Session.pas      — nghttp2 session wrapper + per-stream state
  Nghttp2.Socket.pas       — cross-platform raw TCP (Winsock2 / POSIX / FPC Sockets)
  Nghttp2.Server.pas       — accept loop + per-connection session lifecycle
  Nghttp2.Client.pas       — synchronous HTTP/2 client (TNghttp2Client + TNghttp2Response)

samples/
  tests/                   — protocol-level and integration tests

doc/                       — design docs, upstream notes, migration guides
```

---

## Minimal server (11 lines)

```pascal
uses Nghttp2.Server, Nghttp2.Types;

var Srv: TNghttp2Server;
begin
  Srv := TNghttp2Server.Create;
  Srv.OnRequest := procedure(const AStream: INghttp2Stream)
    begin
      AStream.StatusCode := 200;
      AStream.Header['content-type'] := 'text/plain';
      AStream.Send(TEncoding.UTF8.GetBytes('hello from HTTP/2'));
    end;
  Srv.Start(THorseNghttp2Config.Default);  // binds :9000 by default
  ReadLn;
end;
```

## Minimal client (10 lines)

```pascal
uses Nghttp2.Client;

var C: TNghttp2Client;
var R: TNghttp2Response;
begin
  C := TNghttp2Client.Create;
  try
    C.Connect('127.0.0.1', 9000);
    R := C.SubmitRequest('GET', '/', nil, nil);
    WriteLn('Status: ', R.Status);
    WriteLn(TEncoding.UTF8.GetString(R.Body));
  finally
    C.Free;
  end;
end;
```

---

## License

MIT. See `LICENSE`.

## Credits

- [nghttp2](https://nghttp2.org/) — the C library this wraps
- The extraction from `horse-provider-nghttp2` (v0.1, 2026-08-05) was done to mirror the `Delphi-Cross-Socket` / `horse-provider-crosssocket` pattern
