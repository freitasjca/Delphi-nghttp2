#!/usr/bin/env bash
# =============================================================================
#  compile-check.sh — generate Pascal from real schemas and COMPILE it.
#
#  ── The blind spot this closes ──
#
#  corpus-check.sh runs the parser and (since 2026-09-07) the emitter, so it
#  catches a refusal or a crash. It cannot catch the thing that actually bit
#  twice that day: output that emits perfectly happily and then does not
#  compile.
#
#    FORWARD-1        a message referencing one declared later - TA named TB
#                     before TB existed
#    ENUMCOLLIDE-1    two enums declaring the same value name - both emitted a
#                     bare X, and Pascal enum values share unit scope
#
#  Both were only made VISIBLE by converting them into refusals, which is what
#  a corpus can count. That works for defects already known. It does nothing
#  for the next one.
#
#  So: generate, then hand the result to a compiler. The compiler is the only
#  authority on whether generated Pascal is valid, and until now it had seen
#  exactly four schemas - echo, greeter, optional.proto and the runner fixture.
#
#  ── Why only some schemas ──
#
#  A generated unit references types from every .proto its schema imports, and
#  those units are not generated here. Compiling one would fail on unresolved
#  identifiers that say nothing about the emitter. So the candidate set is:
#
#    - schemas with NO imports, or
#    - schemas importing ONLY well-known types this library BUNDLES, which
#      resolve to Nghttp2.Protobuf.WellKnown rather than to generated code
#
#  On googleapis that is 3019 of 7301 files, 41%. Chasing the other 59% means
#  resolving an import graph and generating whole closures - a different and
#  much larger tool, and the 41% is a large enough sample to find a systematic
#  emitter defect.
#
#  ── Sampling ──
#
#  Compiling 3019 units takes minutes. The default is a SAMPLE, deterministic
#  (every Nth candidate, not random) so two runs of the same corpus compile the
#  same files and a new failure means a new defect rather than a new draw.
#  --all when you want the full sweep.
#
#  USAGE
#    compile-check.sh [--sample N | --all] [corpus-dir]
#
#  ── First run, 2026-09-07 ──
#
#  302 of 3019 candidates (a 10% sample): 15 failed, in FOUR distinct classes.
#  The full sweep then found three MORE classes the sample had missed, which is
#  the argument for --all before believing a clean sample.
#
#    TBYTES-1     SysUtils never named in a generated uses clause, so ANY
#                 schema with a `bytes` field failed. Broken since C2 - months -
#                 because not one of the four compiled fixtures declares one.
#    ENUMWORD-1   enum values that are reserved words (END, STRING, AND),
#                 then values shadowing INTRINSICS the emitter calls (HIGH
#                 broke the destructor's own High()), then values shadowing
#                 TYPE names (BOOL/DOUBLE/INT64 broke TArray<Double> on a
#                 later line), then values past FPC's 126-char identifier
#                 limit colliding after truncation.
#    WKTENUM-1    a bundled well-known ENUM in a oneof got no has-bit while
#                 the group Clear and case getter both referenced one.
#    ONEOFNAME-1  a oneof member named `none` collided with the generated
#                 None sentinel.
#
#  After: 3019/3019. Every one of these predates today; what changed is that
#  something finally handed the output to a compiler.
#
#  Exit code: number of schemas whose generated Pascal did not compile.
#  A failure here is a DEFECT, not a gap - the schema was accepted, so we
#  claimed we could generate from it.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE=300
CORPUS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)    SAMPLE=0; shift ;;
    --sample) SAMPLE="${2:-300}"; shift 2 ;;
    *)        CORPUS="$1"; shift ;;
  esac
done
CORPUS="${CORPUS:-$HERE/.corpus/googleapis}"
OUT="$HERE/.compile-out"

TRUNK="${TRUNK_FPC:-/usr/local/fpc-trunk/bin/fpc}"
TU="${TRUNK_UNITS:-/usr/local/fpc-trunk/lib/fpc/3.3.1/units/x86_64-linux}"
SRC="$HERE/../../src"

if [[ ! -d "$CORPUS" ]]; then
  echo "FAIL: corpus not found at $CORPUS"
  echo "  git clone --depth 1 https://github.com/googleapis/googleapis \\"
  echo "      $HERE/.corpus/googleapis"
  exit 2
fi
if [[ ! -x "$TRUNK" ]]; then
  echo "FAIL: FPC trunk not at $TRUNK (override with TRUNK_FPC)"
  exit 2
fi

rm -rf "$OUT"; mkdir -p "$OUT/units"

# ── Build Protogen ───────────────────────────────────────────────────────────
echo "building Protogen..."
if ! "$TRUNK" -MDelphi -O1 -Fu"$HERE" -FU"$OUT/units" -FE"$OUT" \
      -Fu"$TU/rtl" -Fu"$TU/rtl-objpas" -Fu"$TU/rtl-console" \
      -Fu"$TU/rtl-generics" -Fu"$TU/fcl-base" \
      "$HERE/Protogen.dpr" > "$OUT/protogen-build.log" 2>&1 \
   || [[ ! -x "$OUT/Protogen" ]]; then
  echo "FAIL: Protogen did not compile"
  grep -E "Error|Fatal" "$OUT/protogen-build.log" | head -12 | sed 's/^/  /'
  exit 2
fi

# ── Candidate selection ──────────────────────────────────────────────────────
# Self-contained, or importing only well-known types we bundle. Anything else
# would fail on identifiers from units nobody generated - noise, not a finding.
echo "selecting self-contained schemas..."
python3 - "$CORPUS" > "$OUT/candidates.txt" <<'PY'
import sys, os, re
root = sys.argv[1]
BUNDLED = {'timestamp.proto', 'duration.proto', 'empty.proto', 'field_mask.proto',
           'wrappers.proto', 'struct.proto', 'any.proto'}
imp = re.compile(r'^\s*import\s+(?:public\s+)?"([^"]+)"', re.M)
out = []
for dp, _, fn in os.walk(root):
    for f in sorted(fn):
        if not f.endswith('.proto'):
            continue
        p = os.path.join(dp, f)
        s = re.sub(r'//[^\n]*', '', open(p, encoding='utf-8', errors='replace').read())
        imps = imp.findall(s)
        if imps and not all(i.startswith('google/protobuf/')
                            and os.path.basename(i) in BUNDLED for i in imps):
            continue
        out.append(p)
for p in sorted(out):
    print(p)
PY

TOTAL=$(wc -l < "$OUT/candidates.txt")
if [[ "$SAMPLE" -gt 0 && "$TOTAL" -gt "$SAMPLE" ]]; then
  # Every Nth, not random: two runs of one corpus must compile the SAME files,
  # so a new failure is a new defect rather than a new draw.
  STEP=$(( TOTAL / SAMPLE ))
  [[ $STEP -lt 1 ]] && STEP=1
  awk -v s="$STEP" 'NR % s == 1' "$OUT/candidates.txt" > "$OUT/selected.txt"
else
  cp "$OUT/candidates.txt" "$OUT/selected.txt"
fi
PICKED=$(wc -l < "$OUT/selected.txt")

echo "candidates: $TOTAL self-contained of $(find "$CORPUS" -name '*.proto' | wc -l)"
echo "compiling:  $PICKED"
echo

# ── Generate + compile ───────────────────────────────────────────────────────
OK=0; GENFAIL=0; COMPFAIL=0; N=0
: > "$OUT/failures.txt"

while IFS= read -r proto; do
  N=$(( N + 1 ))
  D="$OUT/g/$N"
  mkdir -p "$D"
  PREFIX="Corpus.S$N"

  if ! "$OUT/Protogen" -i "$proto" -o "$D" --unit-prefix "$PREFIX" \
        > "$D/gen.log" 2>&1; then
    # A refusal here is corpus-check's business, not ours - it means we never
    # claimed to generate this one. Counted separately so it cannot be mistaken
    # for a compile failure.
    GENFAIL=$(( GENFAIL + 1 ))
    continue
  fi

  UNIT="$D/$PREFIX.Messages.pas"
  [[ -f "$UNIT" ]] || { GENFAIL=$(( GENFAIL + 1 )); continue; }

  if "$TRUNK" -MDelphi -O1 -FU"$D" -Fu"$SRC" \
       -Fu"$TU/rtl" -Fu"$TU/rtl-objpas" -Fu"$TU/rtl-console" \
       -Fu"$TU/rtl-generics" -Fu"$TU/fcl-base" \
       "$UNIT" > "$D/build.log" 2>&1; then
    OK=$(( OK + 1 ))
  else
    COMPFAIL=$(( COMPFAIL + 1 ))
    {
      echo "=== $proto"
      grep -E "Error|Fatal" "$D/build.log" | head -4 | sed 's/^/    /'
    } >> "$OUT/failures.txt"
  fi
done < "$OUT/selected.txt"

# ── Report ───────────────────────────────────────────────────────────────────
echo "==========================================================="
printf "  attempted        %5d\n" "$PICKED"
printf "  COMPILED         %5d\n" "$OK"
printf "  refused by gen   %5d   (corpus-check's business, not a defect)\n" "$GENFAIL"
printf "  DID NOT COMPILE  %5d   <- emitter defects\n" "$COMPFAIL"
echo "==========================================================="

if [[ $COMPFAIL -gt 0 ]]; then
  echo
  echo "-- generated Pascal that a compiler rejected --------------"
  echo "   Each of these was ACCEPTED by the generator, so the tool"
  echo "   claimed it could produce Pascal for it and then did not."
  echo "   This is the class corpus-check.sh cannot see: it proves"
  echo "   the emitter RAN, not that its output builds."
  echo
  head -60 "$OUT/failures.txt" | sed 's/^/  /'
  echo
  echo "   full list: $OUT/failures.txt"
  echo "   generated units kept under: $OUT/g/<n>/"
  echo
  echo "-- distinct first errors ----------------------------------"
  grep -oE "Error: .*" "$OUT/failures.txt" | sed 's/([0-9,]*)//' \
    | sort | uniq -c | sort -rn | head -10 | sed 's/^/  /'
fi

exit $COMPFAIL
