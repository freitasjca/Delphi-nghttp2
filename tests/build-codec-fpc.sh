#!/usr/bin/env bash
# =============================================================================
#  build-codec-fpc.sh
#  Compile + run Nghttp2ProtobufTests under FPC, then compile (not run) the
#  standalone samples/grpc-server. Both need trunk for the same reason, and
#  both need the same -Fu list, which is why they share this script.
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

exit $RC
