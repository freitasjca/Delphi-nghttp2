# One binary, two listeners

REST on `:9000` through Horse's full middleware pipeline over HTTP/1.1, and
gRPC on `:50051` through Delphi-nghttp2 — in one process, sharing nothing but
the executable.

```
                    ┌──────────────────────────────────┐
   HTTP/1.1  :9000  │  Horse  ──►  routes, middleware  │
                    │    ▲                             │
                    │    │ HORSE_PROVIDER_CROSSSOCKET  │
                    │    │                             │
                    │  ─────────  one process  ──────  │
                    │                                  │
   h2c       :50051 │  TNghttp2Server ──► TGrpcDispatcher
                    │         (no provider, no Horse)  │
                    └──────────────────────────────────┘
```

## Why this is not a contradiction

A Horse provider is chosen by a compile-time define, and the defines are
**mutually exclusive** — `HORSE_PROVIDER_NGHTTP2` cannot be combined with
`HORSE_PROVIDER_CROSSSOCKET`. One binary, one transport that owns Horse's
socket. `THorseInstance` gives you several logical servers, but all of them on
that one transport, so it does not close this gap either.

What the constraint binds is Horse **providers**. Serving gRPC here needs no
provider at all: the gRPC layer takes an `INghttp2Stream` and nothing else. The
second listener is not a second Horse — it is the library used directly, and
the define never enters into it.

The proof is the `uses` clause. `Horse` and the CrossSocket provider serve the
REST half; `Nghttp2.*` serves the gRPC half; neither group references the
other. The companion sample [`../grpc-server`](../grpc-server) makes the same
point from the other side — it serves gRPC with no framework in its `uses`
clause at all.

## Threading

`TNghttp2Server.Start` is **non-blocking**: it binds, spawns its own threads,
and returns. `THorse.Listen` blocks. So gRPC starts first and Horse owns the
main thread. This sample creates no threads of its own and needs none.

## About the build dependencies

Every other sample in this repository builds from this repository alone. This
one does not — it needs Horse, the CrossSocket provider and Delphi-Cross-Socket
on the search path, because half of what it demonstrates is a Horse
application.

That does **not** make the library depend on Horse. `boss.json` declares
`mainsrc: "src/"`, so samples are not shipped to consumers at all, and nothing
under `src/` references a Horse unit. The dependency lives in this directory
and goes no further.

## Build

Paths assume the four repositories are siblings, as they are in the workspace.

**Delphi** (from this directory):

```
dcc64 -DHORSE_PROVIDER_CROSSSOCKET ^
      "-NSSystem;System.Win;Winapi;Data;Web;Xml" ^
      -U..\..\src ^
      -U..\..\..\horse\src ^
      -U..\..\..\horse-provider-crosssocket\src ^
      -U..\..\..\Delphi-Cross-Socket\Net ^
      -U..\..\..\Delphi-Cross-Socket\Utils ^
      -U..\..\..\Delphi-Cross-Socket\CnPack\Common ^
      -U..\..\..\Delphi-Cross-Socket\CnPack\Crypto ^
      -I..\..\..\Delphi-Cross-Socket ^
      -I..\..\..\Delphi-Cross-Socket\CnPack\Common ^
      -U..\grpc-server ^
      RestAndGrpc.dpr
```

Two switch groups here are easy to omit and neither failure names itself.

**`-NS`** is not optional. Several Horse units spell RTL units
unqualified — `SyncObjs` rather than `System.SyncObjs` — and unit scope names
are what resolve those. The IDE supplies them from project options; a bare
`dcc64` command line does not, and the build fails eighteen units in with
`F2613 Unit 'SyncObjs' not found`. That error names the RTL unit, so it reads
like a broken installation rather than a missing switch.

**`-I` is separate from `-U`, and a unit path does not satisfy an include.**
Every Delphi-Cross-Socket unit opens `{$I zLib.inc}`, which lives at that
repository's root rather than beside them; every CnPack unit opens
`{$I CnPack.inc}` in `CnPack/Common`. Miss either and the build stops with
`F1026 File not found: 'zLib.inc'`, which reads as a broken checkout. The
library's own `BUILDING-FPC.md` documents the same requirement as `-Fi` for
FPC, along with why `Utils` and the CnPack subset belong on the unit path:
`Utils.Hash` uses `CnMD5`/`CnSHA1`/`CnSHA2`.

**FPC trunk 3.3.1** — 3.2.2 cannot build the gRPC layer, because its `Rtti`
unit declares no `TCustomAttribute`. FPC needs no `-NS` equivalent: it has no
unit scope names, and the FPC branch of those uses clauses already spells
everything unqualified:

```
fpc -MDelphi -dHORSE_PROVIDER_CROSSSOCKET -dNGHTTP2_GRPC_NO_FFI \
    -Fu../../src -Fu../../../horse/src \
    -Fu../../../horse-provider-crosssocket/src \
    -Fu../../../Delphi-Cross-Socket/Net -Fu../grpc-server \
    RestAndGrpc.dpr
```

`NGHTTP2_GRPC_NO_FFI` is required on FPC and only because this sample registers
with `RegisterMethod`, which never reaches `TRttiMethod.Invoke`. Without the
define, `Nghttp2.Grpc.Registry` pulls in `ffi.manager` and the build stops with
*Can't find unit ffi.manager*. Reinstate it (define off, `-Fu<units>/libffi`
on) if you switch to `RegisterService<T>`, which does need dynamic invocation.
Delphi has a native `Invoke` and needs none of this.

## Run

```bash
curl http://localhost:9000/ping
curl http://localhost:9000/health
curl 'http://localhost:9000/echo?name=World'

grpcurl -plaintext -import-path ../grpc-server -proto echo.proto \
        -d '{"name":"World"}' localhost:50051 echo.Echo/Say
```

`/health` reports both listeners and reads the framework's own telemetry —
`THorse.ActiveRequests` and `THorse.IsShuttingDown` — rather than counting
anything itself. Those are exposed on the facade precisely so a health endpoint
can use them.

`/echo` is the one place the two halves meet, and they meet in *application*
code: an ordinary REST route calling the same service object the gRPC
dispatcher calls. Nothing in the plumbing is shared.

`libnghttp2 >= 1.59` must be present at run time for the gRPC half. The REST
half has no native dependency.

## Two details worth copying

**Start gRPC before registering routes.** `Start` loads `libnghttp2` and raises
if it is missing. Doing it first means an absent native library fails
immediately with a clear message, instead of after the HTTP listener is already
accepting traffic.

**Shut down in order: drain REST, then stop gRPC.** A Horse route may call into
the same objects the dispatcher uses — `/echo` does — so in-flight requests
should finish before anything they might touch goes away. Then
`TGrpcRegistry.Shutdown` before freeing the service instance, because the
registry holds method pointers into it.

## FPC compatibility

Routes are plain unit-scope procedures rather than inline anonymous methods.
That is Horse's own guidance: anonymous procedures are unavailable on
FPC/Lazarus, so the same source compiles on both only if the handlers are
ordinary procedures or object delegates. The nghttp2 `OnRequest` hook is a
plain procedure type for the same reason.
