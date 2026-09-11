#!/usr/bin/env bash
# =============================================================================
#  crash-namelen.sh — is `Internal error 2015071503` a NAME-LENGTH crash?
#
#  ── Why this test, after seven wrong guesses ──
#
#  crash-reduce.sh reduced the smallest crasher to 119 lines with NO fields, NO
#  properties, NO attributes, and every method body empty. Nothing about the
#  remaining code is semantically interesting, which kills the last structural
#  theory: whatever FPC chokes on, it is not what the code DOES.
#
#  What remains in the file is NAMES. And the mangled symbol FPC builds for one
#  of those empty methods concatenates unit + class + method + parameter types:
#
#    CORPUS_S4136_GOOGLE_ANALYTICS_ADMIN_V1ALPHA_SUBPROPERTYEVENTFILTER_MESSAGES
#      $_$TSUBPROPERTYEVENTFILTEREXPRESSION_$__$$_SETNOT_EXPRESSION
#      $TSUBPROPERTYEVENTFILTEREXPRESSIONLIST
#
#  ~200 characters. FIX-IDENT-1 already established that FPC dies on long
#  generated identifiers AND that the crash DEPENDS ON --unit-prefix, which is
#  precisely a statement about mangled length.
#
#  I previously called this theory disproved by measuring SOURCE identifiers
#  (longest 75) against a 127 limit. That measurement was of the wrong string:
#  the limit applies to the mangled symbol, which no one had measured. Recording
#  it because "disproved" was wrong, not merely unproven.
#
#  It also fits the one crasher that looked like a counterexample: Compute has a
#  SHORT unit name (Google.Cloud.Compute.V1.Compute) but enormous class names,
#  so its mangled symbols are long by the other term of the sum.
#
#  ── The experiment ──
#
#  Rename the unit to progressively shorter prefixes and recompile. Nothing else
#  changes -- same declarations, same bodies. If the crash tracks name length
#  there will be a THRESHOLD, and the fix is ours: MAX_IDENT must bound the
#  mangled length (unit + class + method + params), not just an identifier.
#
#  If every length crashes, length is exonerated for real this time and the
#  remaining suspects are the sparse enum (EXCLUDE = 2) and the forward-declared
#  class -- both still present in the minimal file.
#
#  USAGE
#    crash-namelen.sh <minimal-crash-NNNN.pas>
# =============================================================================
set -uo pipefail

SRCFILE="${1:-}"
[[ -n "$SRCFILE" && -f "$SRCFILE" ]] || { echo "usage: crash-namelen.sh <minimal-crash-*.pas>"; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRUNK="${TRUNK_FPC:-/usr/local/fpc-trunk/bin/fpc}"
TU="${TRUNK_UNITS:-/usr/local/fpc-trunk/lib/fpc/3.3.1/units/x86_64-linux}"
LIBSRC="$HERE/../../src"
[[ -x "$TRUNK" ]] || { echo "FAIL: FPC trunk not at $TRUNK"; exit 2; }

SRCFILE="$(cd "$(dirname "$SRCFILE")" && pwd)/$(basename "$SRCFILE")"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

ORIG=$(sed -n '1s/^unit \(.*\);$/\1/p' "$SRCFILE")
[[ -n "$ORIG" ]] || { echo "FAIL: no 'unit X;' on line 1 of $SRCFILE"; exit 2; }

# The longest mangled symbol FPC must build, approximated the way FPC does it:
# UNIT $_$ CLASS _$__$$_ METHOD $ PARAMTYPES, uppercased, dots -> underscores.
# Approximate on purpose -- the point is the ORDER OF MAGNITUDE and how it moves
# with the unit name, not an exact byte count.
longest_mangled() {
  local unit="$1" u; u=${unit//./_}
  awk -v U="$u" '
    /^  T[A-Za-z0-9_]+ = class$/ { cls=substr($1,1); next }
    /^  end;$/ { cls=""; next }
    cls != "" && /^ *(procedure|function|destructor) / {
      line=$0
      gsub(/^ +/,"",line); gsub(/;.*$/,"",line)
      n=length(U) + 3 + length(cls) + 8 + length(line)
      if (n > max) { max=n }
    }
    END { print max+0 }' "$SRCFILE"
}

compile_as() {                    # <unit-name> -> verdict
  # One `local` per variable. `local a="$1" b="${a}x"` does NOT reliably see a
  # when expanding b, and under `set -u` it aborts the whole function with
  # "unbound variable" -- which printed an empty verdict column for every row
  # while the script otherwise looked like it ran.
  local unit="$1"
  local f="$WORK/${unit}.pas"
  local log="$WORK/b.log"
  local out="$WORK/u"
  rm -rf "$out" "$WORK"/*.pas; mkdir -p "$out"
  sed "1s/^unit .*;$/unit ${unit};/" "$SRCFILE" > "$f"
  if "$TRUNK" -MDelphi -O1 -FU"$out" -Fu"$WORK" -Fu"$LIBSRC" \
       -Fu"$TU/rtl" -Fu"$TU/rtl-objpas" -Fu"$TU/rtl-console" \
       -Fu"$TU/rtl-generics" -Fu"$TU/fcl-base" \
       "$f" > "$log" 2>&1; then
    echo "CLEAN"
  elif grep -qE "Internal error [0-9]+" "$log"; then
    echo "CRASH $(grep -oE 'Internal error [0-9]+' "$log" | head -1 | awk '{print $3}')"
  elif grep -qE "raised exception internally|List index exceeds bounds" "$log"; then
    echo "CRASH other-internal"
  else
    echo "INVALID $(grep -m1 -oE '\([0-9,]+\) (Error|Fatal):.*' "$log" | cut -c1-52)"
  fi
}

echo "source: $(basename "$SRCFILE")   original unit name: ${#ORIG} chars"
echo ""
printf '  %-5s %-9s %-22s %s\n' UNITL MANGLED UNIT-NAME VERDICT
printf '  %s\n' "------------------------------------------------------------------"

# Progressively shorter unit names. Same file otherwise.
for u in "$ORIG" \
         "Corpus.Google.Analytics.Admin.V1alpha.SubpropertyEventFilter.Messages" \
         "Corpus.Analytics.SubpropertyEventFilter.Messages" \
         "Corpus.Sub.Messages" \
         "Corpus.Msg" \
         "M"; do
  printf '  %-5s %-9s %-22s %s\n' "${#u}" "$(longest_mangled "$u")" "$(echo "$u" | cut -c1-22)" "$(compile_as "$u")"
done

# ── The floor case ───────────────────────────────────────────────────────────
# Shortening the UNIT alone bottoms out around ~130 mangled chars, because the
# CLASS names in this unit are themselves 30-40 chars. 130 is still above the
# 127 that FIX-IDENT-1 is written around -- so "every row above crashed" would
# NOT exonerate length; the sweep would simply never have gone below the
# threshold. That is the wrong-in-the-passing-direction error this project keeps
# paying for, so here is a variant that drives the mangled length clearly under
# it by shrinking every generated identifier as well.
echo ""
echo "-- floor case: short unit AND short type/method names -------------------"
short() {
  sed -e '1s/^unit .*;$/unit M;/' \
      -e 's/TSubpropertyEventFilterConditionStringFilter/TA/g' \
      -e 's/TSubpropertyEventFilterConditionOne_filterCase/TB/g' \
      -e 's/TSubpropertyEventFilterExpressionExprCase/TC/g' \
      -e 's/TSubpropertyEventFilterExpressionList/TD/g' \
      -e 's/TSubpropertyEventFilterExpression/TE/g' \
      -e 's/TSubpropertyEventFilterConditionStringFilterMatchType/TF/g' \
      -e 's/TSubpropertyEventFilterClauseFilterClauseType/TG/g' \
      -e 's/TSubpropertyEventFilterCondition/TH/g' \
      -e 's/TSubpropertyEventFilterClause/TI/g' \
      -e 's/TSubpropertyEventFilter/TJ/g' \
      -e 's/SubpropertyEventFilterConditionOne_filterCase/v/g' \
      -e 's/SubpropertyEventFilterExpressionExprCase/w/g' \
      "$SRCFILE" > "$WORK/M.pas"
}
rm -rf "$WORK"/*.pas; short
mkdir -p "$WORK/u2"
if "$TRUNK" -MDelphi -O1 -FU"$WORK/u2" -Fu"$WORK" -Fu"$LIBSRC" \
     -Fu"$TU/rtl" -Fu"$TU/rtl-objpas" -Fu"$TU/rtl-console" \
     -Fu"$TU/rtl-generics" -Fu"$TU/fcl-base" \
     "$WORK/M.pas" > "$WORK/b2.log" 2>&1; then
  echo "  all names short                                    CLEAN"
elif grep -qE "Internal error [0-9]+" "$WORK/b2.log"; then
  echo "  all names short                                    CRASH $(grep -oE 'Internal error [0-9]+' "$WORK/b2.log" | head -1 | awk '{print $3}')"
else
  echo "  all names short                                    INVALID $(grep -m1 -oE '\([0-9,]+\) (Error|Fatal):.*' "$WORK/b2.log" | cut -c1-50)"
fi

echo ""
echo "READ IT AS:"
echo "  a THRESHOLD (crash long, clean short) => name length is the cause, and"
echo "    the fix is OURS: MAX_IDENT must bound the MANGLED length"
echo "    (unit + class + method + params), not just a source identifier."
echo "  ALL rows CRASH *INCLUDING the floor case* => length really is exonerated."
echo "    Next suspects, both still in the minimal file: the sparse enum"
echo "    'EXCLUDE = 2' (single member, ordinal 2, no zero element) and the"
echo "    forward-declared class completed later in the same type section."
echo "  ALL rows CRASH but the floor case is INVALID => inconclusive, NOT a"
echo "    disproof: the sweep never got under the threshold."
echo "  ANY INVALID row is void -- a broken edit, not evidence."
