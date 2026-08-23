# gRPC server, no web framework

A working gRPC server built on `Delphi-nghttp2` and nothing else.

The interesting part is the uses clause:

```pascal
uses
  Nghttp2.Types,
  Nghttp2.Server,
  Nghttp2.Grpc.Registry,
  Nghttp2.Grpc.Dispatcher,
  Sample.Echo.Messages;
```

No Horse, no adapter, no framework. That is the whole claim this sample exists to make, and it is checkable rather than asserted: if the gRPC layer still had a framework dependency in it, this program could not be written.

`horse-provider-nghttp2` is *a* host for this layer, not a prerequisite for it.

## Files

| | |
|---|---|
| `Nghttp2GrpcServer.dpr` | The server. Two RPCs, one plain HTTP/2 route, ~60 lines of actual code |
| `Sample.Echo.Messages.pas` | Two proto3 message classes |
| `echo.proto` | The wire contract, for `grpcurl` |

## Build

**Delphi** (10.4+; validated on 12):

```
dcc64 -U"..\..\src" Nghttp2GrpcServer.dpr
```

**FPC** — trunk 3.3.1. FPC 3.2.2 builds the HTTP/2 transport but *not* the gRPC layer: its `Rtti` unit declares no `TCustomAttribute`.

```
fpc -MDelphi -dNGHTTP2_GRPC_NO_FFI -Fu../../src -Fu. Nghttp2GrpcServer.dpr
```

`-dNGHTTP2_GRPC_NO_FFI` is required, not an optimisation. Without it `Nghttp2.Grpc.Registry` pulls in `ffi.manager`, whose units must then be on the search path, and the build stops with `Can't find unit ffi.manager`. `ffi.manager` is what makes `TRttiMethod.Invoke` work on FPC — needed by `RegisterService<T>`, never by `RegisterMethod`. This sample uses only the latter, so the dependency is dropped; that is the concrete form of "procedural registration needs no libffi", and `tests/build-codec-fpc.sh` compiles this sample with exactly that define so the claim stays true.

If you switch the sample to `RegisterService<T>`, reverse both: drop the define and add `-Fu<fpc-units>/libffi`. Delphi has a native `Invoke` and needs none of this.

`libnghttp2` ≥ 1.59 must be present at run time — `nghttp2.dll` beside the exe on Windows, `libnghttp2.so.14` on Linux. `Start` loads it and raises a clear error if it is missing, rather than failing later with nil function pointers.

## Run

```
$ ./Nghttp2GrpcServer
gRPC + HTTP/2 on h2c://localhost:19000  (2 methods)
```

Then, from another shell:

```sh
grpcurl -plaintext -import-path . -proto echo.proto \
        -d '{"name":"World"}' localhost:19000 echo.Echo/Say
# {"message":"Hello, World!","length":13}

curl --http2-prior-knowledge http://localhost:19000/health
# {"status":"ok"}
```

Both hit the same port and the same listener. `TGrpcDispatcher.TryDispatch` claims `application/grpc*` and returns `False` for anything else, so the fall-through in `HandleRequest` serves ordinary HTTP/2 beside the RPCs.

## Three things worth copying

**`OnRequest` is a plain procedure type**, not `of object` and not an anonymous method. That is deliberate in the library: a plain type accepts a unit-scope trampoline, which is the only shape that compiles on FPC without `FUNCTIONREFERENCES`. A host with state wraps a class method in such a trampoline — that is what the Horse provider does.

**The dispatcher owns both objects.** It creates the request and the response, and frees both. A handler fills the response in and frees neither. Deviating from this leaks or double-frees.

**Message classes need all three RTTI rules**, and `Sample.Echo.Messages.pas` documents each at the point it applies: `{$M+}` unit-wide, serialisable fields `published`, and — on FPC only — an explicit `{$RTTI EXPLICIT}` directive *inside* `interface`. Miss the third and `GetProperties` silently returns zero, so every field arrives empty with no error anywhere.

## Registration styles

This sample uses the procedural form:

```pascal
TGrpcRegistry.RegisterMethod('/echo.Echo/Say',
  TSayRequest, TSayResponse, GService.Say);
```

The alternative reflects a whole interface at once:

```pascal
TGrpcRegistry.RegisterService<IEcho>(TEchoImpl.Create);
```

Both produce identical wire behaviour. Procedural is used here because it never reaches `TRttiMethod.Invoke`, so it needs no libffi on FPC — one less thing between a reader and a running server. `RegisterService<T>` additionally requires `_AddRef`/`_Release` returning `-1` on the implementation, or ARC destroys the instance mid-dispatch.

Streaming RPCs — server, client and bidirectional — register through `RegisterServerStream`, `RegisterClientStream` and `RegisterBidiStream`. A streaming method returns a sequence rather than a value, so it has no natural `IInvokable` shape to reflect over.
