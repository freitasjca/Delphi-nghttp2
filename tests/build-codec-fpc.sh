#!/usr/bin/env bash
# =============================================================================
#  build-codec-fpc.sh
#  Compile + run Nghttp2ProtobufTests under FPC.
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
#  FPC 3.2.2 is a documented HARD BLOCKER for this codebase, not a soft
#  minimum; there is no flag that makes it work.
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
exit $RC
