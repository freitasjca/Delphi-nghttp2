#!/usr/bin/env bash
# =============================================================================
#  protoc-oracle.sh — differential test: our parser vs protoc.
#
#  C1b of plans/horse-grpc-codegen.md.
#
#  ── Why an oracle at all ──
#
#  Every rule in Protogen.Parser was hand-derived from the proto3 spec: field
#  number ranges, first-enum-value-must-be-zero, duplicate numbers, the
#  19000-19999 reserve. Nothing has ever checked those against the reference
#  implementation. This asks protoc the same yes/no question and diffs.
#
#  ── The four cells, and only one of them is a bug ──
#
#    protoc ACCEPT + us ACCEPT   fine
#    protoc ACCEPT + us REFUSE   a DOCUMENTED GAP - valid proto3 we choose not
#                                to emit (map, oneof, sint32...). Must be
#                                declared by the case, or it is an accidental
#                                refusal wearing a deliberate one's clothes.
#    protoc REJECT + us REFUSE   fine - both saw an invalid schema
#    protoc REJECT + us ACCEPT   **BUG**. We would generate Pascal from a
#                                schema protoc will not compile, so our output
#                                could never interoperate. Nothing else in the
#                                suite can catch this.
#
#  The declared expectation is what separates cell 2 from an unnoticed defect.
#  Each case states its own, next to the source, rather than in a list that
#  drifts.
#
#  ── Deliberately generates its corpus ──
#
#  The .proto cases are heredocs below, not files in the repo. One file to
#  read, expectations adjacent to the schema they describe, and no chance of a
#  stale corpus file quietly not matching what its name claims. The repo's two
#  REAL .proto files are picked up from disk as well - those are the cases that
#  must never regress.
#
#  ── Requirements ──
#
#    protoc, or python3 with grpcio-tools (python -m grpc_tools.protoc)
#    ProtogenCheck built (this script builds it if FPC is available)
#
#  Env:
#    PROTOC        explicit protoc binary
#    ORACLE_PYTHON interpreter carrying grpc_tools (default: ./.venv/bin/python
#                  if present, else python3) - same convention as WS_PYTHON in
#                  build-fpc.sh
#    TRUNK_FPC     fpc binary (default /usr/local/fpc-trunk/bin/fpc)
#    TRUNK_UNITS   its unit tree
#
#  ── Two modes ──
#
#    bash protoc-oracle.sh                  built-in corpus (C1b, gates)
#    bash protoc-oracle.sh --corpus <dir>   an outside corpus (C1c, surveys)
#
#  Corpus mode exists to answer the question decision 6.1 ASSUMED the answer
#  to: does "reject loudly" leave a usable tool? The built-in corpus cannot
#  answer it, because it was built around the refusals — 8 gaps out of 17 says
#  nothing about real schemas. Point this at protos someone else wrote.
#
#  It reports rather than gates: a foreign schema carries no declared
#  expectation, so only a BUG (protoc REJECT + us ACCEPT) or a CRASH fails the
#  run. The deliverable is the GAP TALLY BY CAUSE at the end — "which feature
#  turned schemas away" is actionable in a way that "how many" is not.
#
#  Good first corpus, already on disk after `pip install grpcio-tools`:
#    <venv>/lib/python*/site-packages/grpc_tools/_proto
#  That ships google/protobuf/*.proto — the well-known types, written by the
#  protobuf authors — plus descriptor.proto. Real files, not toys.
#
#  Exit code: number of BUG cells plus setup failures. 0 = clean.
# =============================================================================

set -uo pipefail

CORPUS_DIR=""
if [[ "${1:-}" == "--corpus" ]]; then
  CORPUS_DIR="${2:-}"
  if [[ -z "$CORPUS_DIR" || ! -d "$CORPUS_DIR" ]]; then
    echo "FATAL: --corpus needs a directory. Got: ${2:-<nothing>}"
    exit 1
  fi
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/.oracle-out"
CORPUS="$WORK/corpus"

TRUNK=${TRUNK_FPC:-/usr/local/fpc-trunk/bin/fpc}
TU=${TRUNK_UNITS:-/usr/local/fpc-trunk/lib/fpc/3.3.1/units/x86_64-linux}

FAILED=0
BUGS=0
UNDECLARED=0

rm -rf "$WORK"
mkdir -p "$CORPUS"

# ── Locate protoc ────────────────────────────────────────────────────────────
# grpc_tools bundles its own protoc, so a pip install is enough and no system
# package is needed. Preferred over a system protoc precisely because it pins a
# known version rather than whatever the distro ships.
PROTOC_CMD=""
if [[ -n "${PROTOC:-}" ]]; then
  PROTOC_CMD="$PROTOC"
elif command -v protoc > /dev/null 2>&1; then
  PROTOC_CMD="protoc"
else
  ORACLE_PY=${ORACLE_PYTHON:-}
  if [[ -z "$ORACLE_PY" ]]; then
    if [[ -x "$HERE/.venv/bin/python" ]]; then ORACLE_PY="$HERE/.venv/bin/python"
    else ORACLE_PY="python3"; fi
  fi
  if "$ORACLE_PY" -c 'import grpc_tools.protoc' > /dev/null 2>&1; then
    PROTOC_CMD="$ORACLE_PY -m grpc_tools.protoc"
  fi
fi

if [[ -z "$PROTOC_CMD" ]]; then
  echo "FATAL: no protoc available."
  echo "       Install one of:"
  echo "         pip install grpcio-tools     (bundles protoc, no root needed)"
  echo "         apt install protobuf-compiler"
  echo "       or set PROTOC=/path/to/protoc"
  echo
  echo "  This script FAILS rather than skipping. A silent skip would report"
  echo "  green for a differential test that never ran - the same failure mode"
  echo "  build-fpc.sh stage 12 exists to avoid."
  exit 1
fi

# ── Build ProtogenCheck ──────────────────────────────────────────────────────
CHECK="$WORK/ProtogenCheck"
if [[ ! -x "$TRUNK" ]]; then
  echo "FATAL: no FPC trunk at $TRUNK - cannot build ProtogenCheck."
  exit 1
fi

mkdir -p "$WORK/units"
if ! "$TRUNK" -MDelphi -O1 -FU"$WORK/units" -FE"$WORK" -Fu"$HERE" \
      -Fu"$TU/rtl" -Fu"$TU/rtl-objpas" -Fu"$TU/rtl-generics" -Fu"$TU/fcl-base" \
      "$HERE/ProtogenCheck.dpr" > "$WORK/build.log" 2>&1 \
   || [[ ! -x "$CHECK" ]]; then
  echo "FATAL: ProtogenCheck did not compile"
  grep -E "Error|Fatal" "$WORK/build.log" | head -12 | sed 's/^/  /'
  echo "  full log: $WORK/build.log"
  exit 1
fi

echo "protoc: $PROTOC_CMD"
echo "parser: $CHECK"
echo

# ── Corpus ───────────────────────────────────────────────────────────────────
# add_case <name> <expect: accept|refuse> <note>   with the schema on stdin.
# `expect` is OUR verdict. protoc's is discovered, never declared - declaring
# it would just encode today's protoc behaviour as an assumption.

add_case() {
  local name="$1" expect="$2" note="$3"
  cat > "$CORPUS/$name.proto"
  echo "$expect" > "$CORPUS/$name.expect"
  echo "$note"   > "$CORPUS/$name.note"
}

HDR='syntax = "proto3";
package t;
'

add_case minimal accept "baseline - must always pass" <<EOF
$HDR
message M { int32 a = 1; }
EOF

add_case unsigned accept "uint32/uint64 supported since FIX-PROTO-UINT32-1" <<EOF
$HDR
message M { uint32 a = 1; uint64 b = 2; }
EOF

add_case repeated_enum accept "repeated + enum + bytes + message ref" <<EOF
$HDR
enum Status { STATUS_NONE = 0; STATUS_OK = 1; }
message Inner { string s = 1; }
message M {
  repeated int32 ids = 1;
  bytes blob = 2;
  Status st = 3;
  repeated Inner children = 4;
}
EOF

# --- valid proto3 that we deliberately refuse (expect cell 2) ---------------
add_case sint32   refuse "Group B - zigzag not selectable via TProtoMember" <<EOF
$HDR
message M { sint32 v = 1; }
EOF

add_case fixed32  refuse "Group B - fixed width not selectable" <<EOF
$HDR
message M { fixed32 v = 1; }
EOF

add_case map      refuse "Group C - needs a synthesised entry message" <<EOF
$HDR
message M { map<string, int32> m = 1; }
EOF

add_case oneof    refuse "Group C - no presence model" <<EOF
$HDR
message M { oneof pick { int32 a = 1; string b = 2; } }
EOF

add_case optional refuse "Group C - no has-bit; defaults are still emitted" <<EOF
$HDR
message M { optional int32 v = 1; }
EOF

add_case nested   refuse "deferred - Pascal has no nested class scope" <<EOF
$HDR
message M { message Inner { int32 a = 1; } Inner i = 1; }
EOF

add_case wellknown refuse "well-known types are not bundled" <<EOF
$HDR
import "google/protobuf/timestamp.proto";
message M { google.protobuf.Timestamp t = 1; }
EOF

add_case proto2_syntax refuse "proto2 - valid to protoc, out of scope for us" <<EOF
syntax = "proto2";
package t;
message M { optional int32 v = 1; }
EOF

# --- invalid proto3: protoc should reject, and so must we (cell 3) ----------
add_case dup_number refuse "duplicate field number - invalid schema" <<EOF
$HDR
message M { int32 a = 1; int32 b = 1; }
EOF

add_case zero_number refuse "field number 0 - invalid schema" <<EOF
$HDR
message M { int32 a = 0; }
EOF

add_case reserved_range refuse "19000-19999 is protobuf's own reserve" <<EOF
$HDR
message M { int32 a = 19500; }
EOF

add_case enum_nonzero refuse "proto3 needs first enum value = 0" <<EOF
$HDR
enum E { E_ONE = 1; }
EOF

# --- the repo's real files: these must never regress ------------------------
for real in \
  "$HERE/../../samples/grpc-server/echo.proto" \
  "$HERE/../../../horse-provider-nghttp2/samples/grpc/greeter.proto"
do
  if [[ -f "$real" ]]; then
    base="real_$(basename "$real" .proto)"
    cp "$real" "$CORPUS/$base.proto"
    echo accept > "$CORPUS/$base.expect"
    echo "the repo's own schema - must never regress" > "$CORPUS/$base.note"
  fi
done

# ── Corpus mode (C1c) ────────────────────────────────────────────────────────
# Surveys someone else's schemas. Reports; gates only on BUG and CRASH, since a
# foreign file carries no declared expectation.
if [[ -n "$CORPUS_DIR" ]]; then
  echo "corpus: $CORPUS_DIR"
  echo

  mapfile -t FILES < <(find "$CORPUS_DIR" -name '*.proto' -type f | sort)
  if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "FATAL: no .proto files under $CORPUS_DIR"
    exit 1
  fi

  N_OK=0; N_GAP=0; N_BUG=0; N_CRASH=0; N_BOTHREJ=0
  TALLY="$WORK/tally.txt"; : > "$TALLY"

  printf "%-44s %-8s %-8s %-6s %s\n" FILE PROTOC OURS CELL "REFUSED BECAUSE"
  printf "%-44s %-8s %-8s %-6s %s\n" \
    "--------------------------------------------" "--------" "--------" "------" "---------------"

  for f in "${FILES[@]}"; do
    rel="${f#$CORPUS_DIR/}"
    [[ ${#rel} -gt 44 ]] && rel="...${rel: -41}"

    # -I both the corpus root and the file's own directory, so intra-corpus
    # imports resolve. protoc supplies the well-known types itself.
    if $PROTOC_CMD -I "$CORPUS_DIR" -I "$(dirname "$f")" -o /dev/null "$f" \
         > "$WORK/c.protoc.log" 2>&1; then pv=ACCEPT; else pv=REJECT; fi

    "$CHECK" "$f" > "$WORK/c.ours.log" 2>&1
    case $? in 0) ov=ACCEPT ;; 1) ov=REFUSE ;; *) ov=ERROR ;; esac

    why=""
    if [[ "$ov" == "REFUSE" ]]; then
      why=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$WORK/c.ours.log" | head -1)
      [[ -z "$why" ]] && why="(unlabelled)"
    fi

    if   [[ "$ov" == "ERROR"  ]]; then cell=CRASH; N_CRASH=$((N_CRASH+1))
    elif [[ "$pv" == "REJECT" && "$ov" == "ACCEPT" ]]; then cell=BUG; N_BUG=$((N_BUG+1))
    elif [[ "$pv" == "REJECT" ]]; then cell=both; N_BOTHREJ=$((N_BOTHREJ+1))
    elif [[ "$ov" == "REFUSE" ]]; then cell=gap;  N_GAP=$((N_GAP+1)); echo "$why" >> "$TALLY"
    else cell=ok; N_OK=$((N_OK+1)); fi

    printf "%-44s %-8s %-8s %-6s %s\n" "$rel" "$pv" "$ov" "$cell" "$why"
    if [[ "$cell" == "BUG" || "$cell" == "CRASH" ]]; then
      sed 's/^/      /' "$WORK/c.ours.log" | head -3
    fi
  done

  TOTAL=${#FILES[@]}
  echo
  echo "=============================================================="
  printf "  %d files:  %d accepted  ·  %d gap  ·  %d both-reject  ·  %d BUG  ·  %d CRASH\n" \
    "$TOTAL" "$N_OK" "$N_GAP" "$N_BOTHREJ" "$N_BUG" "$N_CRASH"
  echo "=============================================================="

  if [[ $N_GAP -gt 0 ]]; then
    echo
    echo "  Gaps by cause — THIS is the C1c deliverable:"
    echo
    sort "$TALLY" | uniq -c | sort -rn | while read -r n cause; do
      pct=$(( n * 100 / TOTAL ))
      printf "    %4d  (%2d%% of corpus)  %s\n" "$n" "$pct" "$cause"
    done
    echo
    echo "  Read it against plan section 6.1. A cause near the top that is NOT"
    echo "  structural — nested declarations especially, which the codec could"
    echo "  already handle if the generator had a flattening rule — argues for"
    echo "  supporting it before C2 rather than after."
  fi

  echo
  if [[ $((N_BUG + N_CRASH)) -eq 0 ]]; then
    echo "  No BUG and no CRASH: every schema protoc rejected, we refused too."
    exit 0
  fi
  echo "  $((N_BUG + N_CRASH)) case(s) need attention — see above."
  exit $((N_BUG + N_CRASH))
fi

# ── Run ──────────────────────────────────────────────────────────────────────
printf "%-20s %-10s %-10s %-10s %s\n" CASE PROTOC OURS CELL NOTE
printf "%-20s %-10s %-10s %-10s %s\n" -------------------- ---------- ---------- ---------- ----

for f in "$CORPUS"/*.proto; do
  name=$(basename "$f" .proto)
  expect=$(cat "$CORPUS/$name.expect")
  note=$(cat "$CORPUS/$name.note")

  # protoc verdict. -o /dev/null asks for a descriptor set we discard: we want
  # the exit code, not the output. -I is the corpus dir so imports of
  # well-known types resolve through protoc's own bundled copies.
  if $PROTOC_CMD -I "$CORPUS" -o /dev/null "$f" > "$WORK/$name.protoc.log" 2>&1; then
    pv=ACCEPT
  else
    pv=REJECT
  fi

  "$CHECK" "$f" > "$WORK/$name.ours.log" 2>&1
  rc=$?
  case $rc in
    0) ov=ACCEPT ;;
    1) ov=REFUSE ;;
    *) ov=ERROR  ;;
  esac

  cell=""; bad=0
  if [[ "$ov" == "ERROR" ]]; then
    cell="CRASH"; bad=1
  elif [[ "$pv" == "REJECT" && "$ov" == "ACCEPT" ]]; then
    cell="BUG"; bad=1          # the only genuinely wrong cell
  elif [[ "$pv" == "ACCEPT" && "$ov" == "REFUSE" ]]; then
    cell="gap"
  else
    cell="ok"
  fi

  # Our own verdict must match what the case declared, whatever protoc said.
  # This is what stops an accidental refusal of valid proto3 hiding among the
  # deliberate ones.
  want_ov=ACCEPT
  [[ "$expect" == "refuse" ]] && want_ov=REFUSE
  if [[ "$ov" != "$want_ov" ]]; then
    cell="UNDECLARED"; bad=1
    UNDECLARED=$((UNDECLARED + 1))
  fi

  printf "%-20s %-10s %-10s %-10s %s\n" "$name" "$pv" "$ov" "$cell" "$note"

  if [[ $bad -eq 1 ]]; then
    FAILED=$((FAILED + 1))
    [[ "$cell" == "BUG" ]] && BUGS=$((BUGS + 1))
    sed 's/^/      protoc: /' "$WORK/$name.protoc.log" | head -3
    sed 's/^/      ours:   /' "$WORK/$name.ours.log"   | head -3
  fi
done

echo
echo "=============================================================="
if [[ $FAILED -eq 0 ]]; then
  echo "  ORACLE CLEAN - no disagreement protoc would call a defect"
  echo
  echo "  'gap' rows are valid proto3 we deliberately refuse. They are the"
  echo "  point of decision 6.1, not a problem - but the count is worth"
  echo "  watching: it is the fraction of real schemas we would turn away."
  exit 0
fi

echo "  $FAILED case(s) need attention"
[[ $BUGS -gt 0 ]] && \
  echo "    $BUGS BUG - we ACCEPT a schema protoc REJECTS. Generated code" && \
  echo "               could never interoperate. Fix before C2."
[[ $UNDECLARED -gt 0 ]] && \
  echo "    $UNDECLARED UNDECLARED - our verdict differs from the case's own" && \
  echo "               expectation. Either the parser regressed or the" && \
  echo "               expectation is stale; do not just update the expectation."
echo "=============================================================="
exit $FAILED
