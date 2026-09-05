# `protogen` and `horse-pb-compiler`

There are two `.proto` tools in this ecosystem. They are not competing
implementations of the same thing — they target **different runtime stacks**,
and picking the wrong one produces Pascal that will not compile against the
library you are using.

| | `protogen` | `horse-pb-compiler` |
|---|---|---|
| lives in | `Delphi-nghttp2/tools/protogen` | `horse/tools/compiler` |
| generated code uses | `Nghttp2.Protobuf`, `Nghttp2.Grpc.*` | `Horse.Grpc.Attributes`, `Horse.Core.Protobuf.Serializer` |
| serialisation | RTTI-driven at runtime | emitted `Serialize`/`Deserialize` per message |
| runs under | the standalone library **and** `horse-provider-nghttp2` | Horse's native gRPC provider |

**Use the one that matches your stack.** If your server is
`horse-provider-nghttp2` or a bare `TNghttp2Server`, that is `protogen`. If it
is `Horse.Provider.Grpc`, that is `horse-pb-compiler`.

---

## Why there are two

Horse grew its own HTTP/2 and gRPC implementation — `Horse.Core.Http2.*`
(framing, HPACK, streams), `Horse.Provider.Grpc`, `Horse.Grpc.Codec`,
`Horse.Core.Protobuf.*`. That stack is independent of `Delphi-nghttp2`, which
wraps libnghttp2 and stays framework-free by design.

Two runtimes, two attribute sets, two serialisers — so two generators. The
duplication is at the *stack* level; the compilers merely follow it.

`Delphi-nghttp2` deliberately does not depend on Horse: generated code registers
against `TGrpcRegistry`, and both the standalone library and
`horse-provider-nghttp2` dispatch from that same registry. One output serves
both hosts without a line of Horse in the generator.

---

## Scope, measured

The two tools were built for different jobs and it shows. This is not a quality
judgement — `horse-pb-compiler` is ~250 lines doing a straightforward job for
simple flat schemas, and for those it works. But the boundaries are worth
knowing before you point it at a real-world `.proto`.

Line references below are to `horse/tools/compiler/Horse.Protobuf.Compiler.Engine.pas`
so every claim is checkable.

| | `protogen` | `horse-pb-compiler` |
|---|---|---|
| parsing | lexer + recursive-descent, positions on every token | line-oriented token split (L116) |
| `/* */` comments | yes | **no** — only `//` and blanks are skipped (L119) |
| declarations spanning lines | yes | **no** — one line, one declaration |
| `repeated` | yes | **no** — see below |
| `enum` | yes | **silently dropped** — no branch matches, values are ignored |
| nested `message`/`enum` | hoisted with a qualified name | **corrupts state** — `}` clears message *and* service (L142–146) |
| `uint32`/`uint64` | yes | **no** — becomes a message reference, see below |
| well-known types | Timestamp, Duration, FieldMask, Empty, wrappers | no |
| service GUIDs | *(planned: deterministic)* | **random per run** (L237) |
| generated units on FPC | dual-compile | emits `System.Classes` (L186), which does not exist there |
| unsupported input | refused, naming the construct and the reason | mostly accepted and mis-translated |

### The two silent mis-translations

Both matter more than a plain refusal would, because nothing reports them.

**`repeated` fields.** L149 takes `Tokens[0]` as the type. For
`repeated int32 ids = 1;` the tokens are `[repeated, int32, ids, 1]`, giving
type `Trepeated`, field name `int32`, and tag `StrToIntDef('ids', 0)` = **0**.
A field with tag 0 is not valid protobuf.

**Unsigned scalars.** `MapType` (L70–80) knows seven types. Anything else falls
to `'T' + ProtoType`, so `uint32 count = 1;` generates a field of type
`Tuint32` — a *message reference* to a class that does not exist.

Neither produces a diagnostic. `protogen` refuses unsupported input by name and
explains why, which is the design decision the whole tool is built around: a
schema that cannot be expressed correctly should fail at generation time, not
on the wire.

---

## What `protogen` refuses

Being explicit, since the table above may read as if it handles everything:

- `oneof`, `optional`, `map` — need a presence model the RTTI serializer does
  not have
- `sint*`, `fixed*`, `sfixed*` — the wire layer implements them, but
  `TProtoMemberAttribute` carries only a tag, so no wire form can be requested
- `Struct`, `Value`, `ListValue`, `Any` — built on `oneof` or dynamic typing
- proto2 in any form

Against 7300 real googleapis schemas it accepts 59%, refuses the rest by name,
and has never accepted a schema `protoc` rejects. See `doc/protogen.md`.

---

## Not merging them

Asked and answered: **`protogen` stays targeted at `Nghttp2.*` and
`horse-pb-compiler` is left alone.**

A single generator emitting for both stacks would double its output surface —
two attribute vocabularies, two serialisation strategies, two sets of RTTI
rules — to serve users who have already chosen one stack or the other. The
runtimes are what diverged; making one tool paper over that hides a decision
users need to make anyway.

If the stacks converge later, the generators can follow. Until then, the useful
thing is that each says plainly which runtime it emits for — which is what this
document exists to do.
