# `protogen` — `.proto` tooling for the gRPC layer

`tools/protogen/` holds the front end of a `.proto` → Object Pascal code
generator: a proto3 parser, a single-file verdict CLI, and a differential test
against `protoc`.

> **It does not generate code yet.** Today it parses a `.proto`, validates it,
> and tells you — precisely — whether this library can express it. The emitter
> is the next milestone. What ships now is useful on its own: run it against a
> schema before you hand-write the message classes, and it will tell you
> whether that work is going to pay off.

Everything here builds on both compilers and needs nothing beyond the RTL.

---

## What's in the directory

| File | What it is |
|---|---|
| `Protogen.Ast.pas` | The parsed shape of a file. Deliberately dumb — records what was written, no name resolution and no Pascal mapping. |
| `Protogen.Lexer.pas` | Tokeniser. Every token carries line and column. |
| `Protogen.Parser.pas` | Recursive descent, and where every refusal lives. |
| `ProtogenParserTests.dpr` | The gate — 98 checks. |
| `ProtogenCheck.dpr` | Parses one file, prints a verdict, sets an exit code. |
| `protoc-oracle.sh` | Asks `protoc` and this parser the same question and diffs the answers. |

---

## Running it

### Check a single schema

```bash
ProtogenCheck path/to/service.proto
```

```
ACCEPT  service.proto  (3 message(s), 0 enum(s), 1 service(s))
```

or

```
REFUSE  service.proto  [map]  (12:3) map is not supported. A map field is
encoded as a repeated entry submessage with key/value fields, which needs a
synthesised message type per map. Model it as a repeated message with explicit
key and value fields.
```

Exit codes: **0** accepted · **1** refused · **2** internal error or bad usage.

The 1-vs-2 split matters — a refusal is the tool working, an internal error is
the tool failing, and anything consuming this must not score a crash as a
successful rejection.

### The test suite

```bash
fpc -MDelphi -O1 -Fu. ProtogenParserTests.dpr && ./ProtogenParserTests
```

Runs automatically as **stage 6** of `tests/build-codec-fpc.sh` and **stage 5**
of `tests/run-tests.bat`, so you rarely need this directly.

### The protoc oracle

```bash
pip install grpcio-tools            # bundles protoc; no system package needed
bash protoc-oracle.sh               # the built-in 17-case gate
bash protoc-oracle.sh --corpus DIR  # survey someone else's schemas
```

It builds `ProtogenCheck` itself. It **fails rather than skips** when no
`protoc` is available: a differential test that silently did not run is worse
than no test.

---

## The proto3 subset

### Supported

| proto3 | Pascal | Notes |
|---|---|---|
| `int32` `int64` | `Integer` `Int64` | |
| `uint32` `uint64` | `Cardinal` `UInt64` | Since **1.10.0** — earlier versions encoded these incorrectly above 2³¹. |
| `bool` | `Boolean` | |
| `float` `double` | `Single` `Double` | |
| `string` | `string` | Always UTF-8 on the wire, whatever `string` means to your compiler. |
| `bytes` | `TBytes` | A proto3 scalar, **not** `repeated uint8`. |
| `enum` | a Pascal enum | Mapped by **ordinal**, so the first value must be 0. |
| message | a class reference | |
| `repeated T` | `TArray<T>` | Packed for numerics, LEN-per-element otherwise. |
| `service` / `rpc` | interface + methods | All four shapes: unary, server-, client-streaming and bidi. |

### Refused, and why

The parser recognises **more** of proto3 than the library can express. That is
deliberate: a parser that simply did not know the word `sint32` would report
*"unknown type"*, which names the wrong problem and sends you hunting for a
typo in your own schema.

**Structural — the wire layer has these, the attribute cannot ask for them**

`sint32` `sint64` `fixed32` `fixed64` `sfixed32` `sfixed64`

`TProtoWriter` implements every one of these encodings. The gap is that
`TProtoMemberAttribute` carries only a **tag**, so a property has no way to
request a wire form. Lifting this means an attribute overload — a real change,
but an additive one.

*Workaround:* use `int32`/`int64`/`uint32`/`uint64`. You lose the encoding-size
optimisation, not correctness.

**No representation**

| Feature | Why |
|---|---|
| `map<K,V>` | Encoded as a repeated entry submessage, so it needs a synthesised message type per map. Model it as a `repeated` message with explicit key and value fields. |
| `oneof` | A tagged union with presence semantics; nothing here can express which member is set. |
| `optional` | proto3 explicit presence needs a has-bit. Worse, the serializer currently emits **even default-valued scalars**, so "set to zero" and "not set" are indistinguishable on the wire. Drop the keyword — implicit presence is the proto3 default. |

**Deferred — a naming problem, not a wire problem**

Nested `message` / `enum` declarations. The codec handles submessages perfectly
well; Pascal simply has no nested class scope to mirror `Outer.Inner`, so the
generator would have to invent a flattening rule. Declare it at file scope and
reference it by name.

**Out of scope**

proto2 syntax, `required`, `group`, `extend`/`extensions`, and the protobuf
well-known types (`google.protobuf.*`), which are not bundled.

**Rejected as invalid**, matching `protoc`: duplicate field numbers, field
number 0, numbers in the 19000–19999 range protobuf reserves for itself, and a
first enum value that is not 0.

---

## Writing message and service units by hand

Until the emitter lands this is the manual path — and it is worth reading even
afterwards, because these are the rules the generator will enforce. Five of the
six fail **only on FPC**, and they fail in ways that name the wrong cause.

```pascal
unit MyApp.Messages;

{$M+}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

{$IF DEFINED(FPC)}
  {$RTTI EXPLICIT PROPERTIES([vcPublished]) FIELDS([vcPublic]) METHODS([vcPublic])}
{$ENDIF}

uses
  Nghttp2.Protobuf;

type
  [TGrpcMessage]
  TGreetRequest = class
  private
    Fname: string;
  published
    [TProtoMember(1)]
    property name: string read Fname write Fname;
  end;
```

| Rule | What breaks without it |
|---|---|
| `{$M+}` unit-wide | `No RTTI for class %s` when serialising |
| `{$RTTI EXPLICIT …}` **inside** `interface` — FPC only | `GetProperties` returns 0; `RegisterService<T>` registers nothing and every call answers UNIMPLEMENTED |
| Properties in `published` | Access violation in `TRttiProperty.SetValue`, from null field offsets |
| Interface derives `IInvokable` **and** has a GUID | RTTI method dispatch fails |
| `[TGrpcService('pkg.Service')]` on the interface | `RegisterService<T>` raises "lacks a `[TGrpcService]` attribute" |
| Impl overrides `_AddRef`/`_Release` → `-1` | The service object is destroyed mid-`Invoke` |

Field **names** may differ from the `.proto` — proto3 keys off the tag number,
not the name — which is how a field called `message` becomes a property called
`text`. Tag numbers are the contract; keep them stable.

---

## Design notes

**Why it lives in this repo rather than the Horse provider.** Generated code
registers against `TGrpcRegistry`, and both consumers dispatch from that same
registry: the standalone library, and `horse-provider-nghttp2`. One output
serves both hosts, so nothing Horse-specific belongs in the generator.

**Why the parser refuses instead of ignoring.** Every refusal names the
construct, gives the position, and distinguishes a structural limit from a
not-yet. Silently mis-encoding a field is far worse than declining it — a
lesson this codebase paid for directly, when `uint32` values above 2³¹ went
onto the wire wrong for months without a single failing test.

**Why the oracle exists.** Every validation rule in the parser was hand-derived
from the proto3 spec. `protoc-oracle.sh` asks `protoc` the same yes/no question
per schema and classifies the disagreement:

| protoc | protogen | meaning |
|---|---|---|
| ACCEPT | ACCEPT | fine |
| ACCEPT | REFUSE | a documented gap — valid proto3 we decline |
| REJECT | REFUSE | fine, both saw an invalid schema |
| **REJECT** | **ACCEPT** | **a bug** — we would emit Pascal from a schema `protoc` will not compile |

Only that last row is a defect, and nothing else in the suite can catch it.
Current result against libprotoc 35.1: 17 cases, **0 bugs**, with all four
hand-derived rules confirmed by `protoc`.

Each built-in case declares its **own** expected verdict. Without that, a parser
bug that wrongly rejects valid proto3 looks identical to `map` being refused on
purpose.
