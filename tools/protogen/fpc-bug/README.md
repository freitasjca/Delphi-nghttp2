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

The cause is **cumulative identifier volume**, not any construct. Three
unrelated edits each make it compile, everything else byte-identical:

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

## Why there is no local workaround yet

`MAX_IDENT` in `Protogen.Emitter.pas` bounds a *source* identifier at 120. The
type name that triggers this is 41 characters, so it never fires — the limit
measures a string that is never the one overflowing.

A mitigation would have to bound combined volume instead, and that is not a
change to make casually: `releasing.md` records a corpus A/B where the *shorter*
`--unit-prefix` produced *more* crashes (88 vs 50), which no volume model
explains. Reconcile that first, and validate on a full
`compile-check.sh --all` — tuning against the crashing subset is what produced
the `C<N>` revert and 81 new failures.
