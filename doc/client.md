# HTTP/2 client — `TNghttp2Client`

`TNghttp2Client` is the HTTP/2 transport client this library ships alongside the
server. It speaks **prior-knowledge HTTP/2** — h2c on a cleartext socket, or h2
over TLS with ALPN — against any HTTP/2 peer: this library's own server, nginx,
grpcio, or anything else that serves h2. It is the transport the gRPC channel
([`doc/grpc-client.md`](grpc-client.md)) is built on; use that for gRPC and this
for plain HTTP/2.

It is a **gRPC-grade** client, not a browser-grade one. It does DNS and IPv6,
TLS and mTLS, incremental reads, connection reuse, a connection pool, and a
cooperative async API. It deliberately does **not** do redirects, cookies,
`Accept-Encoding`/decompression, or a forward proxy — those are out of scope (see
*What it is not*, last section). If you need those, a general HTTP client such as
Indy or `System.Net.HttpClient` is the better fit — but neither of those speaks
HTTP/2 on FPC, which is the gap this fills.

Everything here compiles on **Delphi** and **FPC trunk 3.3.1**, and the transport
(this client, minus the attribute-driven gRPC layer) is **FPC 3.2.2-clean**. The
whole client is in `Nghttp2.Client`; the pool is in `Nghttp2.Client.Pool`.

> **One thread per client.** A `TNghttp2Client` drives one libnghttp2 session,
> and libnghttp2's rule is that only one thread may ever drive a session.
> "Concurrency" here means several multiplexed streams on one connection, from
> one thread — never a client shared between threads. For concurrent connections,
> use one client per thread, or the pool (which hands each thread its own).

---

## One-shot

For a single request where you do not want to manage a client, `Nghttp2Get` opens
a connection, sends a GET, reads the whole response, and closes:

```pascal
uses Nghttp2.Client;

var R: TNghttp2Response;
begin
  R := Nghttp2Get('http://127.0.0.1:9000/ping');   // h2c; https:// for TLS
  WriteLn('Status: ', R.Status);
  WriteLn(TEncoding.UTF8.GetString(R.Body));
end;
```

It parses scheme, host, port and path from the URL, including a bracketed IPv6
literal (`http://[::1]:9000/`). For anything beyond a single call, hold a client.

---

## A client and a connection

```pascal
var C: TNghttp2Client;
begin
  C := TNghttp2Client.Create;
  try
    C.Connect('example.test', 443);     // DNS name or IP literal, v4 or v6
    // ... requests ...
  finally
    C.Free;                             // Disconnect is implicit in Destroy
  end;
end;
```

`Connect` resolves `AHost` with `getaddrinfo` and connects to the first address
that answers, so a name, an IPv4 literal and an IPv6 literal all work. With no
`TlsContext` assigned it speaks **h2c** (cleartext HTTP/2). `Connected`, `Host`
and `Port` report the current state.

**Connect timeout.** A blocked SYN otherwise stalls the calling thread for the
OS TCP retry budget (~127 s on Linux). Set `ConnectTimeoutMS` before `Connect`:

```pascal
C.ConnectTimeoutMS := 5000;    // 0 (default) = no timeout, OS budget applies
```

It applies to every connect, including the auto-reconnect inside `BeginRequest`
and the pool's health check.

---

## A request, and the response

```pascal
var R: TNghttp2Response;
begin
  R := C.SubmitRequest('GET', '/users/42', nil, nil);   // headers, body both nil
  WriteLn(R.Status);
  WriteLn(TEncoding.UTF8.GetString(R.Body));
end;
```

`SubmitRequest` sends one request and **blocks until the whole response has
arrived**. Its signature:

```pascal
function SubmitRequest(const AMethod, APath: string;
  const AHeaders: TNghttp2Headers; const ABody: TBytes;
  ATimeoutMS: Integer = 30000): TNghttp2Response;
```

- **Pseudo-headers are automatic.** `:method`, `:path`, `:authority` and
  `:scheme` are set for you (`:scheme` follows the transport — `https` under TLS,
  `http` on h2c). `AHeaders` carries only ordinary headers:

  ```pascal
  var H: TNghttp2Headers;
  begin
    SetLength(H, 1);
    H[0].Name := 'accept'; H[0].Value := 'application/json';
    R := C.SubmitRequest('POST', '/items', H, TEncoding.UTF8.GetBytes('{}'));
  end;
  ```

- **`TNghttp2Response`** is `Status`, `Headers`, `Body`, plus `Trailers` and
  `HeadersOnly`. `Trailers` is the HEADERS block that arrived *after* the body
  (gRPC carries `grpc-status`/`grpc-message` there); those fields are still in
  `Headers` too, so pre-trailer callers are unaffected. `HeadersOnly` is True
  when the whole response was one HEADERS block that ended the stream (gRPC's
  "Trailers-Only" shape).

---

## Several streams on one connection

`SubmitRequest` pumps to completion before returning, so a loop of them
serialises. To hold N streams open at once — the thing HTTP/2 exists for — submit
them all, pump once, then reap:

```pascal
var
  Ids: array[0..7] of Int32;
  R:   TNghttp2Response;
  I:   Integer;
begin
  for I := 0 to 7 do
    Ids[I] := C.BeginRequest('GET', '/slow/3000', nil, nil);   // returns at once

  C.PumpAll(20000);                 // drive the session until every stream closes

  for I := 0 to 7 do
  begin
    R := C.TakeResponse(Ids[I]);    // raises only for THIS stream, if it failed
    WriteLn(Ids[I], ' -> ', R.Status);
  end;
end;
```

- **`BeginRequest`** submits and returns the stream id immediately.
- **`PumpAll(ms)`** drives the session until every open stream closes or the
  budget expires (one budget for the whole batch — see per-request deadlines
  below for one per stream).
- **`TakeResponse(id)`** hands back one stream's result and frees its slot,
  raising only if *that* stream failed — a single broken stream does not discard
  the others. `PendingStreams` is how many are still in flight.

`SubmitRequest` is itself a wrapper over these three.

---

## Timeouts

Every blocking call takes a millisecond budget (`SubmitRequest`/`PumpAll`, default
30 000). When it expires with the peer still connected, the call raises
**`ENghttp2Timeout`** — a subclass of `ENghttp2Client`, so an existing
`on ENghttp2Client` handler still catches it, while a caller that must tell "too
slow" from "broken" catches `ENghttp2Timeout` first. The stream it gave up on is
still open, so `Disconnect` or `Reconnect` before reusing the client.

The read deadline is enforced *per read*, not only between reads: a peer that
accepts the connection and then goes silent is cut off at the budget, not parked
forever.

---

## Incremental reads (streaming responses)

By default the body is buffered whole and handed back in `Response.Body`. For a
long-lived response — SSE, a large download, a streaming gRPC call — opt the
stream into incremental delivery and drain it with `ReadChunk`:

```pascal
var
  Id:    Int32;
  Buf:   TBytes;
  N:     Integer;
begin
  Id := C.BeginRequest('GET', '/events', nil, nil, {AStreamResponse=}True);
  repeat
    N := C.ReadChunk(Id, Buf, 64 * 1024, 5000);
    if N > 0 then
      HandleBytes(Buf, N)          // Buf is sized to exactly N
    else if N < 0 then
      // deadline passed, stream still open — call again
      Continue;
  until N = 0;                     // 0 = END_STREAM, nothing more is coming
  C.TakeResponse(Id);              // reap the slot (refuses while bytes are unread)
end;
```

`ReadChunk` returns `>0` bytes copied, `0` at end of stream, `<0` on a timeout
with the stream still open — the same three-way contract as the server side's
`INghttp2Stream.ReadInbound`. `PeekResponseHeaders(id, out resp)` returns the
`:status` and headers once the final HEADERS block has arrived, before the body
ends.

---

## TLS and mTLS

Assign a `TTlsClientContext` to `TlsContext` **before** `Connect`. Assigning it
turns the connection into h2 over TLS and implies ALPN `h2` (set on the
connection, so order of configuration does not matter):

```pascal
uses Nghttp2.Client, Nghttp2.Tls;

var
  Tls: TTlsClientContext;
  C:   TNghttp2Client;
begin
  Tls := TTlsClientContext.Create;
  try
    Tls.LoadVerifyLocations('ca.pem');                 // or UseSystemTrustStore
    Tls.SetClientCertificate('client.pem', 'client.key');   // mTLS only
    C := TNghttp2Client.Create;
    try
      C.TlsContext := Tls;         // non-owning: you free Tls, after the client
      C.Connect('example.test', 443);
      // ...
    finally
      C.Free;
    end;
  finally
    Tls.Free;
  end;
end;
```

- The context **verifies the server** (chain + name) once `LoadVerifyLocations`
  or `UseSystemTrustStore` is set. A name mismatch or an untrusted chain fails the
  handshake. `SetClientCertificate` adds the client side of mTLS; a key with a
  password takes a third argument.
- `SetInsecure` disables verification — **tests only** (self-signed peers).
- A context is **non-owning** and may be **shared across clients and threads**;
  configure it once, before any thread connects. The pool shares one this way.

An encrypted private key with no password configured is refused at once with a
message naming `SSLKeyPassword`, never by prompting on the terminal. See
`samples/` for a complete TLS client.

---

## Connection lifetime

```pascal
C.Reconnect;                       // fresh session to the same host:port
if not C.Ping(5000) then ...;      // HTTP/2 PING; False = no ACK in time
if C.GoAwayReceived then ...;      // server sent GOAWAY — reconnect before reuse
```

`BeginRequest` auto-reconnects a session that received GOAWAY or was torn down,
so most callers never touch these directly. A stream the peer refused
(`REFUSED_STREAM`) raises with a message pointing at `Reconnect`.

---

## The async client API

The async model is **cooperative and single-threaded** — the library spins no
thread of its own (that libnghttp2 one-driver rule again). You submit many
requests, then pump in a loop that stays responsive; between passes you can
cancel a request or let a deadline fire. 100 in flight from one thread:

```pascal
var
  Ids: array[0..99] of Int32;
  I:   Integer;
begin
  for I := 0 to 99 do
    Ids[I] := C.BeginRequest('GET', Paths[I], nil, nil);

  while C.Pump(50) > 0 do          // one bounded pass; returns streams still pending
    ;                              // (do other work here — nothing is blocked)

  for I := 0 to 99 do
    Results[I] := C.TakeResponse(Ids[I]);
end;
```

`Pump(ms)` is `PumpAll`'s single pass: it sends what is queued, reads for up to
`ms`, dispatches callbacks, and returns `PendingStreams`. Unlike `PumpAll` it does
**not** block to completion. Loop it with your own overall deadline — a vanished
peer leaves streams pending that never complete.

### Cancellation

```pascal
C.CancelRequest(Id);     // RST_STREAM(CANCEL), flushed on this call
```

The peer stops, nghttp2 discards any response already in flight, and
`TakeResponse(Id)` then raises instead of returning a body (reap it to free the
slot). A no-op if the stream already completed — the cancel lost the race, so the
real result is kept. Cooperative: it takes effect on this call's flush, not from a
background thread.

### Per-request deadlines

`PumpAll` has one budget for the whole batch; `BeginRequest`'s `ADeadlineMS` gives
**one stream** its own:

```pascal
Id := C.BeginRequest('GET', '/slow', nil, nil, False, False, {ADeadlineMS=}300);
```

When 300 ms passes with that stream still open, the pump RSTs **that stream** and
fails it (`TakeResponse` raises `ENghttp2Timeout`) — the other in-flight streams
keep running untouched.

### Completion callback (push instead of poll)

Instead of polling `TakeResponse`, set `OnComplete` and the pump calls it once per
stream as each reaches a terminal state (completed, errored, cancelled or timed
out):

```pascal
procedure Done(AClient: TNghttp2Client; AStreamId: Int32);
begin
  try
    HandleResponse(AClient.TakeResponse(AStreamId));   // raises for a failed one
  except
    on E: Exception do LogFailure(AStreamId, E);
  end;
end;

// ...
C.OnComplete := Done;              // a plain procedure (FPC 3.2.2-clean)
for I := 0 to 99 do C.BeginRequest('GET', Paths[I], nil, nil);
while C.Pump(50) > 0 do ;          // Done fires as each stream closes
```

`OnComplete` is a plain `procedure`, not a `reference to procedure`, so the client
stays FPC-3.2.2-clean (anonymous methods need trunk). It fires on the pump thread
with the stream Done but not yet reaped; `TakeResponse` and `BeginRequest` are
safe to call from it, but **not** `Pump`/`PumpAll` — you are already inside one.
nil (the default) = poll with `TakeResponse` instead.

---

## Reliability

- **`ENghttp2Client.SafeToRetry`** answers one question: did the server provably
  *not* process the request (RFC 7540 §8.1.4)? It is **True only** on
  `REFUSED_STREAM` (including a GOAWAY whose `last_stream_id` was below this
  stream). Every other failure — a drop, a timeout, a protocol error, a reset
  after the response began — keeps it **False** (uncertain), because the server
  may already have acted. It reports server-processing only; it does **not**
  auto-retry, and a non-idempotent or non-replayable request must not be retried
  on False.
- **`PeerMaxConcurrentStreams`** reports the peer's advertised
  `SETTINGS_MAX_CONCURRENT_STREAMS` after the first round-trip. nghttp2 already
  queues excess submissions, so this is observability (for a pool deciding whether
  to open another stream or lease another connection), not a limit you enforce.

---

## The connection pool

`TNghttp2ClientPool` (`Nghttp2.Client.Pool`) hands each thread its own connection,
keyed by scheme+host+port, with a per-key ceiling and idle eviction:

```pascal
uses Nghttp2.Client, Nghttp2.Client.Pool;

var
  P: TNghttp2ClientPool;
  C: TNghttp2Client;
  R: TNghttp2Response;
begin
  P := TNghttp2ClientPool.Create;          // defaults below
  try
    C := P.Acquire('example.test', 443, {AUseTls=}True);   // connected, yours
    try
      R := C.SubmitRequest('GET', '/', nil, nil);
    finally
      P.Release(C);                        // back to the idle set — do not Free it
    end;
  finally
    P.Free;
  end;
end;
```

- **Concurrency contract.** A client from `Acquire` belongs to exactly one thread
  until `Release` — which is precisely libnghttp2's one-driver rule. The pool
  never drives a client itself; it owns only the idle set, under a lock.
- **Config** (`TNghttp2ClientPoolConfig`, pass to `Create`): `MaxClientsPerKey`
  (default 8), `IdleTimeoutMS` (default 30 000; 0 = never evict), `AcquireTimeoutMS`
  (default 30 000; 0 = fail fast). At the ceiling, `Acquire` waits up to the budget
  then raises `ENghttp2ClientPool`.
- **TLS:** assign `P.TlsContext` once and pass `AUseTls := True` to `Acquire`; the
  context is shared across the pool's TLS clients and is not owned by the pool.
- **Idle eviction** is lazy (per key on each `Acquire`) and can be forced across
  all keys with `Sweep`. A peer that closed an idle socket *without* GOAWAY is not
  detected on checkout — the first request fails and you retry; a short
  `IdleTimeoutMS` bounds that window.
- **`Stats`** returns a one-lock snapshot: instantaneous `Total`/`Idle`/`InUse`
  plus cumulative `Acquires`, `AcquireWaits`, `WaitMS`, `MaxWaitMS`, `Evictions`,
  `ConnectFailures` — the numbers a concurrency problem is read from.

---

## Client-streaming and bidi bodies

For a request whose body is produced incrementally (client-streaming, or the
send side of bidi), open with `BeginStreamingRequest`, push with `SendChunk`, and
half-close with `FinishSending`:

```pascal
Id := C.BeginStreamingRequest('POST', '/upload', nil, {AStreamResponse=}False);
C.SendChunk(Id, Part1);
C.SendChunk(Id, Part2);
C.FinishSending(Id);               // trailing DATA+END_STREAM; SendChunk raises after
R := C.TakeResponse(Id);
```

Set `AStreamResponse := True` for bidi (receive with `ReadChunk` while sending).
For the typed gRPC form of all four RPC shapes, use `TGrpcChannel` —
[`doc/grpc-client.md`](grpc-client.md).

---

## What it is not

Out of scope by design (a service-to-service h2/gRPC client does not need them,
and an h2 deployment normally sits behind an L7 proxy that handles them):

- No redirect following
- No cookie jar
- No `Accept-Encoding` / response decompression
- No forward (`CONNECT`) proxy
- No HTTP/1.1 — this is prior-knowledge HTTP/2 only, with no h1 fallback

A peer that is HTTP/1.1-only, or has ALPN disabled over TLS, is refused with a
message that says so. For those features, reach for a general-purpose HTTP client.

---

## See also

- [`doc/grpc-client.md`](grpc-client.md) — the gRPC channel built on this client
- [`doc/getting-nghttp2-linux.md`](getting-nghttp2-linux.md) /
  [`doc/getting-nghttp2-windows.md`](getting-nghttp2-windows.md) — installing the
  libnghttp2 runtime
- `samples/` — runnable client programs
