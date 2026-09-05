#!/usr/bin/env bash
# =============================================================================
#  build-codec-fpc.sh
#  Compile + run the codec suites under FPC, then compile (not run) the
#  standalone samples/grpc-server. Everything here needs trunk for the same
#  reason and the same -Fu list, which is why it all shares one script.
#
#  Stages:
#    1  Nghttp2ProtobufTests            build + run   (gates)
#    2  Nghttp2ProtobufNegativeTests    build + run   (gates)
#    3  Nghttp2AllocBench               build + run   (reports, never gates)
#    3b Nghttp2ProtobufConformance      build + run   (reports; gates only on
#                                                      a BROKEN probe)
#    4  samples/grpc-server             compile only  (gates)
#    5  samples/grpc-server, old define compile only  (gates back-compat)
#    6  protogen parser tests (C1)      build + run   (gates)
#    7  protoc oracle (C1b)             run           (gates if protoc is
#                                                      present; skips if not)
#    8  protogen emitter tests (C2)     build + run   (gates)
#    9  protogen interface emitter (C3) build + run   (gates)
#   10  protogen runner tests (C4)      build + run   (gates)
#   11  protogen binary (Protogen.dpr)  compile only  (gates)
#   12  protogen GENERATED output (C6a) build + run   (gates; skips without
#                                                      the horse-provider-nghttp2
#                                                      sibling checkout)
#
#  Exists because the obvious command is wrong. Typing
#
#      fpc -MDelphi -Fu../src Nghttp2ProtobufTests.dpr
#
#  picks up the DISTRO compiler — FPC 3.2.2 on Ubuntu — which cannot build this
#  suite at all. It fails with:
#
#      Warning: Illegal compiler directive "$RTTI"
#      Error:   Identifier not found "TCustomAttribute"
#
#  Neither message names the real cause. 3.2.2 has no {$RTTI EXPLICIT ...}
#  directive and no TCustomAttribute in its Rtti unit, so extended RTTI — which
#  the whole attribute-driven serializer depends on — simply is not there.
#  FPC 3.2.2 is a HARD BLOCKER *for the codec*, not a soft minimum: there is no
#  flag that makes attribute-driven serialization work there.
#
#  Scope, since this used to be stated too broadly: the HTTP/2 transport, TLS,
#  the epoll engine, streaming and WebSocket all build AND pass on 3.2.2 —
#  verified 2026-08-22 via build-fpc.sh, 24 stages green. Only this codec and
#  the gRPC layer above it require trunk. Do not generalize this refusal into
#  "the project needs trunk".
#
#  This script pins trunk and the unit paths that go with it. -Fu$TU/rtl-objpas
#  is the one that matters: that is where trunk keeps Rtti and TCustomAttribute.
#
#  Usage:
#    cd patches/Delphi-nghttp2/tests
#    bash build-codec-fpc.sh
#
#  Environment (same names build-fpc.sh uses, so one export covers both):
#    TRUNK_FPC    path to the fpc binary  (default /usr/local/fpc-trunk/bin/fpc)
#    TRUNK_UNITS  path to its unit tree   (default .../units/x86_64-linux)
#
#  Exit code: 0 all tests passed, 1 test failures, 2 compile failure.
# =============================================================================

set -uo pipefail

TRUNK=${TRUNK_FPC:-/usr/local/fpc-trunk/bin/fpc}
TU=${TRUNK_UNITS:-/usr/local/fpc-trunk/lib/fpc/3.3.1/units/x86_64-linux}

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../src"
OUT="$HERE/.fpc-out"

if [[ ! -x "$TRUNK" ]]; then
  echo "FATAL: no FPC trunk at $TRUNK"
  echo "       The distro's fpc (3.2.2) CANNOT build this suite — see the header."
  echo "       Set TRUNK_FPC=/path/to/fpc if trunk lives elsewhere."
  exit 2
fi

# Refuse to proceed on 3.2.2 even if TRUNK_FPC was pointed at it, rather than
# emitting the two misleading errors above and letting them be re-diagnosed.
VER=$("$TRUNK" -iV 2>/dev/null)
case "$VER" in
  3.2.*)
    echo "FATAL: $TRUNK reports version $VER."
    echo "       FPC 3.2.2 lacks {\$RTTI EXPLICIT} and TCustomAttribute — the"
    echo "       attribute-driven serializer cannot compile. Trunk 3.3.1 required."
    exit 2
    ;;
esac

# Deliberately the SAME list build-fpc.sh uses, not a trimmed one.
#
# An incomplete -Fu list does not fail cleanly: FPC falls back to the system
# unit path, finds the DISTRO 3.2.2 .ppu, and reports
#
#     PPU Invalid Version 207 expecting 208
#     Fatal: Can't find unit pthreads used by SyncObjs
#
# which reads as a missing unit but is really a wrong-compiler unit. pthreads
# is the one that bites here, pulled in indirectly by SyncObjs for
# TCriticalSection. Keeping this list identical to build-fpc.sh means a path
# added there is never missing here.
TRUNK_UNIT_PATHS="\
-Fu$TU/rtl -Fu$TU/rtl-console -Fu$TU/rtl-objpas -Fu$TU/rtl-extra \
-Fu$TU/rtl-generics -Fu$TU/fcl-base -Fu$TU/fcl-web -Fu$TU/fcl-json \
-Fu$TU/regexpr -Fu$TU/pthreads -Fu$TU/openssl -Fu$TU/fcl-net -Fu$TU/hash"

echo "FPC:    $TRUNK  (version $VER)"
echo "Units:  $TU"
echo "Source: $SRC"
echo

mkdir -p "$OUT"
rm -f "$OUT"/*.ppu "$OUT"/*.o 2>/dev/null || true

# -FU sends units to their own directory. Without it a stale .ppu built with
# different defines is silently reused — FPC compares timestamps, not the
# define set, so a -d change alone does not invalidate the cache.
"$TRUNK" -MDelphi -O1 \
  -FU"$OUT" -FE"$OUT" \
  -Fu"$SRC" \
  $TRUNK_UNIT_PATHS \
  "$HERE/Nghttp2ProtobufTests.dpr" 2>&1 | sed 's/^/  /'

if [[ ! -x "$OUT/Nghttp2ProtobufTests" ]]; then
  echo
  echo "FAIL  compile did not produce a binary"
  exit 2
fi

echo
# The .dpr ends with ReadLn so a double-clicked console window stays open;
# </dev/null makes that a no-op here instead of a hang.
"$OUT/Nghttp2ProtobufTests" < /dev/null
RC=$?

echo
if [[ $RC -eq 0 ]]; then
  echo "codec suite: PASSED"
else
  echo "codec suite: FAILED (exit $RC)"
fi

# ── negative suite — malformed input must be REJECTED ────────────────────────
# Added 2026-08-24 with the suite itself. This is the gate that stops the five
# defects of that date coming back, and a regression suite nobody runs
# automatically is one refactor away from being decorative — which is exactly
# why it lives here rather than in a README instruction.
#
# -dNGHTTP2_GRPC_NO_FFI is required, for a different reason than the sample
# below needs it. The suite tests StripGrpcPrefix, which lives in
# Nghttp2.Grpc.Dispatcher, whose implementation pulls in Nghttp2.Grpc.Registry,
# which pulls in ffi.manager. Nothing here dispatches a gRPC call, so the define
# severs that and libffi never has to be on the search path. Without it the
# build dies on `PPU Invalid Version 207 expecting 208` from the distro's
# libffi units — the same wrong-compiler trap the header describes, reached by a
# different route.
echo
echo "── negative suite (malformed input) ─────────────────────────────────"
NEG="$HERE/Nghttp2ProtobufNegativeTests.dpr"
if [[ -f "$NEG" ]]; then
  NOUT="$OUT/negative"
  mkdir -p "$NOUT"
  rm -f "$NOUT"/*.ppu "$NOUT"/*.o 2>/dev/null || true
  if "$TRUNK" -MDelphi -O1 -dNGHTTP2_GRPC_NO_FFI \
       -FU"$NOUT" -FE"$NOUT" \
       -Fu"$SRC" \
       $TRUNK_UNIT_PATHS \
       "$NEG" > "$NOUT/build.log" 2>&1 && [[ -x "$NOUT/Nghttp2ProtobufNegativeTests" ]]; then
    "$NOUT/Nghttp2ProtobufNegativeTests" < /dev/null
    NRC=$?
    if [[ $NRC -ne 0 ]]; then
      echo "  negative suite: FAILED ($NRC checks)"
      [[ $RC -eq 0 ]] && RC=1
    else
      echo "  negative suite: PASSED"
    fi
  else
    echo "  FAIL  Nghttp2ProtobufNegativeTests.dpr did not compile"
    grep -E "Error|Fatal" "$NOUT/build.log" | head -12 | sed 's/^/    /'
    echo "    full log: $NOUT/build.log"
    RC=2
  fi
else
  echo "  SKIP  Nghttp2ProtobufNegativeTests.dpr not present"
fi

# ── allocation benchmark — reported, never a gate ────────────────────────────
# Built and run so it cannot rot, but its exit code is deliberately ignored.
# It measures allocations per operation, which is a NUMBER rather than a
# pass/fail: a change there wants a human deciding whether it is an improvement
# or a regression. Wiring it as a gate would mean picking a threshold, and a
# threshold picked without a reason is just a future false alarm.
#
# What it IS good for automatically: proving it still builds and still produces
# bit-identical counts run to run. If two consecutive runs ever disagree, the
# harness is broken — see the file's own closing note.
echo
echo "── allocation benchmark (report only, not a gate) ───────────────────"
BENCH="$HERE/Nghttp2AllocBench.dpr"
if [[ -f "$BENCH" ]]; then
  ABOUT="$OUT/allocbench"
  mkdir -p "$ABOUT"
  rm -f "$ABOUT"/*.ppu "$ABOUT"/*.o 2>/dev/null || true
  if "$TRUNK" -MDelphi -O1 \
       -FU"$ABOUT" -FE"$ABOUT" \
       -Fu"$SRC" \
       $TRUNK_UNIT_PATHS \
       "$BENCH" > "$ABOUT/build.log" 2>&1 && [[ -x "$ABOUT/Nghttp2AllocBench" ]]; then
    # The counting shim is Delphi-only; on FPC the program says so and exits 0.
    # Building it here still has value — it proves the message path compiles
    # and that the message stays accurate.
    "$ABOUT/Nghttp2AllocBench" < /dev/null | sed 's/^/  /'
    echo "  (informational — for real numbers use -gh, or run the Delphi build)"
  else
    echo "  FAIL  Nghttp2AllocBench.dpr did not compile"
    grep -E "Error|Fatal" "$ABOUT/build.log" | head -12 | sed 's/^/    /'
    echo "    full log: $ABOUT/build.log"
    RC=2
  fi
else
  echo "  SKIP  Nghttp2AllocBench.dpr not present"
fi

# ── proto3 conformance probe — report only ───────────────────────────────────
# C0a of plans/horse-grpc-codegen.md. Answers, per proto3 scalar type, whether
# the RTTI serializer encodes it the way the spec says. Several types are
# EXPECTED to deviate (uint32/uint64 confirmed by source reading), which is why
# this cannot live in stage 1: known gaps there would take the 75/75 gate down
# and read as a regression.
#
# It is a stage rather than a documented command because hand-rolling the fpc
# line is exactly how you get `PPU Invalid Version 207 expecting 208` — an
# incomplete -Fu list falls back to the distro 3.2.2 RTL, and the error names
# the wrong cause. See the header note above; this is the second time that trap
# has been paid for.
#
# ExitCode: 0 with deviations (they are findings), 1 only if a probe BREAKS.
echo
echo "── proto3 conformance probe (report only, not a gate) ────────────────"
CONF="$HERE/Nghttp2ProtobufConformance.dpr"
if [[ -f "$CONF" ]]; then
  CFOUT="$OUT/conformance"
  mkdir -p "$CFOUT"
  rm -f "$CFOUT"/*.ppu "$CFOUT"/*.o 2>/dev/null || true
  if "$TRUNK" -MDelphi -O1 \
       -FU"$CFOUT" -FE"$CFOUT" \
       -Fu"$SRC" \
       $TRUNK_UNIT_PATHS \
       "$CONF" > "$CFOUT/build.log" 2>&1 \
     && [[ -x "$CFOUT/Nghttp2ProtobufConformance" ]]; then
    "$CFOUT/Nghttp2ProtobufConformance" < /dev/null | sed 's/^/  /'
    CONF_RC=${PIPESTATUS[0]}
    if [[ "$CONF_RC" -eq 1 ]]; then
      # BROKEN is not a known gap — it means something that should hold does
      # not, and the plan says investigate before writing generator code.
      echo "  FAIL  a conformance probe BROKE (not a known gap) — see above"
      RC=2
    fi
  else
    echo "  FAIL  Nghttp2ProtobufConformance.dpr did not compile"
    grep -E "Error|Fatal" "$CFOUT/build.log" | head -12 | sed 's/^/    /'
    echo "    full log: $CFOUT/build.log"
    RC=2
  fi
else
  echo "  SKIP  Nghttp2ProtobufConformance.dpr not present"
fi

# ── samples/grpc-server — compile only ───────────────────────────────────────
# That sample is this library's claim that the gRPC layer needs no web
# framework, and a claim nobody compiles is a claim nobody has checked. It is
# built here rather than in its own script because the hard part is already
# solved above: the trunk pin and the exact -Fu list. Duplicating that list
# into a second script is the thing this file's own comment warns against.
#
# Compile only, never run: it binds a port and blocks on ReadLn.
#
# -dNGHTTP2_GRPC_NO_FFI is not an optimisation, it is the sample's whole premise
# under test. Nghttp2.Grpc.Registry pulls in ffi.manager on FPC unless that
# define is set, and ffi.manager needs libffi units on the search path. The
# sample registers only through the PROCEDURAL RegisterMethod, which never
# reaches TRttiMethod.Invoke and therefore never needs libffi — so if this
# compiles with the define set, the README's claim to that effect is proven
# rather than asserted. A sample using RegisterService<T> would instead need
# the define OFF and -Fu$TU/libffi ON.
SAMPLE="$HERE/../samples/grpc-server/Nghttp2GrpcServer.dpr"
if [[ -f "$SAMPLE" ]]; then
  echo
  echo "── samples/grpc-server (compile only) ───────────────────────────────"
  SOUT="$OUT/sample"
  mkdir -p "$SOUT"
  rm -f "$SOUT"/*.ppu "$SOUT"/*.o 2>/dev/null || true
  if "$TRUNK" -MDelphi -O1 -dNGHTTP2_GRPC_NO_FFI \
       -FU"$SOUT" -FE"$SOUT" \
       -Fu"$SRC" -Fu"$(dirname "$SAMPLE")" \
       $TRUNK_UNIT_PATHS \
       "$SAMPLE" > "$SOUT/build.log" 2>&1 && [[ -x "$SOUT/Nghttp2GrpcServer" ]]; then
    echo "  PASS  Nghttp2GrpcServer.dpr"
  else
    echo "  FAIL  Nghttp2GrpcServer.dpr"
    grep -E "Error|Fatal" "$SOUT/build.log" | head -12 | sed 's/^/    /'
    echo "    full log: $SOUT/build.log"
    RC=2
  fi
  # ── the DEPRECATED define, still honoured until 2.0.0 ─────────────────────
  # A back-compat path nobody exercises is the same trap as a shim nobody
  # compiles, and this one is easy to break silently: the guard reads
  #   NOT DEFINED(NGHTTP2_GRPC_NO_FFI) AND NOT DEFINED(HORSE_GRPC_NO_FFI)
  # and dropping either clause still compiles for everyone using the OTHER
  # name. So build the same sample with the old spelling and require that it
  # compiles — which is the property users actually depend on.
  #
  # It does NOT assert that the deprecation notice was printed, and that is a
  # deliberate retreat. The unit carries a {$MESSAGE WARNING} for the old
  # define; it demonstrably fires when the unit is compiled directly, and an
  # equivalent directive fires from an equivalent unit compiled as a
  # dependency under these exact flags — but it does not appear in THIS
  # build's output, and eight rounds of bisection did not explain why.
  # Ruled out along the way, each by experiment: the directive itself
  # (WARNING and WARN both fire on FPC 3.3.1, quoted text included), nesting
  # and {$IFEND}, interface vs implementation placement, unit vs program,
  # -O1, the long -Fu list, -FU/-FE output dirs, and stale .ppu reuse. What
  # DID reproduce: a cached .ppu suppresses the message, because {$MESSAGE}
  # only fires when a unit is genuinely recompiled — worth remembering, but
  # not the cause here, since the ppu timestamps post-date the source.
  #
  # Asserting an unexplained diagnostic would make this gate fail for a
  # reason nobody can act on. The rename works; the courtesy warning is
  # cosmetic. Left as an open question rather than a red build.
  #
  # Do not try this by hand with an ad-hoc fpc line. Without -n and the full
  # -Fu list, trunk reads /etc/fpc.cfg, loads the distro 3.2.2 system.ppu and
  # dies with "PPU Invalid Version 207 expecting 208" — the trap this file's
  # header already documents, and which cost a round trip on 2026-08-23.
  echo
  echo "── samples/grpc-server via the DEPRECATED define ────────────────────"
  BOUT="$OUT/sample-oldname"
  mkdir -p "$BOUT"
  rm -f "$BOUT"/*.ppu "$BOUT"/*.o 2>/dev/null || true
  if "$TRUNK" -MDelphi -O1 -dHORSE_GRPC_NO_FFI \
       -FU"$BOUT" -FE"$BOUT" \
       -Fu"$SRC" -Fu"$(dirname "$SAMPLE")" \
       $TRUNK_UNIT_PATHS \
       "$SAMPLE" > "$BOUT/build.log" 2>&1 && [[ -x "$BOUT/Nghttp2GrpcServer" ]]; then
    if grep -q 'HORSE_GRPC_NO_FFI is deprecated' "$BOUT/build.log"; then
      echo "  PASS  old define still honoured, and announced"
    else
      # Informational, not a failure — see the note above.
      echo "  PASS  old define still honoured"
      echo "        (deprecation notice not printed in this build; known open"
      echo "         question, see the comment above. Compiling the unit alone"
      echo "         does print it.)"
    fi
  else
    echo "  FAIL  old define no longer compiles — back-compat is broken"
    grep -E "Error|Fatal" "$BOUT/build.log" | head -12 | sed 's/^/    /'
    echo "    full log: $BOUT/build.log"
    RC=2
  fi
else
  echo
  echo "  SKIP  samples/grpc-server not present"
fi

# ── 6 · protogen parser (C1) ────────────────────────────────────────────────
# The .proto parser behind the code generator. Nothing else in this script
# touches it, and until it was wired in here it only ran when somebody
# remembered to - the "regression suite that is one refactor away from being
# decorative" that run-tests.bat's own header warns about.
#
# Its units are pure RTL (SysUtils / Classes / Generics.Collections) and pull
# in no Nghttp2 unit at all, so $SRC is deliberately NOT on the path: if this
# ever fails to compile without it, something has coupled the generator to the
# codec and that is worth finding out about here rather than later.
#
# Own -FU directory for the reason stated at stage 1: FPC compares timestamps,
# not defines, so sharing a unit dir silently reuses .ppu files built with
# other flags.
echo
echo "── protogen parser tests (C1) ────────────────────────────────────────"
PROTOGEN="$HERE/../tools/protogen"

# The C2 and C3 emit gates compare generated output against the REAL
# hand-written samples on disk. They locate those relative to the running
# executable, which is correct on Windows where the tests are built in place —
# but here every binary is built into $OUT, so ExeDir points at a scratch
# directory and the lookup fails: echo FAILs (it is in-repo, so absence is a
# defect) and greeter SKIPs, taking the suite to "GATE INCOMPLETE".
#
# Echo lives in this repo; greeter lives in the sibling horse-provider-nghttp2
# checkout. If that sibling is absent the greeter comparisons skip loudly and
# the stage reports incomplete, which is the intended behaviour rather than a
# silent pass.
export PROTOGEN_ECHO_DIR="$HERE/../samples/grpc-server"
export PROTOGEN_GREETER_DIR="$HERE/../../horse-provider-nghttp2/samples/grpc"
if [[ -f "$PROTOGEN/ProtogenParserTests.dpr" ]]; then
  PGOUT="$OUT/protogen"
  mkdir -p "$PGOUT"
  rm -f "$PGOUT"/*.ppu "$PGOUT"/*.o 2>/dev/null || true
  if "$TRUNK" -MDelphi -O1 \
       -FU"$PGOUT" -FE"$PGOUT" \
       -Fu"$PROTOGEN" \
       $TRUNK_UNIT_PATHS \
       "$PROTOGEN/ProtogenParserTests.dpr" > "$PGOUT/build.log" 2>&1 \
     && [[ -x "$PGOUT/ProtogenParserTests" ]]; then
    "$PGOUT/ProtogenParserTests" < /dev/null | sed 's/^/  /'
    PG_RC=${PIPESTATUS[0]}
    if [[ "$PG_RC" -eq 0 ]]; then
      echo "  parser tests: PASSED"
    else
      echo "  FAIL  protogen parser tests"
      RC=1
    fi
  else
    echo "  FAIL  ProtogenParserTests.dpr did not compile"
    grep -E "Error|Fatal" "$PGOUT/build.log" | head -12 | sed 's/^/    /'
    echo "    full log: $PGOUT/build.log"
    RC=2
  fi
else
  echo "  SKIP  tools/protogen not present"
fi

# ── 7 · protoc oracle (C1b) ─────────────────────────────────────────────────
# Differential test against the reference implementation. Kept OPTIONAL on the
# protoc side and gating on ours: protoc is an extra install (pip install
# grpcio-tools), so a machine without it skips rather than fails - unlike the
# parser tests above, which need nothing this script does not already have.
#
# That asymmetry is deliberate. protoc-oracle.sh itself FAILS when protoc is
# missing, because a differential test that silently did not run is worse than
# no test; here we make the decision to run it at all, and record the skip.
echo
echo "── protoc oracle (C1b, needs protoc or grpcio-tools) ─────────────────"
if [[ -x "$PROTOGEN/protoc-oracle.sh" ]] || [[ -f "$PROTOGEN/protoc-oracle.sh" ]]; then
  ORACLE_AVAILABLE=0
  if command -v protoc > /dev/null 2>&1; then ORACLE_AVAILABLE=1; fi
  if [[ -x "$PROTOGEN/.venv/bin/python" ]] \
     && "$PROTOGEN/.venv/bin/python" -c 'import grpc_tools.protoc' > /dev/null 2>&1; then
    ORACLE_AVAILABLE=1
  fi
  if python3 -c 'import grpc_tools.protoc' > /dev/null 2>&1; then ORACLE_AVAILABLE=1; fi

  if [[ "$ORACLE_AVAILABLE" -eq 1 ]]; then
    if bash "$PROTOGEN/protoc-oracle.sh" 2>&1 | sed 's/^/  /'; then
      echo "  oracle: CLEAN"
    else
      echo "  FAIL  protoc oracle reported a disagreement"
      RC=1
    fi
  else
    echo "  SKIP  no protoc and no grpc_tools — install with:"
    echo "          python3 -m venv $PROTOGEN/.venv"
    echo "          $PROTOGEN/.venv/bin/python -m pip install grpcio-tools"
  fi
else
  echo "  SKIP  protoc-oracle.sh not present"
fi

# ── 8 · protogen emitter (C2) ───────────────────────────────────────────────
# TMessagesEmitter: generates .Messages.pas from a parsed TProtoFileNode.
# Same unit-path rules as stage 6 (pure RTL, no Nghttp2 unit on the path),
# and same gating: a mismatch here means generated code diverges from the
# hand-verified .Messages.pas originals.
echo
echo "── protogen emitter tests (C2) ───────────────────────────────────────"
if [[ -f "$PROTOGEN/ProtogenEmitTests.dpr" ]]; then
  PEOUT="$OUT/protogen-emit"
  mkdir -p "$PEOUT"
  rm -f "$PEOUT"/*.ppu "$PEOUT"/*.o 2>/dev/null || true
  if "$TRUNK" -MDelphi -O1 \
       -FU"$PEOUT" -FE"$PEOUT" \
       -Fu"$PROTOGEN" \
       $TRUNK_UNIT_PATHS \
       "$PROTOGEN/ProtogenEmitTests.dpr" > "$PEOUT/build.log" 2>&1 \
     && [[ -x "$PEOUT/ProtogenEmitTests" ]]; then
    "$PEOUT/ProtogenEmitTests" < /dev/null | sed 's/^/  /'
    PE_RC=${PIPESTATUS[0]}
    if [[ "$PE_RC" -eq 0 ]]; then
      echo "  emitter tests: PASSED"
    else
      echo "  FAIL  protogen emitter tests"
      [[ $RC -eq 0 ]] && RC=1
    fi
  else
    echo "  FAIL  ProtogenEmitTests.dpr did not compile"
    grep -E "Error|Fatal" "$PEOUT/build.log" | head -12 | sed 's/^/    /'
    echo "    full log: $PEOUT/build.log"
    RC=2
  fi
else
  echo "  SKIP  ProtogenEmitTests.dpr not present"
fi

# ── 9 · protogen service+interfaces emitter (C3) ────────────────────────────
# TInterfacesEmitter + TServiceSkeletonEmitter. Same unit-path rules as stage 8
# (pure RTL + protogen dir, no Nghttp2 units) — keeping them separate means a
# dependency on Nghttp2 code would surface as a compile failure here.
echo
echo "── protogen interface emitter tests (C3) ────────────────────────────────"
if [[ -f "$PROTOGEN/ProtogenInterfaceTests.dpr" ]]; then
  PIOUT="$OUT/protogen-iface"
  mkdir -p "$PIOUT"
  rm -f "$PIOUT"/*.ppu "$PIOUT"/*.o 2>/dev/null || true
  if "$TRUNK" -MDelphi -O1 \
       -FU"$PIOUT" -FE"$PIOUT" \
       -Fu"$PROTOGEN" \
       $TRUNK_UNIT_PATHS \
       "$PROTOGEN/ProtogenInterfaceTests.dpr" > "$PIOUT/build.log" 2>&1 \
     && [[ -x "$PIOUT/ProtogenInterfaceTests" ]]; then
    "$PIOUT/ProtogenInterfaceTests" < /dev/null | sed 's/^/  /'
    PI_RC=${PIPESTATUS[0]}
    if [[ "$PI_RC" -eq 0 ]]; then
      echo "  interface emitter tests: PASSED"
    else
      echo "  FAIL  protogen interface emitter tests"
      [[ $RC -eq 0 ]] && RC=1
    fi
  else
    echo "  FAIL  ProtogenInterfaceTests.dpr did not compile"
    grep -E "Error|Fatal" "$PIOUT/build.log" | head -12 | sed 's/^/    /'
    echo "    full log: $PIOUT/build.log"
    [[ $RC -eq 0 ]] && RC=2
  fi
else
  echo "  SKIP  ProtogenInterfaceTests.dpr not present"
fi

# ── 10 · protogen runner (C4) ───────────────────────────────────────────────
# TProtogenRunner: reads a proto file, orchestrates the three emitters, writes
# output units into a directory.  This is the layer the CLI binary wraps.
#
# Uses a real temp directory (GetTempDir + 'pgtc4') so it exercises actual file
# I/O — existence checks, ForceDirectories, the no-overwrite contract.  Content
# correctness is covered by stages 8 and 9; this gate focuses on file creation,
# no-overwrite, dry-run, and the high-level Run() error paths.
echo
echo "── protogen runner tests (C4) ────────────────────────────────────────"
if [[ -f "$PROTOGEN/ProtogenRunnerTests.dpr" ]]; then
  PROUT="$OUT/protogen-runner"
  mkdir -p "$PROUT"
  rm -f "$PROUT"/*.ppu "$PROUT"/*.o 2>/dev/null || true
  if "$TRUNK" -MDelphi -O1 \
       -FU"$PROUT" -FE"$PROUT" \
       -Fu"$PROTOGEN" \
       $TRUNK_UNIT_PATHS \
       "$PROTOGEN/ProtogenRunnerTests.dpr" > "$PROUT/build.log" 2>&1 \
     && [[ -x "$PROUT/ProtogenRunnerTests" ]]; then
    "$PROUT/ProtogenRunnerTests" < /dev/null | sed 's/^/  /'
    PR_RC=${PIPESTATUS[0]}
    if [[ "$PR_RC" -eq 0 ]]; then
      echo "  runner tests: PASSED"
    else
      echo "  FAIL  protogen runner tests"
      [[ $RC -eq 0 ]] && RC=1
    fi
  else
    echo "  FAIL  ProtogenRunnerTests.dpr did not compile"
    grep -E "Error|Fatal" "$PROUT/build.log" | head -12 | sed 's/^/    /'
    echo "    full log: $PROUT/build.log"
    [[ $RC -eq 0 ]] && RC=2
  fi
else
  echo "  SKIP  ProtogenRunnerTests.dpr not present"
fi

# ── 11 · protogen binary (compile only) ─────────────────────────────────────
# Protogen.dpr is the CLI binary — compile it, do not run it (it exits 1 when
# called with no arguments, which would set RC here incorrectly).  A compile
# failure means the runner unit broke its public API, or a dep was removed.
echo
echo "── protogen binary — compile only ────────────────────────────────────"
if [[ -f "$PROTOGEN/Protogen.dpr" ]]; then
  PBOUT="$OUT/protogen-bin"
  mkdir -p "$PBOUT"
  rm -f "$PBOUT"/*.ppu "$PBOUT"/*.o 2>/dev/null || true
  if "$TRUNK" -MDelphi -O1 \
       -FU"$PBOUT" -FE"$PBOUT" \
       -Fu"$PROTOGEN" \
       $TRUNK_UNIT_PATHS \
       "$PROTOGEN/Protogen.dpr" > "$PBOUT/build.log" 2>&1 \
     && [[ -x "$PBOUT/Protogen" ]]; then
    echo "  PASS  Protogen.dpr"
  else
    echo "  FAIL  Protogen.dpr did not compile"
    grep -E "Error|Fatal" "$PBOUT/build.log" | head -12 | sed 's/^/    /'
    echo "    full log: $PBOUT/build.log"
    [[ $RC -eq 0 ]] && RC=2
  fi
else
  echo "  SKIP  Protogen.dpr not present"
fi

# ── 12 · C6a — compile protogen's OUTPUT with FPC ───────────────────────────
# Every other protogen stage compares generated text against expected text.
# This one generates into a scratch directory and puts the result in front of
# the compiler, so a language-level defect in an emitter — a type that does not
# exist, a method pointer that is not assignment-compatible, a missing unit in
# a uses clause — actually fails something.
#
# The Windows suite has the equivalent stage. Running it on FPC too is the
# point: protogen is dual-compilation and its gates run on both compilers, but
# until this stage existed its OUTPUT had only ever been compiled by dcc64.
#
# Reuses the binary built by stage 11 rather than rebuilding it.
echo
echo "── protogen generated output — compile (C6a) ─────────────────────────"
GENPROTO="$HERE/../../horse-provider-nghttp2/samples/grpc/greeter.proto"
if [[ ! -f "$PROTOGEN/ProtogenGeneratedCompileCheck.dpr" ]]; then
  echo "  SKIP  ProtogenGeneratedCompileCheck.dpr not present"
elif [[ ! -x "$PBOUT/Protogen" ]]; then
  echo "  SKIP  Protogen binary not built by the previous stage"
elif [[ ! -f "$GENPROTO" ]]; then
  echo "  SKIP  greeter.proto not found — needs the horse-provider-nghttp2 sibling"
  echo "        looked in: $GENPROTO"
else
  GENOUT="$OUT/protogen-gencheck"
  GCOUT="$OUT/protogen-gencheck-bin"
  # Deleted, not just cleaned: the no-overwrite contract preserves an existing
  # .Service.pas and writes .Service.new.pas instead, so a leftover directory
  # would compile the PREVIOUS run's skeleton and pass while proving nothing.
  rm -rf "$GENOUT" "$GCOUT"
  mkdir -p "$GENOUT" "$GCOUT"

  if ! "$PBOUT/Protogen" -i "$GENPROTO" -o "$GENOUT" \
         --unit-prefix Sample.Greeter > "$GCOUT/generate.log" 2>&1; then
    echo "  FAIL  Protogen could not generate into $GENOUT"
    sed 's/^/    /' "$GCOUT/generate.log" | head -12
    [[ $RC -eq 0 ]] && RC=2
  # NOTE the deliberate difference from the samples/grpc-server stage above:
  # that one sets -dNGHTTP2_GRPC_NO_FFI because it registers only through the
  # PROCEDURAL RegisterMethod, which never reaches TRttiMethod.Invoke. Generated
  # code does the opposite — the registration unit calls RegisterService<T>,
  # the IInvokable/RTTI path — so it genuinely needs ffi.manager, and the define
  # would be a lie here. That is why libffi goes on the search path instead.
  #
  # This is a real property of protogen's output on FPC, not a build detail:
  # anything consuming a generated .Registration.pas needs libffi available.
  elif "$TRUNK" -MDelphi -O1 \
         -FU"$GCOUT" -FE"$GCOUT" \
         -Fu"$GENOUT" -Fu"$SRC" -Fu"$TU/libffi" \
         $TRUNK_UNIT_PATHS \
         "$PROTOGEN/ProtogenGeneratedCompileCheck.dpr" > "$GCOUT/build.log" 2>&1 \
       && [[ -x "$GCOUT/ProtogenGeneratedCompileCheck" ]]; then
    "$GCOUT/ProtogenGeneratedCompileCheck" < /dev/null | sed 's/^/  /'
    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
      echo "  PASS  generated units compile and register under FPC"
    else
      echo "  FAIL  generated units compiled but registration was wrong"
      [[ $RC -eq 0 ]] && RC=2
    fi
  else
    echo "  FAIL  protogen's generated units did not compile under FPC"
    grep -E "Error|Fatal" "$GCOUT/build.log" | head -12 | sed 's/^/    /'
    echo "    full log: $GCOUT/build.log"
    echo "    generated units kept for inspection: $GENOUT"
    [[ $RC -eq 0 ]] && RC=2
  fi
fi

exit $RC
