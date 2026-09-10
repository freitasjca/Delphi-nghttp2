#!/usr/bin/env bash
# =============================================================================
#  spot-check.sh — generate + compile a NAMED handful of corpus schemas.
#
#  compile-check.sh --all is a ~1 hour sweep. That is the right tool for
#  "did anything regress anywhere", and the wrong one for "did this fix move
#  these ten files", which is the question you have while iterating on a
#  defect you have already localised.
#
#  Same generate and compile invocations as compile-check.sh, deliberately:
#  a spot check that compiles differently from the sweep can disagree with it
#  and neither answer is trustworthy afterwards.
#
#  Usage:
#    bash spot-check.sh                 # the FIX-IDENT-1 cohort (default)
#    bash spot-check.sh a.proto b.proto # paths, absolute or corpus-relative
#
#  MEASURING A FIX WITH THIS: run it BOTH WAYS, today, on the same toolchain.
#
#    git stash push tools/protogen/Protogen.Emitter.pas
#    bash tools/protogen/spot-check.sh          # baseline
#    git stash pop
#    bash tools/protogen/spot-check.sh          # with the fix
#
#  Do NOT compare against an older .compile-out/crashes.txt. That file was
#  written by a different day's toolchain and source tree, and on 2026-09-10 a
#  comparison against one produced a clean 6/6 that meant nothing: two schemas
#  whose generated identifiers were byte-identical before and after (105 chars,
#  well under any truncation) moved from crash to ok anyway. A baseline you did
#  not just re-earn is not a baseline.
#
#  Exit: 0 nothing crashed · 1 at least one crashed · 2 setup problem
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORPUS="${CORPUS:-$HERE/.corpus/googleapis}"
OUT="$HERE/.spot-out"
TRUNK="${TRUNK_FPC:-/usr/local/fpc-trunk/bin/fpc}"
TU="${TRUNK_UNITS:-/usr/local/fpc-trunk/lib/fpc/3.3.1/units/x86_64-linux}"
SRC="$HERE/../../src"

# The schemas whose generated identifiers reached 127+ characters, which is
# where FPC stops diagnosing and starts dying with Internal error 2015071505.
# Measured 2026-09-10: 10 of 57 crashes were this shape, and all 10 were this
# error code. These are the ones FIX-IDENT-1 is supposed to move.
DEFAULT_SET=(
  google/ads/googleads/v22/resources/customer_sk_ad_network_conversion_value_schema.proto
  google/ads/googleads/v22/services/customer_sk_ad_network_conversion_value_schema_service.proto
  google/ads/googleads/v23/resources/customer_sk_ad_network_conversion_value_schema.proto
  google/ads/googleads/v23/services/customer_sk_ad_network_conversion_value_schema_service.proto
  # Controls: these crash too, but NOT with 2015071505 and NOT over 127
  # characters. They must be UNCHANGED by an identifier-length fix — if they
  # move, the fix is doing something other than what it claims.
  google/ads/datamanager/v1/ingestion_service.proto
  google/ads/datamanager/v1/request_status_per_destination.proto
)

[[ -d "$CORPUS" ]] || { echo "FAIL: corpus not at $CORPUS" >&2; exit 2; }
[[ -x "$TRUNK"  ]] || { echo "FAIL: fpc not at $TRUNK (set TRUNK_FPC)" >&2; exit 2; }

rm -rf "$OUT"; mkdir -p "$OUT/units"

echo "building Protogen from current source..."
if ! "$TRUNK" -MDelphi -O1 -Fu"$HERE" -FU"$OUT/units" -FE"$OUT" \
      -Fu"$TU/rtl" -Fu"$TU/rtl-objpas" -Fu"$TU/rtl-console" \
      -Fu"$TU/rtl-generics" -Fu"$TU/fcl-base" \
      "$HERE/Protogen.dpr" > "$OUT/protogen-build.log" 2>&1 \
   || [[ ! -x "$OUT/Protogen" ]]; then
  echo "FAIL: Protogen did not compile"
  grep -E "Error|Fatal" "$OUT/protogen-build.log" | head -12 | sed 's/^/  /'
  exit 2
fi

if [[ $# -gt 0 ]]; then SET=("$@"); else SET=("${DEFAULT_SET[@]}"); fi

CRASH=0; OK=0; DEFECT=0; GENFAIL=0; N=0
echo

for proto in "${SET[@]}"; do
  [[ "$proto" == \#* ]] && continue
  [[ "$proto" = /* ]] || proto="$CORPUS/$proto"
  N=$(( N + 1 ))
  D="$OUT/g/$N"; mkdir -p "$D"

  SHORT="${proto#"$CORPUS"/}"
  printf '  %-72s ' "${SHORT:0:72}"

  # The prefix matches compile-check.sh's `Corpus.S<n>` shape on purpose. It
  # lands in every generated unit name and every cross-file reference, so a
  # shorter one here would generate subtly different source from the sweep —
  # and identifier length is the variable under test.
  if ! "$OUT/Protogen" -i "$proto" -I "$CORPUS" -o "$D" \
        --unit-prefix "Corpus.S$N" > "$D/gen.log" 2>&1; then
    echo "REFUSED (generator)"; GENFAIL=$(( GENFAIL + 1 )); continue
  fi

  ROOTUNIT=$(sed -n 's/^root-unit-file: //p' "$D/gen.log" | head -1)
  UNIT="$D/$ROOTUNIT"
  [[ -n "$ROOTUNIT" && -f "$UNIT" ]] || { echo "REFUSED (no root unit)"; GENFAIL=$(( GENFAIL + 1 )); continue; }

  # The number this exists to report: the longest identifier we emitted.
  LONGEST=$(grep -ohE '[A-Za-z_][A-Za-z0-9_]*' "$D"/*.pas 2>/dev/null \
            | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }')

  if "$TRUNK" -MDelphi -O1 -FU"$D" -Fu"$SRC" \
       -Fu"$TU/rtl" -Fu"$TU/rtl-objpas" -Fu"$TU/rtl-console" \
       -Fu"$TU/rtl-generics" -Fu"$TU/fcl-base" \
       "$UNIT" > "$D/build.log" 2>&1; then
    echo "ok           (longest ident $LONGEST)"; OK=$(( OK + 1 ))
  elif grep -qE "Internal error|raised exception internally|List index exceeds bounds" "$D/build.log"; then
    SIG=$(grep -oE "Internal error [0-9]+|List index exceeds bounds" "$D/build.log" | head -1)
    echo "CRASH        (longest ident $LONGEST) $SIG"; CRASH=$(( CRASH + 1 ))
  else
    echo "did not compile (longest ident $LONGEST)"; DEFECT=$(( DEFECT + 1 ))
    grep -E "Error|Fatal" "$D/build.log" | head -2 | sed 's/^/      /'
  fi
done

echo
echo "==========================================================="
printf "  attempted %d   ok %d   CRASH %d   defect %d   refused %d\n" \
  "$N" "$OK" "$CRASH" "$DEFECT" "$GENFAIL"
echo "==========================================================="
echo "  units + logs: $OUT/g/<n>/"
echo
echo "  This is one arm of an A/B. It is meaningless alone — run it with and"
echo "  without the change, today, and compare THOSE two. The \`longest ident\`"
echo "  column is the discriminator: a schema truncation actually touched"
echo "  reports exactly 120, and one it did not reports whatever it always was."

[[ "$CRASH" -eq 0 ]] && exit 0 || exit 1
