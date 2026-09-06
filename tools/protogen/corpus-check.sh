#!/usr/bin/env bash
# =============================================================================
#  corpus-check.sh — run the parser over a large REAL corpus and tally why it
#  refuses. C1c of plans/horse-grpc-codegen.md.
#
#  WHY THIS EXISTS
#  ---------------
#  Our own two .proto files agree with our parser by construction. The first
#  run of this over googleapis found FOUR parser defects that 98 hand-written
#  checks and a 17-case protoc oracle had all missed — the same lesson as
#  FIX-PROTO-UINT32-1 one layer up: a system validated only against its own
#  inputs agrees with itself.
#
#  It also answers "which gap is worth closing next" with a measurement rather
#  than an intuition. That has already overturned one plan: nested flattening
#  looked like a naming detail and turned out to be 52% of the corpus, beating
#  everything else on the list.
#
#  THE CLASSIFICATION IS THE POINT
#  -------------------------------
#  ProtogenCheck reports BOTH a deliberate refusal and a parse failure as
#  `REFUSE  <path>  [<bracket>]  <reason>`. For a deliberate refusal the
#  bracket names the construct (`map`, `sint32`); for a parse failure it names
#  whatever token the parser choked on (`rpc`, `}`).
#
#  Conflating them is exactly how the first run reported "933 refusals of the
#  construct `rpc`" — ONE parser bug wearing the costume of dozens of exotic
#  features. So every refusal is sorted against a list of constructs we
#  deliberately refuse, and anything else is reported LOUDLY as a suspected
#  defect rather than tallied as a known gap.
#
#    ACCEPT            parsed
#    REFUSE (known)    a documented limitation — a GAP, expected
#    REFUSE (unknown)  probably a PARSER DEFECT — investigate
#    ERROR             crashed — definitely a defect
#
#  NOT WIRED INTO build-codec-fpc.sh, deliberately: it needs a multi-hundred-MB
#  clone and takes minutes. It is a periodic measurement, like protoc-oracle.sh
#  is a periodic differential, not a per-build gate.
#
#  USAGE
#    corpus-check.sh [corpus-dir]
#
#  With no argument it looks for ./.corpus/googleapis and offers the clone
#  command if absent. It FAILS rather than skipping when the corpus is missing:
#  a measurement that silently measures nothing is worse than none.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORPUS="${1:-$HERE/.corpus/googleapis}"
OUT="$HERE/.corpus-out"
CHECK="$OUT/ProtogenCheck"

TRUNK="${TRUNK_FPC:-/usr/local/fpc-trunk/bin/fpc}"
TU="${TRUNK_UNITS:-/usr/local/fpc-trunk/lib/fpc/3.3.1/units/x86_64-linux}"

# ── corpus ───────────────────────────────────────────────────────────────────
if [[ ! -d "$CORPUS" ]]; then
  echo "FAIL: corpus not found at $CORPUS"
  echo
  echo "  mkdir -p $HERE/.corpus"
  echo "  git clone --depth 1 https://github.com/googleapis/googleapis \\"
  echo "      $HERE/.corpus/googleapis"
  echo
  echo "Any large tree of .proto files works; pass it as the first argument."
  exit 2
fi

# ── build the verdict CLI ────────────────────────────────────────────────────
mkdir -p "$OUT"
if [[ ! -x "$TRUNK" ]]; then
  echo "FAIL: FPC trunk not at $TRUNK (override with TRUNK_FPC)"
  exit 2
fi
echo "building ProtogenCheck..."
if ! "$TRUNK" -MDelphi -O1 -Fu"$HERE" \
      -FU"$OUT" -FE"$OUT" \
      -Fu"$TU/rtl" -Fu"$TU/rtl-objpas" -Fu"$TU/rtl-console" \
      -Fu"$TU/rtl-generics" -Fu"$TU/fcl-base" \
      "$HERE/ProtogenCheck.dpr" > "$OUT/build.log" 2>&1 || [[ ! -x "$CHECK" ]]; then
  echo "FAIL: ProtogenCheck.dpr did not compile"
  grep -E "Error|Fatal" "$OUT/build.log" | head -12 | sed 's/^/  /'
  exit 2
fi

# ── constructs we refuse ON PURPOSE ──────────────────────────────────────────
# A refusal whose bracket is NOT here is a suspected parser defect. Keep this
# list in step with the parser's Refuse() calls; an entry going stale turns a
# real defect into a comfortable-looking "gap" row, which is the failure mode
# this whole script exists to avoid.
KNOWN=(
  sint32 sint64 fixed32 fixed64 sfixed32 sfixed64
  map required group extend extensions proto2 syntax
  "optional repeated" "repeated inside oneof" "optional inside oneof"
  "nested oneof" "empty oneof"
)
is_known() {
  local b="$1"
  for k in "${KNOWN[@]}"; do [[ "$b" == "$k" ]] && return 0; done
  # Unbundled well-known types are a deliberate refusal too, and the bracket is
  # the type's own name.
  [[ "$b" == google.protobuf.* ]] && return 0
  # Schema-invalid refusals name the offending NUMBER or enum name. Rare in a
  # real corpus (googleapis compiles), so treat a bare integer as known-invalid
  # rather than as a defect.
  [[ "$b" =~ ^[0-9]+$ ]] && return 0
  return 1
}

# ── run ──────────────────────────────────────────────────────────────────────
declare -A GAP UNKNOWN
ACC=0; REF=0; UNK=0; ERR=0; TOTAL=0
: > "$OUT/unknown.txt"
: > "$OUT/errors.txt"

echo "scanning $CORPUS ..."
while IFS= read -r -d '' f; do
  TOTAL=$((TOTAL+1))
  line="$("$CHECK" "$f" 2>>"$OUT/errors.txt")"
  rc=$?
  case $rc in
    0) ACC=$((ACC+1)) ;;
    1)
       # REFUSE  <path>  [<bracket>]  <reason>
       b="${line#*[}"; b="${b%%]*}"
       if is_known "$b"; then
         REF=$((REF+1)); GAP["$b"]=$(( ${GAP["$b"]:-0} + 1 ))
       else
         UNK=$((UNK+1)); UNKNOWN["$b"]=$(( ${UNKNOWN["$b"]:-0} + 1 ))
         echo "$line" >> "$OUT/unknown.txt"
       fi
       ;;
    *) ERR=$((ERR+1)); echo "$f" >> "$OUT/errors.txt" ;;
  esac
done < <(find "$CORPUS" -name '*.proto' -print0)

# ── report ───────────────────────────────────────────────────────────────────
pct() { [[ $TOTAL -eq 0 ]] && echo 0 || echo $(( $1 * 100 / TOTAL )); }

echo
echo "==========================================================="
printf "  files          %6d\n" "$TOTAL"
printf "  ACCEPT         %6d   (%d%%)\n" "$ACC" "$(pct "$ACC")"
printf "  REFUSE known   %6d   (%d%%)  deliberate gaps\n" "$REF" "$(pct "$REF")"
printf "  REFUSE UNKNOWN %6d   (%d%%)  <- suspected parser defects\n" "$UNK" "$(pct "$UNK")"
printf "  ERROR          %6d   (%d%%)  <- crashes\n" "$ERR" "$(pct "$ERR")"
echo "==========================================================="

echo
echo "-- deliberate gaps, by construct (files MENTIONING it) -----"
echo "   These OVERLAP: one file can want map AND an unbundled WKT,"
echo "   so the rows do NOT sum to the refusal count, and closing a"
echo "   gap does not accept its whole row."
for k in "${!GAP[@]}"; do printf "%8d  %s\n" "${GAP[$k]}" "$k"; done | sort -rn

if [[ $UNK -gt 0 ]]; then
  echo
  echo "-- SUSPECTED PARSER DEFECTS -------------------------------"
  echo "   A refusal naming something we never chose to refuse. The"
  echo "   first corpus run had 933 of these all naming 'rpc' - ONE"
  echo "   bug, not a family of exotic features. Read them before"
  echo "   reading anything above."
  for k in "${!UNKNOWN[@]}"; do printf "%8d  [%s]\n" "${UNKNOWN[$k]}" "$k"; done | sort -rn
  echo "   full lines: $OUT/unknown.txt"
fi

if [[ $ERR -gt 0 ]]; then
  echo
  echo "-- CRASHES ------------------------------------------------"
  echo "   $ERR file(s). An AV is not a refusal. See $OUT/errors.txt"
fi

echo
echo "Baselines to compare against (googleapis, ~7300 files):"
echo "  51%  2026-08-30  after nested flattening"
echo "  85%  2026-09-05  after WKT bundling + PRESENCE-1 + ONEOF-1"
echo "  94%  2026-09-06  after MAP-1"
echo
echo "These are RECORDED RESULTS, not targets - update the list when a"
echo "stage legitimately moves it, so a regression shows as a drop rather"
echo "than as agreement with a number nobody has re-earned."

# Exit non-zero only on things that are actually wrong. A gap is a finding, not
# a failure - same rule the conformance probe uses.
[[ $UNK -gt 0 || $ERR -gt 0 ]] && exit 1
exit 0
