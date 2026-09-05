# Code generation guide — `.proto` → Object Pascal

`protogen` turns a proto3 schema into the Pascal units this library's gRPC
layer needs. One command produces four units; you implement your handlers in
one of them and never touch the other three again.

This guide is the *how*. For which proto3 constructs are supported and why the
rest are refused, see [`protogen.md`](protogen.md) — that list is the contract,
and running `protogen` against a schema before you commit to it will tell you
in one line whether this library can express it.

> **Running Horse rather than this library standalone?** Both work — the
> generated code registers against `TGrpcRegistry`, which the standalone server
> and `horse-provider-nghttp2` both dispatch from. But if you are on Horse's
> *own* gRPC stack instead, you want a different tool:
> [`protogen-vs-horse-pb-compiler.md`](protogen-vs-horse-pb-compiler.md).

---

## Requirements

Delphi 10.4+ or FPC trunk 3.3.1. **FPC 3.2.2 will not work** — it has no
`{$RTTI EXPLICIT}` and no `TCustomAttribute`, and the whole attribute-driven
serializer depends on both.

**On FPC you also need libffi on the unit path.** This is not optional and it
is not obvious:

```
-Fu$FPCUNITS/libffi
```

The generated registration unit calls `TGrpcRegistry.RegisterService<T>`, which
dispatches through `TRttiMethod.Invoke`, which needs `ffi.manager`. Without the
path you get:

```
Nghttp2.Grpc.Registry.pas(350,3) Fatal: Can't find unit ffi.manager
```

That error names a unit you have never heard of and says nothing about your
`.proto`, so it is worth knowing in advance. Note that `-dNGHTTP2_GRPC_NO_FFI`
is **not** the answer here — that define is for servers that register only
through the procedural `RegisterMethod`, which never reaches `Invoke`.
Generated code always uses the interface path for unary methods.

Delphi needs nothing extra.

---

## Quick start

Build the CLI once:

```bash
# Delphi
dcc64 -B tools/protogen/Protogen.dpr
```

On FPC, build it through the test script rather than by hand:
`bash tests/build-codec-fpc.sh` compiles the CLI as stage 11 and leaves the
binary in `tests/.fpc-out/protogen-bin/Protogen`. The script pins trunk and the
exact `-Fu` list, and an incomplete list does not fail cleanly — FPC falls back
to the distro's 3.2.2 units and reports `PPU Invalid Version 207 expecting 208`,
which reads as a missing unit but is really a wrong-compiler unit.

Generate:

```bash
Protogen -i greeter.proto -o src/ --unit-prefix Sample.Greeter
```

```
[write] Sample.Greeter.Messages.pas
[write] Sample.Greeter.Interfaces.pas
[write] Sample.Greeter.Service.pas
[write] Sample.Greeter.Registration.pas
```

| flag | meaning |
|---|---|
| `-i`, `--input` | the `.proto` file |
| `-o`, `--output` | directory to write into (created if absent) |
| `--unit-prefix` | dotted prefix; unit names become `<prefix>.Messages` etc. |
| `--dry-run` | report what would be written, touch nothing |
| `-h` | usage |

Exit codes: **0** success · **1** bad arguments, or the schema was refused ·
**2** an I/O error.

---

## The four units

Three are generated output. One is yours.

### `<prefix>.Messages.pas` — always regenerated

One class per proto message, with `[TProtoMember(N)]` on each published
property. The tag number is what goes on the wire, so property names are free
to differ from the proto field names — and sometimes must:

- `message` → `text`, `string` → `str` (semantic renames)
- any other reserved word → `word_` (e.g. `type` → `type_`)
- nested `Outer.Inner` → `TOuterInner`, flattened to file scope, because Pascal
  has no nested class scope

Every rename is deterministic and carries a comment naming the original field.

### `<prefix>.Interfaces.pas` — always regenerated

One `IInvokable` interface per service, carrying
`[TGrpcService('package.Service')]` and a deterministic GUID.

**Unary RPCs only.** This is not an omission. The dispatcher requires the shape
`function(const ARequest: T): TResponse` — a single message in, a single
message out — and a stream is a sequence, not a return value. Streaming RPCs
are served through the registration unit instead.

The GUID is derived from the service's full name by hash, so regenerating an
unchanged schema produces an identical file. Nothing churns in your diffs.

### `<prefix>.Service.pas` — **written once, never overwritten**

Your implementation. Generated as a skeleton whose methods all raise
`ENotImplemented`; you fill them in.

Regenerating never touches an existing one. If the file is already there, the
new skeleton is written beside it as `<prefix>.Service.new.pas` and you are
told:

```
[info] Sample.Greeter.Service.pas preserved — new skeleton → Sample.Greeter.Service.new.pas
```

Diff the two, take what you need, delete the `.new`. This is the only generated
file that holds your code, which is why it is the only one protected.

### `<prefix>.Registration.pas` — always regenerated

One `Register<Service>(AImpl)` per service, wiring everything to the registry:

```pascal
procedure RegisterGreeter(const AImpl: TGreeterServiceImpl);
begin
  TGrpcRegistry.RegisterService<IGreeter>(AImpl);

  TGrpcRegistry.RegisterServerStream('/greeter.Greeter/ListGreetings',
    TGreetRequest, TGreetResponse, AImpl.ListGreetings);
  ...
end;
```

Unary methods go through `RegisterService<T>` in one call — it walks the
interface by RTTI and derives each path from `[TGrpcService]`. Streaming
methods are registered explicitly, one call each, because they have no
IInvokable shape to reflect over.

**Do not edit this file, and do not exempt it from regeneration.** It is
precisely the file that must track the `.proto`. If it were preserved like
`.Service.pas`, adding an RPC would leave it unregistered — and that surfaces
at run time as an unimplemented path, with nothing in the build to explain it.

---

## Wiring it into a server

```pascal
uses
  Sample.Greeter.Service,
  Sample.Greeter.Registration;

var
  LGreeter: TGreeterServiceImpl;
begin
  LGreeter := TGreeterServiceImpl.Create;
  RegisterGreeter(LGreeter);
  // ... start the server
```

**Do not free the instance.** `RegisterService<T>` stores an interface
reference, so the registry owns it from that point; the impl derives from
`TInterfacedObject` and normal refcounting keeps it alive. Freeing it manually
pulls it out from under the registry.

For a service with *only* streaming RPCs, `RegisterService<T>` is not called at
all — the registry then holds method pointers but no interface reference, so
keep the instance alive yourself for the process lifetime.

Do **not** override `_AddRef` / `_Release` to return `-1`. Some older gRPC
guidance says to; on FPC trunk it causes an access violation when the interface
enters a generic method. The generated skeleton deliberately does not.

---

## Streaming handler signatures

The three streaming shapes take fixed signatures, dictated by the registry's
handler types. Note the message parameters are **`TObject`**, not the concrete
message class — the method pointer has to be assignment-compatible with the
handler type, and the dispatcher casts internally:

| shape | generated signature |
|---|---|
| server-streaming | `procedure M(const ARequest: TObject; const AWriter: IGrpcStreamWriter)` |
| client-streaming | `procedure M(const AReader: IGrpcStreamReader; const AResponse: TObject)` |
| bidirectional | `procedure M(const AReader: IGrpcStreamReader; const AWriter: IGrpcStreamWriter)` |

Cast on entry, then work with the typed message:

```pascal
procedure TGreeterServiceImpl.ListGreetings(const ARequest: TObject;
  const AWriter: IGrpcStreamWriter);
var
  LReq: TGreetRequest;
  I: Integer;
begin
  LReq := TGreetRequest(ARequest);
  for I := 1 to 5 do
  begin
    // Each Send takes ownership of the object passed to it — allocate inside
    // the loop and do not free.
    AWriter.Send(MakeGreeting(LReq.name, I));
  end;
end;
```

Ownership differs by shape and is easy to get wrong: for server-streaming the
writer takes ownership of each message you send; for client-streaming the
response object is dispatcher-owned, so populate it and do not free it.

---

## Regenerating after a schema change

Run the same command again. Three units are rewritten, `.Service.pas` is
preserved, and any new RPC appears in the `.new.pas` skeleton for you to copy
across.

Because the GUID is hashed from the service name rather than randomly
generated, an unchanged schema regenerates byte-identically — regeneration is
safe to run in a build step.

---

## Verifying

The repo gates the generator itself, on both compilers:

```bash
bash tests/build-codec-fpc.sh    # FPC trunk
tests\run-tests.bat              # Delphi
```

Two of those stages are worth knowing about, because they answer questions the
others cannot. One compiles protogen's *output* — every other gate compares
generated text against expected text, which cannot catch a type that does not
exist or a method pointer that is not assignment-compatible. The other round-
trips boundary values through Google's own protobuf implementation, because a
codec shared by our client and our server will agree with itself even when its
bytes are wrong; that is exactly how a real `uint32` corruption bug survived
for years here.

---

## Known limits

`map`, `oneof`, `optional`, `sint*`, `fixed*`, `sfixed*` and proto2 are refused
at parse time, with a message naming the construct and explaining why —
[`protogen.md`](protogen.md) has the full list and the reasoning. A refusal is
the tool working: these would otherwise encode to bytes a peer decodes
differently, with no error anywhere.

Two further points that are easy to miss:

- The codec **emits default-valued scalars** where canonical proto3 omits them.
  This is interoperable — a peer decodes the same value either way — but it is
  not canonical, and it is why `optional` cannot be supported yet: with
  defaults on the wire, "set to zero" and "not set" are indistinguishable.
- Well-known types are bundled only in part. `Timestamp`, `Duration`,
  `FieldMask`, `Empty` and the wrappers work; `Struct`, `Value`, `ListValue`
  and `Any` are refused because they need `oneof` or dynamic typing.
