#!/usr/bin/env bash
# =============================================================================
#  crash-reduce.sh — narrow an FPC compiler crash to a construct.
#
#  compile-check.sh counts crashes apart from emitter defects, correctly: an
#  "Internal error NNNNNNNNNN" is FPC asserting against ITSELF, not a verdict on
#  our Pascal. But "counted apart" has meant "never looked at", and the bucket
#  is now the entire gap between 7,230 and the corpus.
#
#  ── What was already ruled out, so nobody re-runs it ──
#
#  Across the 8 distinct units behind the 16 `Internal error 2015071503`
#  crashes, all four of the obvious structural explanations are DEAD. Each was
#  tested against a control of units that compiled fine in the same run:
#
#    file size            325 to 175,613 lines, all crash identically
#    forward decls        92 of 400 passing units have them
#    oneof                4 of the 8 crashers have none at all
#    self-reference       1 of 8 crashers; 47 PASSING units have one
#
#  The last one is the instructive failure: the correlation ran BACKWARDS. A
#  structural survey across 8 units has now produced four confident wrong
#  answers, which is why this script asks the compiler instead.
#
#  ── The one solid fact ──
#
#  Every 2015071503 is reported at exactly <total lines> + 1 — one line PAST
#  end of file, in all 16 cases. FPC is dying at UNIT CLOSE.
#
#  ── RTTI was the obvious reading of that, and it is WRONG (2026-09-11) ──
#
#  Unit close is when RTTI tables are emitted, so phase 1 aimed there. On
#  SubpropertyEventFilter every single ablation still crashed:
#
#    no {$RTTI EXPLICIT}   CRASH      no [TProtoMember]/[TProtoHas]  CRASH
#    no {$M+}              CRASH      no [TGrpcMessage]              CRASH
#    published -> public   CRASH      no -O / -O1 / -O2              CRASH
#    ZERO property declarations                                      CRASH
#
#  So it is not RTTI, not the attributes, not published visibility, not the
#  optimiser. Seven hand-picked hypotheses have now died (four structural, in
#  the list above; three here). That is why phase 3 exists: every guess a human
#  made about this crash has been wrong, so the compiler gets to answer instead.
#
#  ── THREE outcomes, never two ──
#
#  The trap in any reducer is reading "no longer crashes" as progress when the
#  reduction merely produced invalid Pascal. A syntax error is not a fix; it is
#  a void experiment. So every variant is classified:
#
#    CRASH <code>   the internal error survived      -> the removed thing is innocent
#    CLEAN          compiled                          -> the removed thing is IMPLICATED
#    INVALID        some other compile error          -> tells us NOTHING, discard
#
#  A run that cannot produce CRASH on the unmodified baseline is void and exits
#  non-zero: if the control does not reproduce, nothing after it means anything.
#
#  USAGE
#    crash-reduce.sh <path-to-generated-unit.pas>
#
#    e.g. crash-reduce.sh .compile-out/g/4136/Corpus.S4136.Google.Analytics.\
#         Admin.V1alpha.SubpropertyEventFilter.Messages.pas
#
#  Start with the SMALLEST crashing unit. As of 2026-09-11 that is
#  SubpropertyEventFilter at 325 lines / 19 property declarations; the largest
#  is Compute at 175,613 lines / ~16,600, which is not where to begin.
#
#  Get the current list of crashing units straight from a run, never from this
#  comment:
#    grep -B1 "Internal error" .compile-out/crashes.txt | grep -oE "Corpus\.S[0-9]+\..*\.pas"
# =============================================================================
set -uo pipefail

UNIT="${1:-}"
[[ -n "$UNIT" && -f "$UNIT" ]] || { echo "usage: crash-reduce.sh <generated-unit.pas>"; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRUNK="${TRUNK_FPC:-/usr/local/fpc-trunk/bin/fpc}"
TU="${TRUNK_UNITS:-/usr/local/fpc-trunk/lib/fpc/3.3.1/units/x86_64-linux}"
SRC="$HERE/../../src"
[[ -x "$TRUNK" ]] || { echo "FAIL: FPC trunk not at $TRUNK (override with TRUNK_FPC)"; exit 2; }

UNIT="$(cd "$(dirname "$UNIT")" && pwd)/$(basename "$UNIT")"
GENDIR="$(dirname "$UNIT")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BASENAME="$(basename "$UNIT")"

# FPC REQUIRES THE FILENAME TO MATCH THE UNIT NAME. A variant written to some
# scratch name dies on "Illegal unit name" at line 1 col 81 before the compiler
# ever looks at the code -- which is a VOID experiment, not a passing one. (The
# first version of this script did exactly that and produced six meaningless
# INVALIDs; the three-way classification is what caught it.)
#
# So every variant is staged into a full copy of the generated directory under
# its REAL name. Copying the whole dir also means -Fu never points at $GENDIR,
# so a stale .ppu from an earlier run cannot satisfy a dependency and mask the
# edit under test.
STAGE="$WORK/stage"
mkdir -p "$STAGE"
cp "$GENDIR"/*.pas "$STAGE"/ 2>/dev/null || true

# Exactly compile-check.sh's invocation, with one deliberate difference: the
# -O flag is a parameter, since optimisation level is itself a variable worth
# testing. Pass "" for no -O at all -- that is FPC's "no optimisation"; there
# is no -O0, and passing one is a flag error that reads as a compile failure.
compile() {                       # <source.pas> [opt-flag] -> prints verdict
  local src="$1" log="$WORK/build.log" out="$WORK/u"
  local opt; if [[ $# -ge 2 ]]; then opt="$2"; else opt="-O1"; fi
  rm -rf "$out"; mkdir -p "$out"
  if "$TRUNK" -MDelphi ${opt:+$opt} -FU"$out" -Fu"$STAGE" -Fu"$SRC" \
       -Fu"$TU/rtl" -Fu"$TU/rtl-objpas" -Fu"$TU/rtl-console" \
       -Fu"$TU/rtl-generics" -Fu"$TU/fcl-base" \
       "$src" > "$log" 2>&1; then
    echo "CLEAN"
  elif grep -qE "Internal error [0-9]+" "$log"; then
    echo "CRASH $(grep -oE 'Internal error [0-9]+' "$log" | head -1 | awk '{print $3}')"
  elif grep -qE "raised exception internally|List index exceeds bounds" "$log"; then
    echo "CRASH $(grep -oE 'List index exceeds bounds \([0-9]+\)|raised exception internally' "$log" | head -1)"
  else
    echo "INVALID $(grep -m1 -oE '[A-Za-z0-9_.]+\.pas\([0-9,]+\) (Error|Fatal):.*' "$log" | cut -c1-70)"
  fi
}

say() { printf '  %-34s %s\n' "$1" "$2"; }

echo "unit:  $(basename "$UNIT")"
echo "lines: $(wc -l < "$UNIT")   property declarations: $(grep -c "^\\s*property " "$UNIT")"
echo ""

# ── Phase 0 · the control ────────────────────────────────────────────────────
echo "-- phase 0: baseline (must reproduce, or everything below is void) ------"
BASE=$(compile "$UNIT")
say "unmodified, -O1" "$BASE"
if [[ "$BASE" != CRASH* ]]; then
  echo ""
  echo "VOID: the baseline did not crash. Nothing below would mean anything."
  echo "      Check this really is one of the crashing units, and that TRUNK_FPC"
  echo "      is the same compiler compile-check.sh used."
  exit 1
fi
CODE="${BASE#CRASH }"
echo ""

# ── Phase 1 · ablations ──────────────────────────────────────────────────────
# Each keeps the unit valid Pascal, so a CLEAN result implicates the thing
# removed rather than reflecting a broken edit. Aimed at unit close / RTTI,
# which is where the crash is reported.
echo "-- phase 1: ablations (CLEAN here = that construct is implicated) -------"

# V is the staged file under test -- the unit's REAL name, so FPC accepts it.
V="$STAGE/$BASENAME"
v() { cp "$UNIT" "$V"; }
restore() { cp "$UNIT" "$V"; }

v; sed -i -E '/\{\$RTTI EXPLICIT/d'                 "$V"; say "no {\$RTTI EXPLICIT}"   "$(compile "$V")"
v; sed -i -E '/^\{\$M\+\}/d'                        "$V"; say "no {\$M+}"              "$(compile "$V")"
v; sed -i -E 's/^([[:space:]]*)published$/\1public/' "$V"; say "published -> public"   "$(compile "$V")"
v; sed -i -E '/^[[:space:]]*\[TProto(Member|Has)\([0-9]+\)\][[:space:]]*$/d' "$V"
   say "no [TProtoMember]/[TProtoHas]" "$(compile "$V")"
v; sed -i -E '/^[[:space:]]*\[TGrpcMessage\][[:space:]]*$/d' "$V"; say "no [TGrpcMessage]" "$(compile "$V")"
restore
say "no -O flag (source unchanged)" "$(compile "$V" "")"
say "-O2 (source unchanged)"        "$(compile "$V" -O2)"
echo ""

# ── Phase 2 · bisect the published-property count ────────────────────────────
# Deleting a published property is dependency-SAFE: the backing field and any
# setter stay, so nothing else loses a referent -- only the RTTI table shrinks.
# That is why this axis and not "delete classes", which breaks every referrer
# and would drown the search in INVALID.
#
# Finds the smallest K where keeping the first K published properties still
# crashes. K is then the boundary to inspect by hand.
echo "-- phase 2: bisect property-declaration count ----------------------------"
TOTP=$(grep -c '^\s*property ' "$UNIT")

keep() {                          # keep first $1 published properties
  awk -v k="$1" '
    /^[[:space:]]*\[TProto(Member|Has)\(/ { pend=$0; next }
    /^[[:space:]]*property / {
      n++
      if (n <= k) { if (pend != "") print pend; print }
      pend=""; next
    }
    { if (pend != "") { print pend; pend="" } print }
  ' "$UNIT" > "$V"
}

keep 0; Z=$(compile "$V"); say "keep 0 property declarations" "$Z"
if [[ "$Z" == CRASH* ]]; then
  echo ""
  echo "  Crashes with ZERO published properties: the trigger is NOT the RTTI"
  echo "  property table. Look at the type section itself -- enum count, class"
  echo "  count, or a specific type -- and re-read phase 1 for what came back CLEAN."
elif [[ "$Z" == INVALID* ]]; then
  echo ""
  echo "  Reducer produced invalid Pascal at k=0, so this axis is unusable here."
  echo "  Phase 1 is still valid; phase 2 is not."
else
  lo=0; hi=$TOTP                  # lo CLEAN, hi CRASH
  while (( hi - lo > 1 )); do
    mid=$(( (lo + hi) / 2 )); keep "$mid"; R=$(compile "$V")
    printf '  keep %-29s %s\n' "$mid properties" "$R"
    case "$R" in
      CRASH*)   hi=$mid ;;
      CLEAN)    lo=$mid ;;
      INVALID*) echo "  (invalid reduction at $mid - bisection cannot continue cleanly)"; break ;;
    esac
  done
  echo ""
  echo "  BOUNDARY: $lo properties compiles, $hi crashes."
  echo "  The property at index $hi is the one to read:"
  grep -n '^\s*property ' "$UNIT" | sed -n "${hi}p" | sed 's/^/    /'
fi

echo ""

# ── Phase 3 · delta debugging (ddmin) ────────────────────────────────────────
# Phases 1-2 test hypotheses a human picked. On this unit all of them came back
# CRASH, i.e. every guess was wrong -- so stop guessing and let the compiler
# minimise the file.
#
# Greedy line-chunk removal: try deleting a chunk; KEEP the deletion only if the
# result still CRASHes with the same code. CLEAN or INVALID both mean "put it
# back". That rejection rule is what makes this safe on Pascal without the
# script understanding Pascal at all -- a cut that breaks a dependency compiles
# with an error, scores INVALID, and is discarded. No grammar needed.
#
# Chunk sizes halve, so it converges on a locally minimal file that still
# crashes. THAT file is the deliverable: it is what an upstream FPC report needs
# and what tells us whether we can emit the construct differently.
if [[ "${SKIP_DDMIN:-}" == "1" ]]; then
  echo "-- phase 3: skipped (SKIP_DDMIN=1) -------------------------------------"
else
echo "-- phase 3: delta-debug to a minimal crashing unit ----------------------"
cp "$UNIT" "$V"
CUR="$WORK/cur.pas"; cp "$UNIT" "$CUR"
N0=$(wc -l < "$CUR")
CHUNK=$(( (N0 + 15) / 16 )); (( CHUNK < 1 )) && CHUNK=1
TRIES=0

while (( CHUNK >= 1 )); do
  progressed=1
  while (( progressed )); do
    progressed=0
    total=$(wc -l < "$CUR")
    start=1
    while (( start <= total )); do
      end=$(( start + CHUNK - 1 ))
      sed "${start},${end}d" "$CUR" > "$V"
      TRIES=$(( TRIES + 1 ))
      R=$(compile "$V")
      if [[ "$R" == "CRASH $CODE" ]]; then
        cp "$V" "$CUR"                 # deletion kept
        total=$(wc -l < "$CUR")
        progressed=1
        printf '\r  chunk=%-4s lines=%-6s tries=%-5s ' "$CHUNK" "$total" "$TRIES"
      else
        start=$(( start + CHUNK ))     # deletion rejected, move on
      fi
    done
  done
  (( CHUNK == 1 )) && break
  CHUNK=$(( CHUNK / 2 ))
done
printf '\r%*s\r' 60 ''

MIN="$GENDIR/minimal-crash-$CODE.pas"
cp "$CUR" "$MIN" 2>/dev/null || MIN="$WORK/minimal.pas"
echo "  reduced $N0 -> $(wc -l < "$CUR") lines in $TRIES compiles"
echo "  minimal crashing unit written to:"
echo "    $MIN"
echo ""
echo "  --- it is this that still crashes ---"
sed 's/^/    /' "$CUR" | head -60
[[ $(wc -l < "$CUR") -gt 60 ]] && echo "    ... $(( $(wc -l < "$CUR") - 60 )) more lines"
fi

echo ""
echo "crash code under test: $CODE"
echo "Reminder: an Internal error is an FPC bug by definition. The outcome here"
echo "is either a construct we can emit differently, or an upstream report --"
echo "not a defect in the generated Pascal."
