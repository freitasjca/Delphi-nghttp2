#!/usr/bin/env python3
"""Every refusal must declare the precondition it depends on.

WHY THIS EXISTS
---------------
On 2026-09-07 four separate refusals were found whose stated reasoning was
correct while their verdict no longer followed. The worst:

    ONEOF-1 refused a message member inside a oneof because "clearing one means
    freeing it, and protogen emits no destructor".

True when written. PROTOGEN-DTOR then added destructors — and nothing connected
the two. The refusal survived four releases, was read past while three further
features were built on top of it, and cost 19% of a 7301-schema corpus.

A test could not have caught that: the refusal still worked, it simply should
not have existed any more. What was missing was a LINK from the refusal to the
thing it depends on, so that removing the limitation surfaces the refusals that
cited it.

THE MECHANISM
-------------
Each refusal site carries, on the line above it:

    { BLOCKED-BY: <token> }

and the rule is one line long:

    WHEN YOU REMOVE A LIMITATION, GREP FOR ITS TOKEN BEFORE SHIPPING.

This script enforces that every refusal has one, and reports the inventory
grouped by token — so the LIVE tokens, the ones naming a capability somebody
could add, stay visible instead of dissolving into prose nobody re-reads.

THE TAXONOMY
------------
LIVE — a capability that could be added; the refusal must be revisited if it is:

  no-wire-form-selector   TProtoMemberAttribute carries only a tag, so a
                          property cannot request zigzag or fixed width. The
                          codec implements both. An attribute overload removes
                          this, and then three refusals are wrong.
  wkt-not-bundled         A google.protobuf type nobody has written Pascal for.
                          Bundling one removes its refusal.

PERMANENT — no capability would change the answer:

  invalid-proto3          protoc rejects it too. Not our limitation.
  out-of-scope-proto2     proto2. A deliberate scope boundary.
  pascal-language         a property of Pascal itself, e.g. identifiers being
                          case-insensitive.
  user-must-choose        two things want one identifier and only the author
                          can pick. Renaming silently would change an API.
  internal-invariant      a guard on something that should be unreachable.

Adding a refusal means choosing one of these, which is the thinking that was
missing when ONEOF-1 was written.

Usage:  python3 refusal-tags.py <Protogen.Emitter.pas> <Protogen.Parser.pas>
Exit:   number of untagged sites plus unknown tokens (0 = clean).
"""
import re
import sys
import collections

LIVE = {
    'no-wire-form-selector':
        'TProtoMemberAttribute carries only a tag; the codec implements the '
        'wire forms. An attribute overload invalidates these.',
    'wkt-not-bundled':
        'A google.protobuf type with no Pascal written for it. Bundling one '
        'invalidates its refusal.',
}
PERMANENT = {
    'invalid-proto3':      'protoc rejects it too',
    'out-of-scope-proto2': 'proto2, a deliberate scope boundary',
    'pascal-language':     'a property of Pascal itself',
    'user-must-choose':    'ambiguous intent; only the author can pick',
    'internal-invariant':  'a guard on something unreachable',
}

SITE = re.compile(r'raise EEmitError\.CreateFmt\(|\b(?:RefuseAt|Refuse)\(')
TAG = re.compile(r'\{\s*BLOCKED-BY:\s*([a-z0-9-]+)\s*\}')


def main(paths):
    if not paths:
        print(__doc__)
        return 0

    found = collections.defaultdict(list)
    untagged, unknown = [], []

    for path in paths:
        lines = open(path, encoding='utf-8').read().split('\n')
        for i, line in enumerate(lines):
            if not SITE.search(line):
                continue
            # The forward declarations and the definitions of Refuse/RefuseAt
            # themselves are not refusal SITES.
            if 'procedure ' in line or 'const AConstruct' in line:
                continue
            prev = lines[i - 1] if i else ''
            m = TAG.search(prev)
            if not m:
                untagged.append((path, i + 1, line.strip()[:60]))
                continue
            token = m.group(1)
            if token not in LIVE and token not in PERMANENT:
                unknown.append((path, i + 1, token))
            found[token].append((path.split('/')[-1], i + 1))

    print('refusal inventory')
    print()
    print('  LIVE — revisit these when the named capability lands:')
    live_total = 0
    for tok, why in sorted(LIVE.items()):
        hits = found.get(tok, [])
        live_total += len(hits)
        print(f'    {len(hits):3d}  {tok}')
        print(f'         {why}')
        for f, n in hits:
            print(f'           {f}:{n}')
    print()
    print('  PERMANENT — no capability would change the answer:')
    for tok, why in sorted(PERMANENT.items()):
        hits = found.get(tok, [])
        if hits:
            print(f'    {len(hits):3d}  {tok:22s} {why}')
    print()
    print(f'  {sum(len(v) for v in found.values())} refusals, '
          f'{live_total} of them live')

    bad = 0
    if untagged:
        print()
        print('  !! UNTAGGED REFUSALS')
        print('     Every refusal must say what it depends on, so that removing')
        print('     a limitation surfaces the refusals that cited it. Pick a')
        print('     token from the taxonomy in this file\'s header.')
        for f, n, t in untagged:
            print(f'       {f}:{n}  {t}')
        bad += len(untagged)
    if unknown:
        print()
        print('  !! UNKNOWN TOKENS (not in the taxonomy)')
        for f, n, t in unknown:
            print(f'       {f}:{n}  {t}')
        bad += len(unknown)
    return bad


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
