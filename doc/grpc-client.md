# gRPC client — calling a service from Pascal

Since **1.28.0** this library calls gRPC services as well as serving them. There are two layers:

- **`Nghttp2.Grpc.Client`** is the channel: `TGrpcChannel`, `EGrpcClientError`,
  `TGrpcCallOptions` and `IGrpcClientStream`. It is untyped: you pass a path and a
  response class.
- **`protogen --client`** generates a typed stub per service on top of it, so a call
  reads `Client.GetProduct(Req)` and a stream's `Current` is already the message
  class.

Both compile on Delphi and on FPC trunk. Neither needs libffi, because the
client never goes through `TRttiMethod.Invoke`.

A complete working example is
[`samples/inventory`](../samples/inventory/document.md). One program there is a
server that calls itself through the generated stubs. The other is a standalone
client that runs the same checks against any server, including an independent
python `grpcio` one.

---

## Generate the stubs

```bash
Protogen -i inventory.proto -o src/ --unit-prefix Sample --client
```

```
[write] Sample.Inventory.Messages.pas
[write] Sample.Inventory.Interfaces.pas
[write] Sample.Inventory.Service.pas
[write] Sample.Inventory.Registration.pas
[write] Sample.Inventory.Client.pas
```

`--client` is opt-in: without it, the four server-side units are written exactly
as before. `<prefix>.Client.pas` is **always regenerated**, like the messages
unit, so don't edit it. A client-only program needs just that unit and
`<prefix>.Messages.pas`.

For each service the unit contains:

| Generated | What it is |
|---|---|
| `T<Service>Client` | One method per unary and server-streaming RPC, each with two overloads: plain, and with `TGrpcCallOptions`. |
| `T<Service><Rpc>Stream` | A typed wrapper per server-streaming RPC: `MoveNext`, `Received`, and a `Current` of the message class. |

**Client and bidi streaming RPCs get no method yet.** They are listed in a
comment in the generated unit rather than silently dropped. See
[What is not there yet](#what-is-not-there-yet).

Method names that would clash with `TObject` members or with the client's own
`Channel` property, or that are reserved words, get a trailing underscore
(`Free_`, `Channel_`, `Type_`). The call still uses the proto name on the wire.

---

## Call it

```pascal
uses
  Nghttp2.Grpc.Client,
  Sample.Inventory.Messages,
  Sample.Inventory.Client;

var
  LChannel: TGrpcChannel;
  LClient:  TInventoryServiceClient;
  LReq:     TGetProductRequest;
  LReply:   TGetProductResponse;
begin
  LChannel := TGrpcChannel.Create('127.0.0.1', 19010);   // h2c; connects lazily
  try
    LClient := TInventoryServiceClient.Create(LChannel);
    try
      LReq := TGetProductRequest.Create;
      try
        LReq.barcode := 'ABC123';
        LReply := LClient.GetProduct(LReq);
        try
          WriteLn(LReply.product.name);
        finally
          LReply.Free;                    // a unary reply belongs to the caller
        end;
      finally
        LReq.Free;                        // the stub never frees the request
      end;
    finally
      LClient.Free;
    end;
  finally
    LChannel.Free;                        // the client BORROWS the channel
  end;
end;
```

### Ownership

| Object | Owned by |
|---|---|
| Request | The caller. No call frees it, so it can be reused for the next call. |
| Unary reply | The caller, who must free it. |
| Stream wrapper | The caller, who must free it. Freeing it before the end abandons the call. |
| `Stream.Current` | The stream. The next `MoveNext` frees it, and so does freeing the stream. Copy anything you want to keep. |
| Channel | The caller. The generated client and every stream only borrow it, so it must outlive them. |
| `TTlsClientContext` | The caller. The channel borrows it for its whole lifetime. |

### Server streaming

```pascal
LStream := LClient.WatchStock(LReq);
try
  while LStream.MoveNext do
    WriteLn(LStream.Current.stock);
finally
  LStream.Free;
end;
```

`MoveNext` returns `False` only when the stream **ended well** (`grpc-status 0`).
Every other ending raises `EGrpcClientError` from `MoveNext`, after the messages
that came before it have already been delivered. That includes a non-zero status,
a missing trailer, a truncated or oversized message, and a dropped connection.
A caller can't forget to check the status, because a bad ending can't look like
a normal one.

---

## Failure is an exception

A call either returns a decoded reply with `grpc-status 0`, or raises
`EGrpcClientError`, whose `Status` holds the gRPC code and whose `GrpcMessage`
holds the percent-decoded `grpc-message`. You never get a half-filled object, and
"HTTP 200, so it worked" is never assumed.

| What went wrong | Status |
|---|---|
| The server's own status | as sent: 5 NOT_FOUND, 7 PERMISSION_DENIED, 12 UNIMPLEMENTED, … |
| Connection refused, reset or dropped; any TLS failure | 14 UNAVAILABLE |
| An HTTP status other than 200 | the gRPC HTTP mapping: 404 → 12, 503 → 14, … |
| A content-type that is not `application/grpc*` | 13 INTERNAL |
| No `grpc-status` where the protocol puts it | 13 INTERNAL |
| A `grpc-status` that is not a number | 2 UNKNOWN |
| Status 0 with a reply that is missing, doubled, truncated, compressed or undecodable | 13 INTERNAL |
| A message over `MaxReceiveMessageBytes` (4 MB default) | 8 RESOURCE_EXHAUSTED |
| The deadline, or `CallTimeoutMS`, ran out | 4 DEADLINE_EXCEEDED |
| A second call on a channel whose stream is still open | 9 FAILED_PRECONDITION |

"Not found" is a domain decision rather than a transport one. The inventory sample
answers it with `found = False` in a successful reply, which the client reads
like any other field. A server that would rather `abort(NOT_FOUND)` produces a
status-5 exception instead, and both styles work.

---

## Deadlines and metadata

```pascal
LOpts := TGrpcCallOptions.Default;      // always start from Default
LOpts.DeadlineMS := 500;                // 0 = no deadline
LOpts.AddMetadata('x-request-id', 'abc');
LReply := LClient.GetProduct(LReq, LOpts);
```

**Deadlines.** The deadline is sent as `grpc-timeout` and is also enforced
locally. When it passes, the call raises 4 whether or not the server honoured
the header. Time spent connecting counts against it. For a stream, the deadline
bounds the **whole** stream.

Without a deadline, `TGrpcChannel.CallTimeoutMS` is the backstop. For a stream
it applies to each wait for the next message, because a healthy stream can run
for hours.

After a deadline fires, the channel drops its connection and the next call opens
a new one.

**Metadata.** Names must be lowercase `a-z 0-9 - _ .`. They can't be `grpc-*`,
`content-type` or `te`, because the client sends those itself. Values must be
printable ASCII. A bad name or value raises `EArgumentException` before anything
is sent, because it is a bug in the calling code, not a call status. Binary
(`-bin`) metadata is refused for now.

---

## TLS and mTLS

```pascal
LTls := TTlsClientContext.Create;
try
  LTls.LoadVerifyLocations('ca.pem');          // or LTls.UseSystemTrustStore
  LTls.SetClientCertificate('client.pem', 'client.key');   // mTLS only
  LChannel := TGrpcChannel.Create('api.example.com', 443, LTls);
  try
    ...
  finally
    LChannel.Free;
  end;
finally
  LTls.Free;                                   // after the channel
end;
```

The client verifies the server by default, against whatever you tell it to
trust. Until you call `LoadVerifyLocations` or `UseSystemTrustStore` it trusts
nothing. The certificate must also be issued for the host you passed to
`Create`, whether that is a DNS name or an IP literal, and a DNS name is also
sent as SNI.

Every TLS failure is 14 UNAVAILABLE: an untrusted or wrong-name certificate, or a
server that wanted a client certificate. `GrpcMessage` names the underlying
`ENghttp2TlsCertVerify` and its `X509_V_*` code. Under TLS 1.3, a refusal for a
missing client certificate arrives on the first read, so it surfaces at the
first call rather than at connect.

`SetInsecure` skips verification and is meant for tests only.

---

## Threads

A channel is **not** thread-safe. Use one channel per thread, the same rule as
the `TNghttp2Client` it wraps.

A channel also runs one call at a time. While a server stream is open, another
call on the same channel raises 9. To run calls concurrently, open more
channels.

---

## What is not there yet

| Missing | Notes |
|---|---|
| Client streaming and bidi streaming | Deferred to a later release (B2 plan, GC5). They need the HTTP/2 client to send a request body while the stream is open, which is new library surface. |
| Binary (`-bin`) metadata | Refused with `EArgumentException` rather than sent wrong. |
| Message compression | A compressed reply is refused with 13. Requests are never compressed. |
| A connection pool, async calls, retries, load balancing, name resolution | Out of scope for the channel. One channel is one connection. |
| Server side: reading call metadata in a handler; honouring `grpc-timeout` | `TGrpcDispatcher` ignores `grpc-timeout`, and handlers see typed messages only. A deadline set by this client is therefore enforced here, at the client, not by a server built on this library. A grpcio server does honour it. |

---

## How it is tested

Every behaviour above is checked against **our own** server and against an
**independent** one. A client and server that share code also share their
bugs, so each would pass against the other.

- **Stage 4l, `Nghttp2GrpcUnaryClient`** (71 checks):
  - Part A: our `TGrpcDispatcher`.
  - Part B: python `grpcio`.
  - Part C: a raw HTTP/2 peer (python `h2`) that sends the malformed replies no
    real server sends. Each must map to its exact status.
  - Part D: TLS and mTLS against our server, including a wrong-name certificate.
  - Part E: TLS and mTLS against grpcio, which uses BoringSSL.
- **Stage 4m, the inventory sample** (7 + 7): the generated stubs against our
  server and against `inventory_server.py`, a grpcio server.
- **C3, `ProtogenInterfaceTests`**: keeps the sample's committed
  `Sample.Inventory.Client.pas` identical to what `protogen --client` emits.
- **C6a**: compiles the generated client and makes live calls to a generated
  server.

Each of these checks was confirmed by a control run, where a deliberately broken
build had to fail it. All of them run on FPC trunk (`tests/build-codec-fpc.sh`)
and on Delphi 12 (`tests\run-tests.bat`).

Across the real-schema corpus, `tools/protogen/compile-check.sh --client`
generates and compiles a client for every schema that declares a service. On a
sample of 305 schemas, all 62 such clients compiled.
