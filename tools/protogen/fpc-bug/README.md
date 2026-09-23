# FPC compiler crash — minimal reproducer

`Corpus.S6854.Google.Iam.V3.PrincipalAccessBoundaryPolicyResources.Messages.pas`
is a 56-line unit that makes FPC 3.3.1 trunk die at unit close. It is kept here
because it took 543 compiles to find and would otherwise have to be re-derived.

**This is an upstream FPC bug, not a defect in generated Pascal.** An internal
error is the compiler asserting against itself. The file is valid Object Pascal.

## Reproducing

```bash
/usr/local/fpc-trunk/bin/fpc -MDelphi -O1 \
  Corpus.S6854.Google.Iam.V3.PrincipalAccessBoundaryPolicyResources.Messages.pas
```

Expect `EListError: List index exceeds bounds (2)`, reported one line *past* end
of file.

**Keep the filename.** FPC requires it to match the unit name; renamed, it stops
at `Illegal unit name` at line 1 before reaching the bug — a void experiment that
reads like a pass. That trap cost six meaningless results once already, which is
why `crash-reduce.sh` stages every variant under the real name.

It needs no project unit: the `uses` clause was removed and it still crashes.

## What it establishes

**ROOT CAUSE (FPC upstream #41921, diagnosed and fixed 2026-09-22): an RTTI-name
collision.** `rtti_mangledname()` already hashes a name down to fit 127
characters; `ncgrtti.pas` then prepends a 9-character prefix and stores the
result in a `TIDString` — also capped at 127 — and *that* truncation has no hash
protection. Two types in one unit whose mangled names share a long common prefix
(the same long namespaced unit name) truncate to an identical string, and
`begin_anonymous_record()` reuses one type's cached RTTI record for the other:
an enum's, for a class's. Fixed by widening two locals to `TSymStr`.

The observations below were how it was narrowed down before upstream answered.
"Cumulative identifier volume" was a good approximation of the wrong model — the
real variable is whether two names *collide* after truncation, which is why
deleting **either** member of the colliding pair fixes it. Three unrelated edits
each make it compile, everything else byte-identical:

- shorten the unit name from 74 characters to 69
- delete the enum
- delete `TPrincipalAccessBoundaryPolicyRule`, an empty class nothing references

Enum *shape* is irrelevant — `(ALLOW)`, `(ALLOW = 0)` and
`(UNSPECIFIED = 0, ALLOW = 1)` all fail identically.

Ruled out, each against a control: RTTI directives, `{$M+}`, the `[TProto*]`
attributes, `published` visibility, the optimiser, fields, properties, method
bodies, and the `uses` clause. A version with **zero property declarations**
still crashed.

**Both crash signatures are one bug.** This file reports `EListError`; changing
only `published` to `public` reports `Internal error 2015071503` instead. The
34 + 16 split in `.compile-out/crashes.txt` is one defect surfacing two ways.

Full derivation in `crash-reduce.sh`'s header; the length sweep is in
`crash-namelen.sh`.

## Why there is no local workaround — settled, not pending

`MAX_IDENT` in `Protogen.Emitter.pas` bounds a *source* identifier at 120. The
type name that triggers this is 41 characters, so it never fires — the limit
measures a string that is never the one overflowing.

And no emitter change can help, because the string that overflows is assembled
by the compiler *after* our identifiers have already been hashed. There is
nothing protogen could emit differently. The crashes clear when the toolchain
moves past the upstream fix.

This also explains the one observation that looked impossible: `releasing.md`
records a corpus A/B where the *shorter* `--unit-prefix` produced *more* crashes
(88 vs 50). Under a volume model that cannot happen; under a collision model it
is expected, because prefix length moves where truncation cuts and so yields a
*different* collision set rather than a smaller one. That A/B was briefly filed
as a suspect measurement on 2026-09-21 — it was not; the model was.
