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
#  Runs ProtogenCheck with --emit, so each schema is PARSED AND EMITTED. Until
#  2026-09-07 it parsed only, which meant "99.5% accepted" was a claim about the
#  parser being read as coverage of generated output - and two emitter defects
#  (FORWARD-1, ENUMCOLLIDE-1) sat behind it, unreachable by any corpus run.
#
#  Note what --emit still cannot see: output that emits happily and then fails
#  to compile. That is why both defects were fixed by making the emitter REFUSE.
#  A refusal is the shape this script can count; a non-compiling unit is not.
#
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
  # `emit` is an EMITTER refusal - the generator declining to produce Pascal it
  # knows would not compile. Added 2026-09-07 with ProtogenCheck --emit; before
  # that this corpus ran the PARSER only and could not see emitter defects at
  # all. FORWARD-1 and ENUMCOLLIDE-1 both hid behind that.
  emit
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
: > "$OUT/refused.tsv"

echo "scanning $CORPUS ..."
while IFS= read -r -d '' f; do
  TOTAL=$((TOTAL+1))
  line="$("$CHECK" --emit "$f" 2>>"$OUT/errors.txt")"
  rc=$?
  case $rc in
    0) ACC=$((ACC+1)) ;;
    1)
       # REFUSE  <path>  [<bracket>]  <reason>
       b="${line#*[}"; b="${b%%]*}"
       if is_known "$b"; then
         REF=$((REF+1)); GAP["$b"]=$(( ${GAP["$b"]:-0} + 1 ))
         printf '%s\t%s\n' "$b" "$f" >> "$OUT/refused.tsv"
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
# One decimal, because the closure rows are small fractions of a large corpus
# and integer division renders 37 files as "0%" - a number that reads as
# "nothing" for what is actually the second-largest opportunity on the list.
pct1() { [[ $TOTAL -eq 0 ]] && echo 0.0 \
         || awk -v n="$1" -v t="$TOTAL" 'BEGIN{printf "%.1f", n*100/t}'; }

echo
echo "==========================================================="
printf "  files          %6d\n" "$TOTAL"
printf "  ACCEPT         %6d   (%d%%)\n" "$ACC" "$(pct "$ACC")"
printf "  REFUSE known   %6d   (%d%%)  deliberate gaps\n" "$REF" "$(pct "$REF")"
printf "  REFUSE UNKNOWN %6d   (%d%%)  <- suspected parser defects\n" "$UNK" "$(pct "$UNK")"
printf "  ERROR          %6d   (%d%%)  <- crashes\n" "$ERR" "$(pct "$ERR")"
echo "==========================================================="

echo
echo "-- deliberate gaps, by FIRST construct refused ------------"
echo "   The parser is fail-fast, so each file reports exactly ONE"
echo "   construct and these rows sum to the refusal count above."
echo "   They do NOT overlap - but they ARE ORDER-DEPENDENT, which"
echo "   is worse: a file wanting Struct AND Any is counted under"
echo "   whichever the parser reached first. So a row is NOT the"
echo "   gain from closing that gap - the file may simply fall"
echo "   through to its next blocker. The closure section below is"
echo "   what answers that question."
for k in "${!GAP[@]}"; do printf "%8d  %s\n" "${GAP[$k]}" "$k"; done | sort -rn

# ── what-if closure ──────────────────────────────────────────────────────────
# "Which gap is worth closing next" cannot be read off the table above, because
# fail-fast reports only a file's FIRST blocker. Closing the biggest row can
# gain nothing if every one of its files also wants something else.
#
# So: for each refused file, find EVERY gap it contains, then count the files a
# given closure would actually accept - the ones where that gap is the ONLY
# thing in the way.
#
# The detection is TEXTUAL, and deliberately so: making the parser report all
# blockers means continuing after an error, which is a real change to it, and
# the point here is to decide what to build BEFORE building it. Two consequences
# worth stating rather than discovering later:
#
#   - a construct named in a COMMENT counts as a blocker. That over-counts
#     blockers, so every "would accept" figure below is a LOWER BOUND. Erring
#     toward under-selling a gain is the safe direction for a build decision.
#   - it cannot see a blocker the parser would find but the text does not name,
#     e.g. a schema-invalid field number. Those land in `other`.
echo
echo "-- what-if: files a closure would ACTUALLY accept ----------"

if [[ $REF -eq 0 ]]; then
  echo "   nothing refused - nothing to close."
else
  # Bundled well-known types are NOT blockers; everything else under
  # google.protobuf. is. Anchored at both ends so StringValue is not mistaken
  # for Value.
  BUNDLED='^google\.protobuf\.(Timestamp|Duration|FieldMask|Empty|DoubleValue'
  BUNDLED+='|FloatValue|Int64Value|UInt64Value|Int32Value|UInt32Value'
  BUNDLED+='|BoolValue|StringValue|BytesValue)$'

  declare -A COMBO SINGLE
  while IFS=$'\t' read -r _bracket f; do
    [[ -f "$f" ]] || continue
    set=""
    # Two groups have been removed from here, each when its gap closed:
    # struct-family at STRUCT-1, any at ANY-1. Both were caught the same way -
    # a closure list outliving its gap inflates every count with something that
    # no longer blocks anything. struct-family was found by hand, one run late;
    # `any` was found by the STALE check below, on the run after ANY-1 shipped,
    # which is what that check exists for.
    grep -Eq '\b(sint32|sint64|fixed32|fixed64|sfixed32|sfixed64)\b' "$f" \
      && set+=" group-b"
    # Anchored to line start: `required` and `extensions` are common English.
    grep -Eq '^[[:space:]]*(extend|extensions|required)\b|syntax[[:space:]]*=[[:space:]]*"proto2"' "$f" \
      && set+=" proto2"
    if grep -oE 'google\.protobuf\.[A-Za-z_]+' "$f" 2>/dev/null | sort -u \
         | grep -qvE "$BUNDLED|^google\.protobuf\.(Struct|Value|ListValue|NullValue|Any)$"; then
      set+=" other-wkt"
    fi
    [[ -z "$set" ]] && set=" other"
    set="${set# }"
    COMBO["$set"]=$(( ${COMBO["$set"]:-0} + 1 ))
    # A single-element set means this gap is the ONLY thing blocking the file.
    [[ "$set" != *" "* ]] && SINGLE["$set"]=$(( ${SINGLE["$set"]:-0} + 1 ))
  done < "$OUT/refused.tsv"

  echo "   closing ONE gap, in isolation (lower bound):"
  # Counted BEFORE the pipeline, not inside it: `for ... done | sort` runs the
  # loop in a subshell, so a counter incremented there is discarded and the
  # empty-case message fires even when there are rows. Caught by the control
  # fixture in .oracle-out - the kind of thing a syntax check never sees.
  CLOSABLE=0
  for k in "${!SINGLE[@]}"; do
    [[ "$k" == "other" ]] || CLOSABLE=$((CLOSABLE+1))
  done
  if [[ $CLOSABLE -eq 0 ]]; then
    echo "        every refused file wants more than one gap closed"
  else
    for k in "${!SINGLE[@]}"; do
      [[ "$k" == "other" ]] && continue    # residue, not a closure - see below
      printf "     %6d  %-16s  %s%% of the corpus\n" \
        "${SINGLE[$k]}" "$k" "$(pct1 "${SINGLE[$k]}")"
    done | sort -rn
  fi

  # `other` is not a gap anyone can close - it is the files whose refusal the
  # TEXT SCAN could not explain. A large or growing count here means the scan
  # has drifted from what the parser actually refuses, so it is called out
  # rather than sorted in among the build options as though it were one.
  if [[ -n "${SINGLE[other]:-}" ]]; then
    echo
    printf "     %6d  refusals the text scan cannot explain (%s%%).\n" \
      "${SINGLE[other]}" "$(pct1 "${SINGLE[other]}")"
    echo "             Not a closure - either schema-invalid files, or a"
    echo "             construct this scan does not know to look for."
  fi

  # A closure group that MATCHES files but that the parser never actually
  # refuses is a group that outlived its gap. Detected by asking whether any
  # first-refusal bracket belongs to it: the brackets are what the parser really
  # said, the group patterns are only a guess about why.
  #
  # Not hypothetical. struct-family sat here for one run after STRUCT-1 closed
  # it, reporting 13 files as wanting "struct-family any" when Any alone was
  # blocking them - a closure list that outlived its gap, which is exactly how
  # an oracle note goes stale.
  group_is_live() {
    local g="$1" b
    for b in "${!GAP[@]}"; do
      case "$g" in
        any)           [[ "$b" == *Any* ]] && return 0 ;;
        group-b)       [[ "$b" == sint32 || "$b" == sint64   || "$b" == fixed32 \
                       || "$b" == fixed64 || "$b" == sfixed32 || "$b" == sfixed64 ]] \
                       && return 0 ;;
        proto2)        [[ "$b" == extend || "$b" == extensions || "$b" == required \
                       || "$b" == group  || "$b" == proto2     || "$b" == syntax ]] \
                       && return 0 ;;
        other-wkt)     [[ "$b" == google.protobuf.* ]] && return 0 ;;
        struct-family) [[ "$b" == *Struct* || "$b" == *ListValue* \
                       || "$b" == *NullValue* ]] && return 0 ;;
      esac
    done
    return 1
  }

  STALE=""
  for combo in "${!COMBO[@]}"; do
    for one in $combo; do
      [[ "$one" == "other" ]] && continue
      [[ " $STALE " == *" $one "* ]] && continue
      group_is_live "$one" || STALE="$STALE $one"
    done
  done
  if [[ -n "$STALE" ]]; then
    echo
    echo "   !! STALE CLOSURE GROUP(S):$STALE"
    echo "      These match files, but the parser refuses NOTHING for them -"
    echo "      the gap closed and the detection above did not. Remove them, or"
    echo "      every count here is inflated by a gap that no longer exists."
  fi

  echo
  echo "   what each refused file actually wants (top 12):"
  for k in "${!COMBO[@]}"; do printf "     %6d  %s\n" "${COMBO[$k]}" "$k"; done \
    | sort -rn | head -12
  echo
  echo "   Read the FIRST list for build order: it is the number of"
  echo "   files that stop being refused if you close that one gap and"
  echo "   nothing else. The second says which gaps are entangled, so"
  echo "   a pair worth doing together shows up as one row."
fi

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
echo
echo "  PARSE ONLY - not comparable with the numbers below. Until 2026-09-07"
echo "  this script ran the parser and never the emitter, so these say nothing"
echo "  about whether generated Pascal is produced at all:"
echo "    51%  2026-08-30  after nested flattening"
echo "    85%  2026-09-05  after WKT bundling + PRESENCE-1 + ONEOF-1"
echo "    94%  2026-09-06  after MAP-1"
echo "    98%  2026-09-06  after STRUCT-1"
echo "    99%  2026-09-06  after ANY-1"
echo
echo "  PARSE + EMIT - what the generator actually accepts:"
echo "    73%  2026-09-07  first run with --emit (5351/7301, 1950 refusals)"
echo "    90%  2026-09-07  after ONEOF-2  (6642/7301, 659 refusals)"
echo
echo "  The 99% -> 73% drop was NOT a regression. It was the first honest"
echo "  measurement: 1391 files wanted a message member in a oneof, which the"
echo "  emitter refused for a reason that had expired four stages earlier."
echo
echo "These are RECORDED RESULTS, not targets - update the list when a"
echo "stage legitimately moves it, so a regression shows as a drop rather"
echo "than as agreement with a number nobody has re-earned."

# Exit non-zero only on things that are actually wrong. A gap is a finding, not
# a failure - same rule the conformance probe uses.
[[ $UNK -gt 0 || $ERR -gt 0 ]] && exit 1
exit 0
