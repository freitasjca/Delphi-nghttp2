# Delphi-nghttp2

**Server + client bindings for [libnghttp2](https://nghttp2.org/) in Object Pascal (Delphi + FPC).**

HTTP/2 transport primitives — session state, HPACK, streams, callbacks — packaged as a standalone library, plus a **framework-agnostic gRPC layer** on top: protobuf codec, service registry, dispatcher, and streaming readers and writers. Use it directly to build HTTP/2 or gRPC servers and clients in Delphi, or via the higher-level [`horse-provider-nghttp2`](https://github.com/freitasjca/horse-provider-nghttp2) glue for the [Horse](https://github.com/HashLoad/horse) web framework.

The gRPC layer takes an `INghttp2Stream` and nothing else — no web framework is involved on either side, so any host that owns a stream can serve gRPC with it. `horse-provider-nghttp2` is one such host, not a prerequisite.

Parallels the ecosystem's proven pattern:

| Transport library | Horse glue |
|---|---|
| [`Delphi-Cross-Socket`](https://github.com/winddriver/Delphi-Cross-Socket) | `horse-provider-crosssocket` |
| [`mORMot2`](https://github.com/synopse/mORMot2) | `horse-provider-mormot` |
| **`Delphi-nghttp2`** *(this repo)* | [`horse-provider-nghttp2`](https://github.com/freitasjca/horse-provider-nghttp2) |

---

## Roadmap

All items marked **✓** ship in the v1.0.0 public release. The internal milestone labels (M0–M5) reflect the development sequence, not semver versions.

| Layer | State |
|---|---|
| Server-side FFI + session runtime | **✓** (M0 — extracted from `horse-provider-nghttp2` 2026-08-05) |
| TCP accept loop + cross-platform sockets | **✓** |
| Client-side FFI (`nghttp2_session_client_new`, `nghttp2_submit_request`, …) | **✓** |
| `TNghttp2Client` — synchronous request/response API | **✓** |
| **Multiplexed client streams** — `BeginRequest` / `PumpAll` / `TakeResponse` | **✓** (MULTISTREAM-1 — N concurrent streams on ONE connection) |
| Native HTTP/2 test client (94/94 pass) | **✓** |
| TLS + ALPN — server side (`TTlsServerContext`, `TTlsConnection`) | **✓** |
| TLS + ALPN — client side (`TTlsClientContext`, `TTlsClientConnection`) | **✓** |
| OpenSSL 3.x + 1.1.x FFI with auto-detect + `SetDllDirectory` for local libs | **✓** |
| mTLS (client cert verification) | **✓** |
| Password-protected private keys (`SSL_CTX_set_default_passwd_cb`) | **implemented, untested** — callback wired, no fixture uses an encrypted key |
| **Async dispatch** — host answers `OnRequest` off the connection thread | **✓** |
| **Graceful shutdown** — drain contract + two-stage GOAWAY (RFC 9113 §6.8) | **✓** |
| **Memory-BIO TLS** — OpenSSL never touches the socket (event-loop prerequisite) | **✓** (validated 2026-08-16: Windows/Delphi 12, FPC 3.3.1, Linux64) |
| **Event-loop I/O** — epoll (`Nghttp2.Engine.Epoll`) + IOCP (`Nghttp2.Engine.Iocp`) | **✓** (both engines' graceful shutdown validated under load 2026-08-22, 3/3 delivery shapes each) |
| **gRPC layer** — protobuf codec, registry (procedural + `RegisterService<T>`), dispatcher, all four RPC shapes | **✓** (extracted from `horse-provider-nghttp2` 2026-08-23; the units never depended on Horse, only their names did) |
| Reusable session pool for high-concurrency clients | planned |
| Async client API (non-blocking `SubmitRequest`) | planned — note `BeginRequest`/`PumpAll` already covers concurrency *within* one connection; what remains is not blocking the calling thread at all |

---

## Async dispatch (v2.1)

By default `OnRequest` runs inline on the connection thread: one request at a
time per connection, so a slow handler blocks every other stream the client
has multiplexed there. Set `TNghttp2Config.AsyncDispatch` and the host
may answer from its own threads instead.

One libnghttp2 rule shapes the entire design (`doc/programmers-guide.rst`):
**`nghttp2_session_send` / `_recv` must never be called from inside a callback
or from a second thread** — "it will lead to the crash". Only the
`nghttp2_submit_*` family is safe, and even that must be serialised.

So in async mode nothing but the connection thread touches the native session.
A worker stages its response on the stream object and hands it back through a
queue; the connection thread drains that queue between recv calls, submits,
and pumps the wire. Three consequences worth knowing before modifying any of
it:

- **Stream state is reference-counted.** `on_stream_close` can fire — client
  RST_STREAM, dead connection — while a worker still holds the stream, so the
  session's table, the response queue and the worker each hold a reference.
- **`BeginAsyncDispatch` / `EndAsyncDispatch`** on `INghttp2Stream` tell the
  pump that work is outstanding. Call `Begin` on the connection thread *before*
  handing the stream over, and pair `End` in the worker's `finally`; an
  unmatched `Begin` parks that connection until the peer gives up.
- **The pump wakes on worker completion, not just socket input.** A client
  waiting on a reply sends nothing, so a socket-only wait would hold every
  response for a full poll interval.

`PollIntervalMS` bounds how long the pump blocks; `MaxConnections` caps
concurrency at the other end, since this transport is one thread per
connection.

## Graceful shutdown (v2.1)

`TNghttp2Server` separates **draining** from **stopping** — one flag used to
mean both, which tore down the pumps the moment a drain began and discarded
replies whose handlers had already finished:

1. `StopAcceptingNewConnections` — closes the listener, raises DRAINING. Every
   connection keeps pumping and sends a GOAWAY notice
   (`last_stream_id = 2^31-1`) so the peer stops opening streams.
2. The caller waits for **both** `ActiveRequests → 0` and
   `AllConnectionsIdle`. The request counter alone is not a drain: a worker
   retires it when its handler returns, which is before the response has been
   submitted or written.
3. `Stop` — raises STOPPING. Each pump sends a second GOAWAY naming the last
   stream it actually processed, flushes it, and only then closes.

The second GOAWAY is what lets a peer distinguish a request that was served
from one it must replay elsewhere. It is queued **between the response drain
and the write loop** so it ships in the same burst as the final response — a
one-shot client exits the moment its stream ends, so anything later misses it
— and it uses `nghttp2_submit_goaway`, never
`nghttp2_session_terminate_session`, which discards frames already submitted
for open streams.

## Memory-BIO TLS (v2.2)

`Nghttp2.Tls.pas` no longer hands OpenSSL the socket. `SSL_set_fd` is replaced
by a pair of in-memory BIOs, and the unit performs every socket read and write
itself:

```
send:  SSL_write(plaintext) → BIO_read(FBioOut)  → SocketSendAll
recv:  SocketRecv → BIO_write(FBioIn) → SSL_read(plaintext)
```

Nothing about the public surface changed — `Read` and `Write` keep the same
signatures and the same *bytes / 0 on clean close / <0 on error* contract, and
they still block, because the connection pump is still one thread per
connection. The change is where the blocking happens: inside our own
`SocketRecv` instead of inside OpenSSL.

That distinction is the whole point. With `SSL_set_fd` an event loop cannot
drive TLS at all — it has no way to know when OpenSSL wants the descriptor,
and no bound on how long a call will park. With memory BIOs, TLS becomes a
pure state machine fed with buffers, which is what an epoll/IOCP loop needs
and the structure Delphi-Cross-Socket uses over its own engines. This shipped
ahead of that loop so it could be validated on its own: the existing TLS and
mTLS suites exercise the rewrite end to end while the threading model they run
against is unchanged.

Validated 2026-08-16 with no new tests: on Windows/Delphi 12, 94/94 over h2c,
TLS **and** mTLS plus 16/16 gRPC on all three; `build-fpc.sh` 15/15 stages on
FPC 3.3.1, including mTLS positive and the uncertified-client rejection; clean
`dcclinux64` compile. The 94 checks run in 117 ms h2c → 146 ms TLS → 189 ms
mTLS, so the handshake pump adds no round trips and the mTLS increment is just
the client-certificate flight.

Two consequences worth knowing:

- **`Write` flushes before it returns success.** After `SSL_write` the
  ciphertext is only in `FBioOut`. Returning the byte count without draining
  it would report bytes as sent while they sit in memory.
- **`Pending` counts two buffers**, not one — plaintext already decrypted
  inside SSL, *plus* undecrypted ciphertext in `FBioIn`. A pump that waits on
  `select()` first must check it, or it will wait on a socket that has nothing
  left to give while a whole record sits undecrypted.

## POSIX note: SIGPIPE

`Nghttp2.Socket.pas` sets `SIGPIPE` to `SIG_IGN` at unit initialisation on
Unix and Delphi POSIX. Writing to a socket whose peer has closed is routine
for a server, and at the default action that write **terminates the whole
process** — every connection, not just the one that lost its peer, with exit
code 141 and no exception to catch.

`SIG_IGN` was originally required because `Nghttp2.Tls.pas` used `SSL_set_fd`:
OpenSSL wrote straight to the descriptor, where a per-call `MSG_NOSIGNAL`
could never reach. Since the memory-BIO rewrite (v2.2) every write is our own
`SocketSendAll`, so per-send flags *would* now be reachable — but `SIG_IGN` is
kept, because it is one line covering every send site including any added
later, and process-wide termination is too severe a failure mode to guard
call-by-call.

---

## Requirements

- **Delphi 10.4 Sydney or later** (for inline `var`, `System.Threading`). Older versions gated by `{$IF CompilerVersion >= 32.0}`.
- **Free Pascal 3.2.2 or trunk 3.3.1 / Lazarus (matching)** — `{$MODE DELPHI}` required. The HTTP/2 transport, TLS and streaming build and pass on **3.2.2** (verified 2026-08-22). The **protobuf/gRPC codec needs trunk 3.3.1**: 3.2.2's `Rtti` unit declares no `TCustomAttribute` and its compiler rejects `{$RTTI EXPLICIT}`, both of which the attribute-driven serializer requires.
- **libnghttp2 ≥ 1.59** at runtime — loaded dynamically at startup (no link-time dependency):

  | Platform | Quick install | Full guide |
  |---|---|---|
  | **Windows** | prebuilt from curl for Windows bundle (no toolchain needed) | [`doc/getting-nghttp2-windows.md`](doc/getting-nghttp2-windows.md) |
  | **Linux** (Debian/Ubuntu) | `sudo apt install libnghttp2-14` | [`doc/getting-nghttp2-linux.md`](doc/getting-nghttp2-linux.md) |
  | **Linux** (Fedora/RHEL) | `sudo dnf install libnghttp2` | [`doc/getting-nghttp2-linux.md`](doc/getting-nghttp2-linux.md) |
  | **macOS** | `brew install nghttp2` | — |

  **Building libnghttp2 yourself** — needed for a pinned version, debug symbols,
  the import `.lib`, or a target with no package: both guides carry a
  from-source route. Windows uses MSVC + CMake ([Win64 and Win32 recipes](doc/getting-nghttp2-windows.md#option-c--build-from-source-msvc--cmake));
  Linux uses the standard autotools build ([from source](doc/getting-nghttp2-linux.md#build-from-source),
  plus [ARM / cross-compile notes](doc/getting-nghttp2-linux.md#arm--cross-compile-targets)).
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
  "github.com/freitasjca/Delphi-nghttp2": "^1.0.0"
}
```

---

## Layout

```
src/
  Nghttp2.Native.pas          — libnghttp2 FFI bindings (server + client symbols)
  Nghttp2.OpenSSL.pas         — OpenSSL FFI bindings (auto-detect 3.x / 1.1.x)
  Nghttp2.Types.pas           — INghttp2Connection + INghttp2Stream interfaces
  Nghttp2.Session.pas         — nghttp2 session wrapper + per-stream state machine
  Nghttp2.Socket.pas          — cross-platform raw TCP (Winsock2 / POSIX / FPC Sockets)
  Nghttp2.Tls.pas             — memory-BIO TLS layer (TTlsServerContext, TTlsClientContext)
  Nghttp2.Engine.Epoll.pas    — Linux epoll event loop
  Nghttp2.Engine.Iocp.pas     — Windows IOCP event loop
  Nghttp2.Server.pas          — accept loop + per-connection session lifecycle
  Nghttp2.Client.pas          — synchronous HTTP/2 client (TNghttp2Client + TNghttp2Response)
  Nghttp2.Protobuf.pas        — Protobuf wire-format codec
  Nghttp2.Protobuf.Rtti.pas   — RTTI-driven Protobuf ↔ Delphi/FPC record mapping
  Nghttp2.Grpc.Attributes.pas — [TGrpcService('pkg.Svc')] for the IInvokable API
  Nghttp2.Grpc.Registry.pas   — service/method registry (procedural + IInvokable)
  Nghttp2.Grpc.Dispatcher.pas — application/grpc interception, framing, trailers
  Nghttp2.Grpc.StreamWriter.pas — IGrpcStreamWriter (server-streaming, bidi out)
  Nghttp2.Grpc.StreamReader.pas — IGrpcStreamReader (client-streaming, bidi in)

samples/
  tests/                      — protocol-level and integration tests

doc/                          — design docs, upstream notes, migration guides
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
  Srv.Start(TNghttp2Config.Default);  // loads libnghttp2, binds :9000
  ReadLn;
end;
```

`Start` loads libnghttp2 itself and raises if it cannot — no explicit
`NghttpLoad` call is needed. Before v2.2 it did not, and only the Horse
provider and `TNghttp2Client` loaded the library: a program built on
`TNghttp2Server` directly (this example included) left every FFI pointer nil.
The listener still bound and the banner still printed — that is plain socket
code — and the connection thread then died on a nil call with the exception
captured silently by `TThread`, leaving the client waiting on a socket nobody
would close. No error, no crash, just a hang.

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

### Several streams on one connection

`SubmitRequest` pumps to completion before returning, so calling it in a loop
serialises the requests. To hold N streams open at once — the thing HTTP/2
exists for — submit them all first, then pump:

```pascal
uses Nghttp2.Client;

var
  C:   TNghttp2Client;
  Ids: array[0..7] of Int32;
  R:   TNghttp2Response;
  I:   Integer;
begin
  C := TNghttp2Client.Create;
  try
    C.Connect('127.0.0.1', 9000);

    for I := 0 to 7 do
      Ids[I] := C.BeginRequest('GET', '/slow/3000', nil, nil);   // returns at once

    C.PumpAll(20000);          // drives the session until every stream closes

    for I := 0 to 7 do
    begin
      R := C.TakeResponse(Ids[I]);   // raises only for THIS stream
      WriteLn(Ids[I], ' -> ', R.Status);
    end;
  finally
    C.Free;
  end;
end;
```

`TakeResponse` frees the stream's slot as it hands the response back, and raises
only if *that* stream failed — one broken stream does not discard the others.
`SubmitRequest` is itself a wrapper over these three calls.

**One thread per client.** Concurrency here means multiplexed streams on one
connection, not a client shared between threads; use separate clients for
separate connections.

---

## License

MIT. See `LICENSE`.

## Credits

- [nghttp2](https://nghttp2.org/) — the C library this wraps
- The extraction from [`horse-provider-nghttp2`](https://github.com/freitasjca/horse-provider-nghttp2) (v0.1, 2026-08-05) was done to mirror the [`Delphi-Cross-Socket`](https://github.com/winddriver/Delphi-Cross-Socket) / [`horse-provider-crosssocket`](https://github.com/freitasjca/horse-provider-crosssocket) pattern
