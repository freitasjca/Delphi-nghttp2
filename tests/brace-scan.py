#!/usr/bin/env python3
"""Finds Pascal { } comments that the compiler will terminate EARLY.

Delphi and FPC { } comments do NOT nest: the first `}` inside one ends it, and
everything after it becomes code. So a comment that quotes Pascal-ish text
containing a brace silently truncates, and the compiler reports a syntax error
somewhere BELOW - typically at the next real statement, with a column number
that belongs to no visible line. That distance between cause and symptom is
what makes this expensive, and it has cost this project two sessions.

  { A proto3 map IS `repeated Entry {key=1; value=2;}` on the wire, so
    nothing below the parser needs a map concept. }
                    ^ comment ENDS here          ^ and this } is stray

Why the obvious scanner does not work
-------------------------------------
"Does every { have a } after it?" MODELS THE BUG AS CORRECT - it finds the
early `}`, calls the comment terminated, and reports green. A scanner written
that way was run against the line above and passed it. The assertion has to be
about nesting intent, not termination:

    a `{` appearing INSIDE the region a comment actually spans

means the author wrote a brace expecting it to nest. That is exact, not a
heuristic - there is no legitimate reason for a `{` to sit inside a { } comment.

`{$...}` is a compiler DIRECTIVE, not a comment, and is skipped: its contents
are consumed by the compiler and the rule does not apply.

Usage:  python3 brace-scan.py <file.pas|file.dpr> ...
Exit:   number of problems (0 = clean), so it can gate a build.
"""
import sys


def regions(s):
    """Yield (kind, start, end) for each string / comment / directive region,
    walking the text the way a compiler does so that a brace inside a string
    literal or a // comment is not mistaken for a comment opener."""
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == "'":
            j = i + 1
            while j < n:
                if s[j] == "'":
                    if j + 1 < n and s[j + 1] == "'":
                        j += 2
                        continue
                    j += 1
                    break
                if s[j] == '\n':
                    break
                j += 1
            yield ('str', i, j)
            i = j
            continue
        if c == '/' and i + 1 < n and s[i + 1] == '/':
            j = s.find('\n', i)
            j = n if j < 0 else j
            yield ('//', i, j)
            i = j
            continue
        if c == '(' and i + 1 < n and s[i + 1] == '*':
            j = s.find('*)', i + 2)
            j = n if j < 0 else j + 2
            yield ('(*', i, j)
            i = j
            continue
        if c == '{':
            j = s.find('}', i + 1)
            j = n if j < 0 else j + 1
            kind = '{$' if s[i:i + 2] == '{$' else '{'
            yield (kind, i, j)
            i = j
            continue
        i += 1


def scan(path):
    # Pascal ONLY. In .proto (and JSON, and C) `{ }` is a block, not a comment,
    # so every brace looks like an unterminated comment and the report is pure
    # noise. Guarded because it actually happened: a hand-typed invocation
    # included optional.proto and produced two confident false positives.
    if not path.lower().endswith(('.pas', '.dpr', '.inc', '.dpk', '.lpr')):
        print('%s: SKIPPED - not a Pascal source file' % path)
        return 0
    with open(path, encoding='utf-8') as f:
        s = f.read()
    bad = 0
    for kind, a, b in regions(s):
        if kind != '{':
            continue
        line = s.count('\n', 0, a) + 1
        if b >= len(s) and '}' not in s[a:]:
            print('%s:%d: UNTERMINATED { } comment' % (path, line))
            bad += 1
            continue
        body = s[a + 1:b - 1]
        if '{' in body:
            print('%s:%d: { } comment contains a nested "{" - the comment ENDS '
                  'at the first "}" and the rest becomes code' % (path, line))
            print('    %s' % body.strip()[:90].replace('\n', ' '))
            print('    Fix: use // for this block, or (* *), or drop the brace.')
            bad += 1
    return bad


def main(argv):
    if not argv:
        print(__doc__)
        return 0
    total = sum(scan(p) for p in argv)
    print()
    print('brace-scan: %d file(s), %d problem(s)' % (len(argv), total))
    return total


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
