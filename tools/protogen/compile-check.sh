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
#  ── Every schema, since IMPORT-1 ──
#
#  This script used to compile only self-contained schemas - no imports, or
#  imports of bundled well-known types alone - because a generated unit
#  referencing another .proto's types named identifiers that no generated unit
#  declared. That was 3019 of 7301 googleapis files, 41%, and the excluded 59%
#  was not a sampling choice: it was the shape of a defect.
#
#  IMPORT-1 resolves imports and generates one unit per file in the closure, so
#  the whole corpus is now a candidate. The include root is the corpus root,
#  which is how googleapis paths ('google/rpc/status.proto') are meant to
#  resolve.
#
#  What is still excluded, and why it is a GAP rather than a defect:
#  a schema importing a file the corpus does not contain. protogen reports
#  that as a missing import - correctly - and it is counted separately from a
#  compile failure, because the tool never claimed to generate it.
#
#  ── Sampling ──
#
#  Compiling 3019 units takes minutes. The default is a SAMPLE, deterministic
#  (every Nth candidate, not random) so two runs of the same corpus compile the
#  same files and a new failure means a new defect rather than a new draw.
#  --all when you want the full sweep.
#
#  USAGE
#    compile-check.sh [--sample N | --all | --only FILE] [corpus-dir]
#
#  --only FILE re-runs just the schemas named in FILE, which may be a plain
#  list of .proto paths or crashes.txt / failures.txt copied verbatim -- any
#  .proto path in it is matched. A --all sweep is ~2h45m; the 50 crashing
#  schemas take about a minute, which is what makes iterating on them
#  practical.
#
#  It keeps each schema's ORIGINAL corpus index for --unit-prefix, so the
#  generated unit names are byte-identical to what the full sweep produced.
#  That is not tidiness: FIX-IDENT-1 is identifier-LENGTH dependent, and a
#  short-prefix spot-check once falsely disproved it. Renumbering a subset
#  would let a crash disappear because its unit got a shorter name -- the run
#  would be measuring the prefix instead of the schema.
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

ONLY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)    SAMPLE=0; shift ;;
    --sample) SAMPLE="${2:-300}"; shift 2 ;;
    --only)   ONLY="${2:-}"; shift 2 ;;
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
# Every .proto in the corpus. Before IMPORT-1 this list was filtered down to
# schemas with no cross-file references; that filter is gone, and the count it
# used to print (3019) is worth remembering as the size of the blind spot.
echo "collecting schemas..."
find "$CORPUS" -name '*.proto' | sort > "$OUT/candidates.txt"

TOTAL=$(wc -l < "$OUT/candidates.txt")

# selected.txt is "<corpus index><TAB><path>". The INDEX MUST be the line number
# in candidates.txt, never a position within the selection.
#
# It feeds --unit-prefix as Corpus.S<index>, so renumbering renames every
# generated unit and changes identifier LENGTHS. FIX-IDENT-1 is length-dependent
# and a short-prefix spot-check once falsely disproved it. A subset run that
# renumbered could therefore "fix" a crash by shortening its name -- the run
# would be measuring the prefix, not the schema.
#
# --sample used to renumber for exactly this reason, so a sample run and an
# --all run generated different unit names for the same schema. Now they agree.
if [[ -n "$ONLY" ]]; then
  # Re-run named schemas only. Matches full paths OR any unique suffix, so a
  # line copied straight out of crashes.txt works.
  [[ -r "$ONLY" ]] || { echo "FAIL: --only list not readable: $ONLY"; exit 2; }
  grep -oE '/[^[:space:]]+\.proto' "$ONLY" | sed 's|^|/|; s|^//|/|' | sort -u > "$OUT/only.keys"
  [[ -s "$OUT/only.keys" ]] || { echo "FAIL: no .proto paths found in $ONLY"; exit 2; }
  awk 'NR==FNR { want[$0]=1; next }
       { for (k in want) if (index($0, k) || index(k, $0)) { print FNR "\t" $0; next } }' \
      "$OUT/only.keys" "$OUT/candidates.txt" > "$OUT/selected.txt"
  WANTED=$(wc -l < "$OUT/only.keys"); GOT=$(wc -l < "$OUT/selected.txt")
  echo "  --only: $GOT of $WANTED requested schemas matched the corpus"
  # A silent shortfall would read as "those ones pass now".
  [[ "$GOT" -eq "$WANTED" ]] || echo "  WARNING: $(( WANTED - GOT )) requested schema(s) NOT FOUND - not the same as passing"
  [[ "$GOT" -gt 0 ]] || exit 2
elif [[ "$SAMPLE" -gt 0 && "$TOTAL" -gt "$SAMPLE" ]]; then
  # Every Nth, not random: two runs of one corpus must compile the SAME files,
  # so a new failure is a new defect rather than a new draw.
  STEP=$(( TOTAL / SAMPLE ))
  [[ $STEP -lt 1 ]] && STEP=1
  awk -v s="$STEP" 'NR % s == 1 { print NR "\t" $0 }' "$OUT/candidates.txt" > "$OUT/selected.txt"
else
  awk '{ print NR "\t" $0 }' "$OUT/candidates.txt" > "$OUT/selected.txt"
fi
PICKED=$(wc -l < "$OUT/selected.txt")

echo "candidates: $TOTAL schemas (every .proto in the corpus)"
echo "compiling:  $PICKED"
echo

# ── Progress ─────────────────────────────────────────────────────────────────
# --all is a ~1 hour run. Without this you cannot tell a slow sweep from a hung
# one, which is the only question you actually have while waiting.
#
# Written to STDERR, not stdout, so `| tail -25` still shows the report and
# nothing else. Redraws in place on a terminal; falls back to one line every
# 250 schemas when stderr is redirected, so a log file does not fill with
# carriage returns.
PROG_START=$(date +%s)

hms() {                       # seconds -> 1h02m03s / 2m03s / 43s
  local t=$1
  if   [[ $t -ge 3600 ]]; then printf '%dh%02dm%02ds' $((t/3600)) $((t%3600/60)) $((t%60))
  elif [[ $t -ge 60   ]]; then printf '%dm%02ds' $((t/60)) $((t%60))
  else                         printf '%ds' "$t"
  fi
}

progress() {                  # <done> <total>
  local done=$1 total=$2 now elapsed eta rate pct
  [[ $total -le 0 ]] && return 0
  now=$(date +%s); elapsed=$(( now - PROG_START ))
  pct=$(( done * 100 / total ))

  # ETA from the average so far. Honest for this workload: every schema is one
  # generate + one compile, so the per-item cost has no long tail to skew it.
  if [[ $done -gt 0 && $elapsed -gt 0 ]]; then
    eta=$(( elapsed * (total - done) / done ))
  else
    eta=0
  fi

  if [[ -t 2 ]]; then
    printf '\r  [%5d/%5d %3d%%]  ok %-5d crash %-4d defect %-4d refused %-5d  %s elapsed, ~%s left   ' \
      "$done" "$total" "$pct" "$OK" "$CRASH" "$COMPFAIL" "$GENFAIL" \
      "$(hms "$elapsed")" "$(hms "$eta")" >&2
  elif [[ $done -gt 0 && ( $(( done % 250 )) -eq 0 || $done -eq $total ) ]]; then
    printf '  [%5d/%5d %3d%%]  ok %d crash %d defect %d refused %d  %s elapsed, ~%s left\n' \
      "$done" "$total" "$pct" "$OK" "$CRASH" "$COMPFAIL" "$GENFAIL" \
      "$(hms "$elapsed")" "$(hms "$eta")" >&2
  fi
}

# ── Generate + compile ───────────────────────────────────────────────────────
# N is the CORPUS index (drives --unit-prefix); DONE counts this run's progress.
# They are equal only in an --all run; keeping them apart is what lets a subset
# run keep each schema's original unit name.
OK=0; GENFAIL=0; COMPFAIL=0; CRASH=0; N=0; DONE=0
: > "$OUT/failures.txt"
: > "$OUT/crashes.txt"

while IFS=$'\t' read -r N proto; do
  DONE=$(( DONE + 1 ))
  D="$OUT/g/$N"
  mkdir -p "$D"
  # The prefix is DELIBERATELY ONE CHARACTER. It used to be "Corpus.S<N>", and
  # that cost 12 characters of every generated unit name for no measurement
  # value -- the harness was testing itself.
  #
  # FPC crashes on a long MANGLED symbol (unit + class + method + parameter
  # types), and the generated unit name is prefix + path-derived segments, so
  # the prefix is a direct term in it. Measured 2026-09-11 on the smallest
  # crashing unit, changing nothing but the unit name:
  #
  #   75 chars -> Internal error 2015071503
  #   69 chars -> compiles clean
  #
  # A 6-character window, and "Corpus.S4136." was 13 of the 75. Re-running the
  # 50 crashing schemas with "C" instead: crashes 50 -> 7, COMPILED 0 -> 43.
  # 43 of the 50 were the HARNESS, never a defect a user could hit.
  #
  # Override to reproduce that comparison, or to test a long user prefix:
  #   PREFIX_BASE=Corpus.S bash compile-check.sh --only .compile-out/crashes.txt
  #
  # NOTE: corpus totals from before 2026-09-11 were measured with the long
  # prefix and are NOT comparable with figures from this script now. See
  # doc/releasing.md.
  PREFIX="${PREFIX_BASE:-C}$N"

  # -I the corpus root: googleapis import paths are corpus-relative
  # ('google/rpc/status.proto'), which is exactly what protoc expects too.
  if ! "$OUT/Protogen" -i "$proto" -I "$CORPUS" -o "$D" \
        --unit-prefix "$PREFIX" > "$D/gen.log" 2>&1; then
    # A refusal or an unresolvable import is corpus-check's business, not ours
    # - either way we never claimed to generate this one. Counted separately so
    # it cannot be mistaken for a compile failure.
    GENFAIL=$(( GENFAIL + 1 ))
    continue
  fi

  # Ask the tool which unit is the root rather than re-deriving the
  # path-to-unit-name rule here. A second implementation of that rule in shell
  # would agree with the Pascal one right up until it did not.
  ROOTUNIT=$(sed -n 's/^root-unit-file: //p' "$D/gen.log" | head -1)
  UNIT="$D/$ROOTUNIT"
  [[ -n "$ROOTUNIT" && -f "$UNIT" ]] || { GENFAIL=$(( GENFAIL + 1 )); continue; }

  if "$TRUNK" -MDelphi -O1 -FU"$D" -Fu"$SRC" \
       -Fu"$TU/rtl" -Fu"$TU/rtl-objpas" -Fu"$TU/rtl-console" \
       -Fu"$TU/rtl-generics" -Fu"$TU/fcl-base" \
       "$UNIT" > "$D/build.log" 2>&1; then
    OK=$(( OK + 1 ))
  else
    # A COMPILER CRASH is not a rejection of our output. FPC dies on some of
    # what we generate - "Internal error 2015071505", "Compilation raised
    # exception internally", "List index exceeds bounds" - and counting those
    # as emitter defects overstated the number by 3.5x on the first full sweep
    # (76 reported, 22 real). Long identifiers correlate with it; see MAX_IDENT
    # in Protogen.Emitter.pas, which exists because of this same FPC behaviour.
    if grep -qE "Internal error|raised exception internally|List index exceeds bounds" \
         "$D/build.log"; then
      CRASH=$(( CRASH + 1 ))
      { echo "=== [compiler crash] $proto"
        grep -E "Internal error|raised exception|List index" "$D/build.log" \
          | head -2 | sed 's/^/    /'
      } >> "$OUT/crashes.txt"
    else
      COMPFAIL=$(( COMPFAIL + 1 ))
      {
        echo "=== $proto"
        grep -E "Error|Fatal" "$D/build.log" | head -4 | sed 's/^/    /'
      } >> "$OUT/failures.txt"
    fi
  fi

  progress "$DONE" "$PICKED"
done < "$OUT/selected.txt"

# Close the in-place line so the report does not land on top of it.
[[ -t 2 ]] && printf '\r%*s\r' 110 '' >&2

# ── Report ───────────────────────────────────────────────────────────────────
echo "==========================================================="
printf "  attempted        %5d\n" "$PICKED"
printf "  COMPILED         %5d\n" "$OK"
printf "  refused / unresolved imports %5d   (not an emitter defect)\n" "$GENFAIL"
printf "  DID NOT COMPILE  %5d   <- emitter defects\n" "$COMPFAIL"
printf "  compiler crashed %5d   (FPC fell over; not our output being rejected)\n" "$CRASH"
echo "==========================================================="

# WHY the refused ones were refused. This bucket is where a systematic problem
# hides while the headline number reads clean: the first corpus run after
# IMPORT-1 reported "DID NOT COMPILE 0" over 305 schemas, of which 163 never
# reached a compiler at all - 162 of them refused for ONE cause. A count with
# no breakdown invites reading it as background noise.
if [[ $GENFAIL -gt 0 ]]; then
  echo
  echo "-- why generation stopped, by cause ----------------------"
  echo "   A large single cause here is a finding, not background."
  cat "$OUT"/g/*/gen.log 2>/dev/null \
    | grep -h "^error:" \
    | sed 's/[0-9][0-9]*/N/g; s/"[^"]*"/"X"/g' \
    | cut -c1-100 \
    | sort | uniq -c | sort -rn | head -8 | sed 's/^/  /'
fi

if [[ $CRASH -gt 0 ]]; then
  echo
  echo "-- FPC crashed on these ----------------------------------"
  echo "   Counted apart because the compiler DIED rather than"
  echo "   reporting our output invalid. Still worth reading: long"
  echo "   generated identifiers correlate with it, and IMPORT-1"
  echo "   made both unit names and qualified references longer."
  head -12 "$OUT/crashes.txt" | sed 's/^/  /'
  echo "   full list: $OUT/crashes.txt"
fi

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
