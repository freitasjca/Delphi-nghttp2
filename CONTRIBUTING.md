# Contributing to Delphi-nghttp2

Thanks for looking. This file covers how to build, how to run the gates, and the
two conventions that matter most in this codebase.

Toolchain and runtime prerequisites live in the README under
[Requirements](README.md#requirements) and are not repeated here.

---

## The dual-compilation rule

Every change to `src/` must compile and pass under **both** toolchains:

- **Delphi** 10.4 Sydney or later
- **Free Pascal** — 3.2.2 for the HTTP/2 transport, TLS and streaming;
  **trunk 3.3.1** for the protobuf/gRPC codec (3.2.2's `Rtti` unit declares no
  `TCustomAttribute` and its compiler rejects `{$RTTI EXPLICIT}`, both of which
  the attribute-driven serializer needs)

`{$MODE DELPHI}` is required on the FPC side. Any `uses` clause that differs
between compilers is split with `{$IF DEFINED(FPC)} ... {$ELSE} ... {$IFEND}`.

A change that passes on one compiler and was never tried on the other is not
finished. Most defects found late in this repo were found by the other compiler.

---

## Running the gates

### Windows / Delphi

```cmd
cd Delphi-nghttp2\tests
run-tests.bat
```

Ends with a plain `ALL STAGES PASSED` banner. Anything else is a failure.

### Linux / FPC

```bash
cd Delphi-nghttp2/tests
bash build-codec-fpc.sh 2>&1 | grep -nE "FAIL|Fatal:|Error:" | head
```

**`build-codec-fpc.sh` prints no pass banner.** It ends on whatever the last
stage printed, so a `FAIL` in the middle of the run looks like success if you
only read the tail — hence the grep. Two things about that command are
deliberate:

- The capital **E** in `Error:` — FPC capitalises it. A lowercase `error:`
  pattern matches only the `Fatal: There were 1 errors` summary line and hides
  the message that says what was actually wrong.
- Never pipe it through `tail` alone. A pipe discards the exit status, so a
  failing build then looks green twice over.

`Nghttp2ServerSmoke` is the only stage that starts a real server. It **skips
loudly** when libnghttp2 is absent — a skip is not a pass, and the output says
so on purpose.

### Code generation changes

Changes under `tools/protogen/` have their own checks, over a corpus of real
googleapis schemas:

```bash
cd tools/protogen
bash compile-check.sh --all      # generate, then compile, every corpus schema
bash corpus-check.sh             # parser acceptance across the corpus
bash protoc-oracle.sh            # differential: our parser vs protoc
```

`protoc-oracle.sh` classifies four cells; only *protoc rejects + we accept* is a
defect, because that means we would emit Pascal from a schema protoc will not
compile. It fails rather than skips when protoc is missing.

A compile check proves the generated code **compiles**. It does not prove the
generated code is **correct** — assert emitted types and round-trips in
`ProtogenEmitTests` when behaviour changes, not just that the corpus still builds.

---

## Conventions

**Commit messages** follow [Conventional Commits](https://www.conventionalcommits.org/):
`feat(client):`, `fix(ffi):`, `docs:`, `chore(release):`.

**Comments carry the reason, not the restatement.** This codebase documents *why*
a thing is the way it is, and tags a decision so it can be found later —
`FIX-ALPN-RACE-1`, `PRESENCE-1`, `IMPORT-1`, `WIRE-FORM-1`. When you fix
something subtle, leave the tag and the reasoning behind it. Roughly one line in
five of `src/` is a comment, and that is the intended ratio, not an accident:
most of these units encode a constraint that is invisible from the code alone.

**Refusals explain themselves.** When the library or the generator rejects
something, the message should name the construct, say why it cannot be
supported, and be longer than the construct it is refusing — the reader should
not have to go hunting for a typo that is not there.

---

## Releasing

Maintainer checklist: [`doc/releasing.md`](doc/releasing.md). Every step in it
exists because skipping it cost something once.
