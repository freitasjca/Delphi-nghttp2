# Upstream report

Filed against FPC at <https://gitlab.com/freepascal.org/fpc/source/-/issues>.

Attach `Corpus.S6854.Google.Iam.V3.PrincipalAccessBoundaryPolicyResources.Messages.pas`
from this directory — do not paste it inline, since a transcription slip would
change the identifier lengths and the reproducer would stop reproducing.

**Compiling it here needs the trunk RTL units passed explicitly**, because this
machine also has a system FPC 3.2.2 and trunk's `ppcx64` otherwise resolves
against it and dies on `PPU Invalid Version 207 expecting 208` — which looks
like the reproducer failing when it is really a void run that never compiled:

```bash
TU=/usr/local/fpc-trunk/lib/fpc/3.3.1/units/x86_64-linux
/usr/local/fpc-trunk/bin/fpc -MDelphi -O1 -FU/tmp/fpcchk \
  -Fu"$TU/rtl" -Fu"$TU/rtl-objpas" -Fu"$TU/rtl-console" \
  -Fu"$TU/rtl-generics" -Fu"$TU/fcl-base" \
  Corpus.S6854.Google.Iam.V3.PrincipalAccessBoundaryPolicyResources.Messages.pas
```

That `-Fu` list is a local artefact and is deliberately NOT in the report: a
maintainer with a clean trunk install has matching RTL units on their default
path and needs none of it.

Record the issue URL here once it exists, so the next person reading
`crash-reduce.sh` can find the upstream status without re-deriving anything.

**Issue URL:** https://gitlab.com/freepascal.org/fpc/source/-/issues/41921

## RESOLVED upstream (2026-09-22) — root cause and fix

A maintainer diagnosed it and posted a patch within days. It is an **RTTI-name
collision**, not a size limit:

> `rtti_mangledname()` already hashes its result down to fit `maxidlen` (127).
> `ncgrtti.pas` then prepends a 9-character `itp_rttidef` prefix and stores the
> result in a `TIDString` — also capped at 127. That second truncation has **no
> hash protection**, so it can cut off the disambiguating hash the first step
> added. Two defs in one unit whose mangled names share a long common prefix —
> the same long namespaced unit name — truncate to an identical string, and
> `begin_anonymous_record()` reuses one def's cached RTTI record for the other.
> An enum's, for a class's.

Fix: two locals — `TRTTIWriter.write_rtti` and `enumdef_rtti_extrasyms` — changed
from `TIDString` to `TSymStr` (255), removing the second truncation.

**Affected:** FPC 3.3.1 trunk up to and including build 2026/07/15, which is what
we measured on. Any trunk build predating the fix will still show it.

### What this confirmed, and what it corrected

Confirmed: cumulative unit + type name length as the driver; enum *shape*
irrelevant; both error codes one bug; and that deleting **either** the enum
**or** an unreferenced empty class fixes it — those are the two halves of the
colliding pair.

Corrected, and both were ours:

- **"It is not RTTI"** (`crash-reduce.sh` header). The ablations were sound —
  `{$M+}` and `{$RTTI EXPLICIT}` really do not control it, because enum type RTTI
  is emitted regardless — but concluding RTTI was uninvolved was a leap. It is
  squarely the RTTI writer.
- **"The 88-vs-50 A/B is suspect"** (`releasing.md`, recorded 2026-09-21). Under a
  volume model a shorter prefix cannot produce more crashes; under a collision
  model it is expected, because prefix length moves where truncation cuts and so
  yields a different collision set rather than a smaller one. The measurement was
  fine; the reasoning was not.

### No local mitigation

`MAX_IDENT` was never the right lever. The string that overflows is assembled by
the compiler *after* our identifiers are hashed, so nothing protogen emits could
avoid the collision reliably. The 50 crashes stay in the `compiler crashed`
bucket until the toolchain moves past the fix.

---

## Title

Internal error 2015071503 / EListError at unit close, driven by identifier volume

## Body

**Version:** FPC 3.3.1 trunk, build 2026/07/15, target Linux x86-64.
Compiled with `-MDelphi -O1`.

**Summary.** A unit with long names fails at unit close. Nothing in the code is
implicated: the attached 56-line reproducer has no fields, no properties, no
attributes, no RTTI directives, no `uses` clause, and every method body is
empty. The error is reported one line *past* end of file.

**The trigger is identifier volume, and it is cumulative.** Three unrelated
edits each make it compile cleanly, with everything else byte-identical:

- shortening the unit name from 74 characters to 69 (below that it is also
  clean at 48, 19, 10 and 1)
- deleting the enum declaration
- deleting `TPrincipalAccessBoundaryPolicyRule`, an empty class that nothing in
  the unit references

Enum *shape* is irrelevant — `(ALLOW)`, `(ALLOW = 0)` and
`(UNSPECIFIED = 0, ALLOW = 1)` all fail identically. Only removing it entirely
helps.

**Two error codes, one cause.** The attached file reports
`EListError: List index exceeds bounds (2)`. Changing only `published` to
`public` in it reports `Internal error 2015071503` instead.

**To reproduce:** save the attachment under the unit's own filename — FPC
requires the match and otherwise stops at `Illegal unit name` before reaching
the bug — then:

```
fpc -MDelphi -O1 Corpus.S6854.Google.Iam.V3.PrincipalAccessBoundaryPolicyResources.Messages.pas
```

Optimisation level is irrelevant: no `-O`, `-O1` and `-O2` all fail.

Observed:

```
Corpus.S6854.…Messages.pas(57) Error: Compilation raised exception internally
Fatal: Compilation aborted
An unhandled exception occurred at $000000000047D9C7:
EListError: List index exceeds bounds (2)
  $000000000047D9C7
```

Line 57 of a 56-line file. The preceding "Function result does not seem to be
set" warnings and unused-`I` notes are expected — every method body is empty by
construction and none of them is related to the failure.

---

## Deliberately omitted

Two things were left out of the report, and should stay out unless asked:

- **Incidence across our corpus.** 50 of 7,301 generated schemas crash, but a
  recorded A/B has a *shorter* `--unit-prefix` producing *more* crashes (88 vs
  50), which no volume model explains. Quoting a number we cannot yet tell a
  coherent story about would invite a wrong answer.
- **The mangled-symbol theory.** That the relevant quantity is
  unit + class + method + parameter types is an inference from the type-name
  result, not something measured. It is a reasonable thing to offer if a
  maintainer asks what we think the mechanism is; it is not a finding.
