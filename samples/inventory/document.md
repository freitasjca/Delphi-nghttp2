# Protobuf + gRPC, end to end

A warehouse inventory service, in Pascal, on this library alone. No web
framework, no adapter layer — a `TNghttp2Server`, a handler, and a dispatcher.

The point of the sample is the **division of labour** between the two
technologies, which is easy to blur:

| | answers | produces |
|---|---|---|
| **Protobuf** | *What does a `Product` look like on the wire?* | message classes + serialisation |
| **gRPC** | *How do I invoke `GetProduct` remotely?* | routing, framing, status trailers |

They meet in one file — `inventory.proto` — which is the single source of
truth. Change a field **number** there and you have changed the wire format.
Change a field **name** and you have not: the tag is the contract.

---

## What it serves

```
inventory.proto
      |
      |  Protogen -i inventory.proto -o . --unit-prefix Sample.Inventory
      v
Sample.Inventory.Messages.pas          <- protobuf half: types + codec metadata
      |
      v
Nghttp2InventoryServer.dpr             <- gRPC half: registration + handlers
```

Three RPCs, chosen to cover the three shapes a real service needs:

| RPC | shape | what it demonstrates |
|---|---|---|
| `GetProduct` | unary | one in, one out; absent vs. default |
| `CreateShipment` | unary | a `repeated` field arriving |
| `WatchStock` | server streaming | many messages over one call |

Plus `/healthz` on the same port as plain HTTP/2, because anything the
dispatcher does not recognise falls through to ordinary handling.

---

## Build

**Delphi** (from this directory):

```
dcc64 -U..\..\src Nghttp2InventoryServer.dpr
```

**FPC trunk 3.3.1** — the gRPC layer needs trunk, because 3.2.2's `Rtti` unit
declares no `TCustomAttribute`:

```
fpc -MDelphi -dNGHTTP2_GRPC_NO_FFI -Fu../../src Nghttp2InventoryServer.dpr
```

`NGHTTP2_GRPC_NO_FFI` is safe here because the sample registers with
`RegisterMethod` / `RegisterServerStream`, which never reach
`TRttiMethod.Invoke`. Drop the define if you switch to `RegisterService<T>`,
which does need dynamic invocation and therefore `ffi.manager` on FPC.

`libnghttp2 >= 1.59` must be present at run time. `Start` loads it and raises
if it is missing.

---

## Run it

### 1. Put libnghttp2 where the program will find it

Loaded at run time, not linked, so a missing library is a startup failure
rather than a build error. `Start` raises with a message naming it.

**Windows** — the DLL must sit beside the `.exe` or be on `PATH`, and its
bitness must match the compiler (`dcc64` needs the Win64 build):

```bat
copy ..\..\tests\nghttp2.dll .
```

**Linux** — `sudo apt install libnghttp2-14` (or `dnf install libnghttp2`).
The loader looks for the stable SONAME `libnghttp2.so.14`.

### 2. Start the server

```bat
Nghttp2InventoryServer.exe
```

```bash
./Nghttp2InventoryServer
```

It prints its routes and then waits on ENTER. Leave it running — every command
below goes in a **second terminal**.

```
inventory service on h2c port 19010
  /inventory.InventoryService/GetProduct      unary
  /inventory.InventoryService/CreateShipment  unary
  /inventory.InventoryService/WatchStock      server streaming
  /healthz                                    plain HTTP/2
```

The server logs each call as it handles it, so keep both terminals visible —
the client side shows what came back, the server side shows what it did.

### 3. Check it is up, with no extra tools

```bash
curl --http2-prior-knowledge http://localhost:19010/healthz
```

Prints `ok`. This proves the HTTP/2 listener works before any gRPC is
involved, which separates "the server is broken" from "my grpcurl invocation
is wrong" — worth doing first when something does not answer.

> **From WSL against a Windows-hosted server**, use the host IP rather than
> `localhost`, and open the port through Windows Firewall — it *drops*
> unsolicited inbound instead of rejecting, so a blocked port looks like a
> hang rather than a refusal. `ip route | awk '/default/{print $3}'` gives you
> the address; substitute it for `localhost` everywhere below.

### 4. Call the RPCs

Needs [`grpcurl`](https://github.com/fullstorydev/grpcurl). There is no Pascal
client yet — see [below](#the-missing-half-a-pascal-client).

**Unary, a hit:**

```bash
grpcurl -plaintext -import-path . -proto inventory.proto \
        -d '{"barcode":"ABC123"}' \
        localhost:19010 inventory.InventoryService/GetProduct
```

```json
{ "found": true,
  "product": { "id": "1001", "barcode": "ABC123",
               "name": "Mechanical keyboard", "stock": 17 } }
```

**Unary, a miss** — note this is a *successful* RPC, not an error:

```bash
grpcurl -plaintext -import-path . -proto inventory.proto \
        -d '{"barcode":"NOPE"}' \
        localhost:19010 inventory.InventoryService/GetProduct
```

```json
{}
```

Empty, because `found` is `false` and `product` is absent — and proto3 omits
both. That emptiness *is* the answer, which is the point of section 3 below.

**Unary with a repeated field:**

```bash
grpcurl -plaintext -import-path . -proto inventory.proto \
        -d '{"product_ids":[1001,1002,1004]}' \
        localhost:19010 inventory.InventoryService/CreateShipment
```

```json
{ "shipmentId": "9001", "lineCount": 3 }
```

Two things to notice. `shipment_id` comes back as `shipmentId` — grpcurl
renders proto field names in lowerCamelCase, and the *field number* is what
actually crossed the wire. And `9001` is quoted: JSON cannot hold an `int64`
exactly, so every 64-bit field is a string in this output.

**Server streaming** — time it, because the timing is the demonstration:

```bash
time grpcurl -plaintext -import-path . -proto inventory.proto \
        -d '{"barcode":"ABC123"}' \
        localhost:19010 inventory.InventoryService/WatchStock
```

Five `Product` messages with `stock` counting 17, 16, 15, 14, 13 — arriving
spread across roughly two seconds rather than in one burst at the end. If they
appeared all at once you would be looking at a batched response, not a stream.

### 5. Stop it

Press ENTER in the server terminal. It calls `Stop`, then clears the registry
before freeing the service instance — in that order, because the registry
holds method pointers into it.

---

---

## The three things worth copying

### 1. Ownership is **not** the same for unary and streaming

This is the one that bites.

**Unary** — the dispatcher creates both the request and the response, and
frees both. Your handler fills the response in and frees *nothing*:

```pascal
procedure TInventoryService.GetProduct(const ARequest, AResponse: TObject);
begin
  TGetProductResponse(AResponse).found := True;      // just fill it in
end;                                                  // free nothing
```

**Streaming** — `IGrpcStreamWriter.Send` *takes ownership* of each message and
frees it, even if serialisation raises. So you allocate one message per
iteration and never free it:

```pascal
LMsg := TProduct.Create;
LMsg.stock := LStock;
AWriter.Send(LMsg);          // Send frees LMsg — do NOT touch it after this
```

Reusing a single instance across sends is a use-after-free on the second
`Send`. The asymmetry is deliberate: a unary response has one owner for its
whole life, a streamed message is handed off and forgotten immediately.

The exception inside a unary response is a **message-typed field**. It is an
owned instance, so the response's destructor frees it — which is why
`TGetProductResponse` declares a destructor at all.

### 2. The path is the routing key

```pascal
TGrpcRegistry.RegisterMethod('/inventory.InventoryService/GetProduct', ...);
```

That is `/<proto package>.<service>/<rpc>`, exactly as written in the `.proto`.
Get it wrong and the call 404s at the dispatcher with no hint that a service
exists at all.

### 3. Absent and default are the same thing in proto3

`GetProduct` returns a wrapper with a `found` Boolean rather than a bare
`Product`. That is not ceremony. A product whose every field happens to hold
its default encodes to **zero bytes**, which is byte-identical to a product
that was never set. Without `found`, "no such barcode" and "a real product
with id 0, empty name, no stock" are indistinguishable to the client.

The same rule explains `CreateShipment`: an empty `product_ids` and an omitted
`product_ids` are the same on the wire. If that distinction matters to your
domain, it has to be carried explicitly.

---

## Regenerating the messages

`Sample.Inventory.Messages.pas` is checked in so the sample builds without
running the generator, but it is generated output:

```bash
Protogen -i inventory.proto -o . --unit-prefix Sample.Inventory
```

Three rules govern that unit, and all three are load-bearing — they are in its
header too, because each one fails *silently*:

1. `{$M+}` unit-wide, or the codec finds no properties and every field arrives
   blank. Not an error — blank.
2. Serialisable properties in `published`. A public or private-storage property
   carries no offset information and `SetValue` access-violates.
3. On FPC, `{$M+}` alone is not enough: `{$RTTI EXPLICIT ...}` is required or
   `GetProperties` returns zero. It must sit **inside** `interface`.

### What the generator refuses

If you extend `inventory.proto`, note that `sint32`/`sint64`,
`fixed*`/`sfixed*` are **refused at build time**. That is deliberate and it
protects you: the codec selects a wire type from the Pascal type, and RTTI
cannot express the zigzag/fixed-width distinction — so generating code for
them would put *wrong bytes* on the wire that a peer decodes as a different
value with no error anywhere. A build-time refusal is the cheap version of
that discovery.

`map`, `oneof`, `optional`, the `Struct` family, `Any`, and the whole `import`
closure are all supported.

---

## The missing half: a Pascal client

This library **serves** gRPC; it does not yet **call** it.

`TNghttp2Client` speaks HTTP/2, but it knows nothing of gRPC's length-prefixed
framing, `grpc-status` trailers, or deadlines — so there is no
`Client.GetProduct(Request)` to show, and writing one by hand here would mean
reimplementing the framing this library already contains on the server side.

That is roadmap item **B2**. When it lands, the client half belongs in *this*
sample: the same three RPCs called from Pascal against this same server, so
the contract is exercised from both ends in one process. The `.dpr` carries a
`B2 PLACEHOLDER` block marking exactly where it goes.

Until then, `grpcurl` is the client — and it has one advantage worth keeping
even afterwards: it is an **independent implementation**. A bug shared between
our client and our server is invisible to a test that uses both, and visible
immediately to one that does not.

---

## Language independence, concretely

The contract is the `.proto`, not the Pascal:

```
              inventory.proto
                     |
        +------------+------------+
        v            v            v
     Pascal         C#          Python
   this server    backend     data service
```

The Pascal server does not know what wrote the client, and the client does not
know the server is Delphi. They agree on `inventory.InventoryService` and on
field numbers 1–4. Everything else is an implementation detail on both sides —
which is the entire reason to pay protobuf's ceremony cost in the first place.
