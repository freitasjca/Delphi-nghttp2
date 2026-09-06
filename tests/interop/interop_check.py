#!/usr/bin/env python3
"""
§7.5 cross-language interop check — Python is the reference implementation.

WHY THIS EXISTS
---------------
FIX-PROTO-UINT32-1 was real data corruption: proto3 uint32 above MaxInt was
sign-extended onto the wire for years. It survived because the bug was
SYMMETRIC — our client and our server share a codec, so every round-trip
agreed with itself perfectly. No amount of internal testing could find it.

Only an independent implementation can. That is this script's whole job.

And it must use BOUNDARY VALUES. A naive interop test with small integers
passes against the broken code too: 42 encodes identically whether or not the
encoder sign-extends. The bug lives above MaxInt, so that is where the cases
are.

HOW IT WORKS
------------
    Python  builds N boundary-value messages and serialises each with the
            google.protobuf reference implementation      -> cases/X-NNN.bin
    Pascal  reads each case, DECODES it, RE-ENCODES it     -> roundtrip/X-NNN.bin
    Python  decodes the round-tripped bytes and compares FIELD VALUES against
            the originals

The filename prefix names the message type, and the Pascal side dispatches on
it: `s-` is Scalars, `c-` is Composite.

Values are compared, not bytes, and that is deliberate.

The original reason was that our encoder emitted default-valued scalars where
canonical proto3 omits them — non-canonical but perfectly decodable, so a byte
compare would have failed on a known-benign difference and hidden the real
question. CANONICAL-1 has since removed that deviation, so for these scalar
cases our bytes should now match Python's.

The comparison stays on VALUES regardless, and not from inertia: what this
file exists to catch is a peer reading a DIFFERENT VALUE from our bytes, which
is exactly what FIX-PROTO-UINT32-1 did. Byte equality is a stricter condition
that would also fail on differences nobody would care about, and a test that
fails for uninteresting reasons gets relaxed or ignored rather than fixed. Two
deviations also remain — zigzag and fixed-width, both structural in
TProtoMemberAttribute — which a byte compare would trip over if those types
were ever exercised here.

C6c DEPTH — what the Composite cases add
----------------------------------------
Repeated fields and submessages reach the codec through code paths the scalar
cases never touch:

  * Repeated numerics are PACKED. Python emits packed by default for proto3,
    so these cases are the first time our DECODER has been handed packed input
    by an independent implementation, and the first time our packed OUTPUT has
    been judged by one.

  * WritePackedElement is separate code from the singular field writer, and
    reads uint32/uint64 through different TValue accessors chosen specifically
    to dodge the FIX-PROTO-UINT32-1 overflow — chosen by reasoning, never
    checked against a reference until now.

  * Submessages exercise recursion and the proto3 presence distinction between
    an absent field and a present-but-all-defaults one.

USAGE
-----
    python3 interop_check.py --pascal <path-to-Nghttp2InteropCodec>

Exit code 0 = every case round-tripped with identical values.

SPLIT MODE — running the Pascal half on a machine with no Python
----------------------------------------------------------------
The Delphi half of this check needs to run on Windows, where grpcio-tools is
usually not installed. It is worth running there rather than trusting the FPC
result, because the codec is NOT the same code on both compilers: Delphi has
no unsigned-64 type kind and types UInt64 as tkInt64, reaching the packed
writer through a different arm than FPC's tkQWord. That is the same split
Nghttp2ProtobufConformance exists to cover on Windows.

So the three phases can be run separately, with only the Pascal step needing
to happen on the target machine:

    # 1. on any machine with Python + grpcio-tools
    python3 interop_check.py --emit-only --work /shared/run

    # 2. on the Delphi machine — no Python needed
    Nghttp2InteropCodec.exe \\shared\\run\\cases \\shared\\run\\roundtrip

    # 3. back where Python lives
    python3 interop_check.py --verify-only --work /shared/run

The case set is built deterministically from this file, so phase 3 rebuilds
the originals in memory rather than trusting anything phase 1 left on disk.
That is deliberate: a stale or hand-edited case file cannot silently become
the thing being asserted against.
"""

import argparse
import os
import shutil
import struct
import subprocess
import sys

# NOTE: google.protobuf is imported LAZILY, never at module level. The rest of
# this file already follows that rule — generate_module() imports the generated
# interop_pb2 only after putting it on sys.path — and breaking it costs more
# than it looks: a top-level import makes the script die before argparse runs,
# so `--help` fails and a missing dependency reports itself as a traceback from
# line 1 rather than as the missing dependency it is.

HERE = os.path.dirname(os.path.abspath(__file__))

U32_MAX = 4294967295
U64_MAX = 18446744073709551615
I32_MIN, I32_MAX = -2147483648, 2147483647
I64_MIN, I64_MAX = -9223372036854775808, 9223372036854775807
F32_MAX = struct.unpack("<f", struct.pack("<f", 3.4028234663852886e38))[0]


def generate_module(out_dir):
    """Run grpc_tools.protoc on interop.proto and import the result."""
    os.makedirs(out_dir, exist_ok=True)
    cmd = [sys.executable, "-m", "grpc_tools.protoc",
           "-I", HERE, "--python_out", out_dir,
           os.path.join(HERE, "interop.proto")]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        print("FAIL: protoc could not compile interop.proto", file=sys.stderr)
        print(proc.stderr, file=sys.stderr)
        sys.exit(1)
    sys.path.insert(0, out_dir)
    import interop_pb2                      # noqa: E402  (generated at runtime)
    return interop_pb2


def build_scalar_cases(pb):
    """The scalar boundary values. Each entry is (name, message)."""
    cases = []

    def case(name, **kw):
        m = pb.Scalars()
        for k, v in kw.items():
            setattr(m, k, v)
        cases.append((name, m))

    # The control: every field at its proto3 default. Canonical encoding is
    # zero bytes; ours emits tag+0 for each. Values must still survive.
    case("all_defaults")

    # uint32 — the FIX-PROTO-UINT32-1 territory. Anything at or below MaxInt
    # would pass against the broken encoder, so the interesting cases are above.
    case("u32_one",        u32=1)
    case("u32_maxint",     u32=I32_MAX)
    case("u32_maxint_p1",  u32=I32_MAX + 1)     # first value that sign-extends
    case("u32_max",        u32=U32_MAX)

    # uint64 — same shape one width up. Delphi types UInt64 as tkInt64 (there
    # is no unsigned-64 type kind), so this arm reaches the codec differently.
    case("u64_one",        u64=1)
    case("u64_high_i64",   u64=I64_MAX)
    case("u64_high_i64_p1", u64=I64_MAX + 1)    # above High(Int64)
    case("u64_max",        u64=U64_MAX)

    # Signed extremes. proto3 sign-extends negative int32 to 10 bytes.
    case("i32_minus_one",  i32=-1)
    case("i32_min",        i32=I32_MIN)
    case("i32_max",        i32=I32_MAX)
    case("i64_min",        i64=I64_MIN)
    case("i64_max",        i64=I64_MAX)

    case("bool_true",      b=True)
    case("colour_red",     colour=pb.COLOUR_RED)
    case("colour_blue",    colour=pb.COLOUR_BLUE)

    # Strings: multi-byte UTF-8, an embedded quote, and an embedded NUL — the
    # last one catches any length-vs-terminator confusion.
    case("s_ascii",        s="hello")
    case("s_utf8",         s="olá 世界 \U0001f40e")
    case("s_quote",        s="it's \"quoted\"")
    case("s_nul",          s="a\x00b")
    case("s_empty",        s="")

    # Bytes: NUL and high bytes, which a string-typed path would corrupt.
    case("blob_bytes",     blob=bytes([0x00, 0x01, 0xFE, 0xFF, 0x7F, 0x80]))
    case("blob_empty",     blob=b"")

    # Floats chosen to be exactly representable, so a mismatch means a real
    # encoding fault rather than a rounding artefact.
    case("f32_simple",     f32=3.5)
    case("f32_negative",   f32=-2.25)
    case("f32_max",        f32=F32_MAX)
    case("f64_simple",     f64=1.5)
    case("f64_max",        f64=1.7976931348623157e308)
    case("f64_tiny",       f64=5e-324)

    # Everything at once — catches field-ordering and offset bugs that
    # single-field cases cannot.
    m = pb.Scalars(i32=-7, i64=I64_MIN, u32=U32_MAX, u64=U64_MAX, b=True,
                   s="mixed é", f32=1.25, f64=2.5,
                   blob=bytes([0xDE, 0xAD, 0xBE, 0xEF]))
    m.colour = pb.COLOUR_BLUE
    cases.append(("everything", m))

    return cases


def build_composite_cases(pb):
    """C6c depth — repeated fields and submessages. (name, message) pairs."""
    cases = []

    def case(name, **kw):
        """Repeated fields cannot be set by constructor keyword in every
        protobuf version, so build empty and extend explicitly."""
        m = pb.Composite()
        for k, v in kw.items():
            getattr(m, k).extend(v)
        cases.append((name, m))

    # ── The empty control ────────────────────────────────────────────────
    # Every repeated field absent and no submessage. Our encoder emits
    # NOTHING for an empty repeated field (unlike its scalar behaviour), so
    # this asserts that "absent stays absent" rather than becoming [0].
    cases.append(("comp_empty", pb.Composite()))

    # ── Empty-vs-zero, the distinction packing makes easy to lose ────────
    # A one-element list holding the default value is NOT the same as an
    # empty list, and the two are only one byte apart on the wire. If the
    # encoder ever "optimises away" default-valued elements, this is the
    # case that catches it.
    case("r_i32_single_zero", r_i32=[0])
    case("r_i32_single_one",  r_i32=[1])

    # ── Packed varint families at their boundaries ───────────────────────
    case("r_i32_bounds",  r_i32=[0, 1, -1, I32_MIN, I32_MAX])
    case("r_i64_bounds",  r_i64=[0, 1, -1, I64_MIN, I64_MAX])

    # The highest-value cases in this file. WritePackedElement reads uint32
    # via TValue.AsOrdinal — a different accessor from the singular path
    # that FIX-PROTO-UINT32-1 broke, and one never checked against an
    # independent encoder until now.
    case("r_u32_bounds",  r_u32=[0, 1, I32_MAX, I32_MAX + 1, U32_MAX])
    case("r_u64_bounds",  r_u64=[0, 1, I64_MAX, I64_MAX + 1, U64_MAX])

    case("r_bool_mixed",  r_bool=[True, False, True, True])
    case("r_colour_all",  r_colour=[pb.COLOUR_UNSET, pb.COLOUR_RED,
                                    pb.COLOUR_BLUE])

    # ── Packed fixed-width families ──────────────────────────────────────
    # Exactly-representable values only, so a mismatch is an encoding fault
    # and not a rounding artefact.
    case("r_f32_bounds",  r_f32=[0.0, 3.5, -2.25, F32_MAX])
    case("r_f64_bounds",  r_f64=[0.0, 1.5, -2.5, 1.7976931348623157e308,
                                 5e-324])

    # ── Unpacked family: LEN-per-element, tag repeated ───────────────────
    case("r_str_simple",  r_str=["a", "bb", "ccc"])
    case("r_str_empties", r_str=["", "x", ""])   # empty elements must survive
    case("r_str_utf8",    r_str=["olá", "世界", "\U0001f40e"])
    case("r_str_nul",     r_str=["a\x00b", "c"])

    # ── Singular submessage: the three presence states ───────────────────
    # absent — no `inner` at all. Round-trips as still-absent.
    cases.append(("inner_absent", pb.Composite()))

    # present but all-default. Python encodes tag+len(0); our encoder emits
    # every scalar unconditionally so it comes back longer, but the VALUES
    # are unchanged and presence is preserved. This is exactly the case the
    # values-not-bytes rule exists for.
    m = pb.Composite()
    m.inner.SetInParent()
    cases.append(("inner_empty", m))

    m = pb.Composite()
    m.inner.id = 7
    m.inner.name = "seven"
    cases.append(("inner_set", m))

    # A submessage whose own fields are at boundaries — the recursion must
    # not lose precision on the way down.
    m = pb.Composite()
    m.inner.id = I32_MIN
    m.inner.name = "olá\x00end"
    cases.append(("inner_bounds", m))

    # ── Repeated submessage ──────────────────────────────────────────────
    m = pb.Composite()
    m.r_inner.add(id=1, name="one")
    cases.append(("r_inner_single", m))

    m = pb.Composite()
    m.r_inner.add(id=1, name="one")
    m.r_inner.add(id=2, name="two")
    m.r_inner.add(id=3, name="three")
    cases.append(("r_inner_many", m))

    # An element that is entirely default. Encoded as a zero-length
    # submessage; it must come back as a present element, not be dropped —
    # dropping it would silently shorten the array the peer receives.
    m = pb.Composite()
    m.r_inner.add()
    m.r_inner.add(id=9, name="nine")
    m.r_inner.add()
    cases.append(("r_inner_empty_elems", m))

    # ── Everything at once ───────────────────────────────────────────────
    # Field ordering and offset bugs need more than one populated field to
    # show up, and repeated fields interleaved with a submessage is the
    # shape most likely to expose one.
    m = pb.Composite()
    m.r_i32.extend([1, -1, I32_MAX])
    m.r_i64.extend([I64_MIN])
    m.r_u32.extend([U32_MAX, 0])
    m.r_u64.extend([U64_MAX])
    m.r_bool.extend([False, True])
    m.r_colour.extend([pb.COLOUR_BLUE])
    m.r_f32.extend([1.25])
    m.r_f64.extend([2.5, -0.5])
    m.r_str.extend(["mixed é", ""])
    m.inner.id = 42
    m.inner.name = "answer"
    m.r_inner.add(id=1, name="a")
    m.r_inner.add(id=2, name="b")
    cases.append(("comp_everything", m))

    return cases


def _fmt(value):
    """One-line rendering of anything a field can hold.

    protobuf's str() on a message is MULTI-LINE, and a newline in the middle of
    a report row truncates everything after it — the "got back" half of a diff
    silently disappears, which is the one half you need. text_format's
    as_one_line does the job properly for messages; lists of messages need it
    applied per element."""
    # Imported here, not at module scope — see the note beside the imports.
    # Only reached on a diff, so the repeated lookup costs nothing on the
    # happy path and Python caches the module anyway.
    from google.protobuf import text_format

    if hasattr(value, "DESCRIPTOR"):
        return "{%s}" % text_format.MessageToString(value, as_one_line=True)
    if isinstance(value, list):
        return "[%s]" % ", ".join(_fmt(v) for v in value)
    return repr(value)


def _is_repeated(fd):
    """protobuf renamed this out from under us. 5.26+ (and the upb
    implementation that ships by default in 7.x) expose `fd.is_repeated` and
    have DROPPED `fd.label` entirely; older releases only have `label`. Ask for
    the new one first and fall back, so this script runs against whatever
    protobuf the machine happens to have — the point of an independent
    reference is lost if it only works against one version of it."""
    if hasattr(fd, "is_repeated"):
        return fd.is_repeated
    return fd.label == fd.LABEL_REPEATED


def diff_messages(pb_class, original, got):
    """Field-by-field comparison so the report names the field, not just the
    message. Repeated and submessage fields are compared by value through the
    reference implementation's own equality, which is what makes this an
    independent judgement rather than ours."""
    diffs = []
    for fd in pb_class.DESCRIPTOR.fields:
        a = getattr(original, fd.name)
        b = getattr(got, fd.name)

        # Repeated fields: compare as lists. Message elements compare
        # structurally via protobuf's own __eq__.
        if _is_repeated(fd):
            la, lb = list(a), list(b)
            if la != lb:
                diffs.append("%s: sent %s (%d), got back %s (%d)"
                             % (fd.name, _fmt(la), len(la), _fmt(lb), len(lb)))
            continue

        # Singular submessage: presence matters as much as content. An
        # absent field that comes back present (or the reverse) is a real
        # defect even when every scalar inside happens to match.
        if fd.type == fd.TYPE_MESSAGE:
            ha = original.HasField(fd.name)
            hb = got.HasField(fd.name)
            if ha != hb:
                diffs.append("%s: presence changed, sent %s, got back %s"
                             % (fd.name, ha, hb))
            elif ha and a != b:
                diffs.append("%s: sent %s, got back %s"
                             % (fd.name, _fmt(a), _fmt(b)))
            continue

        if a != b:
            diffs.append("%s: sent %s, got back %s"
                         % (fd.name, _fmt(a), _fmt(b)))
    return diffs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pascal",
                    help="path to the compiled Nghttp2InteropCodec binary "
                         "(required unless --emit-only or --verify-only)")
    ap.add_argument("--work", default=os.path.join(HERE, ".interop-out"))
    ap.add_argument("--emit-only", action="store_true",
                    help="write the case files and stop (split mode phase 1)")
    ap.add_argument("--verify-only", action="store_true",
                    help="verify an existing roundtrip dir (split mode phase 3)")
    args = ap.parse_args()

    if args.emit_only and args.verify_only:
        print("FAIL: --emit-only and --verify-only are mutually exclusive",
              file=sys.stderr)
        return 2
    run_pascal = not (args.emit_only or args.verify_only)
    if run_pascal:
        if not args.pascal:
            print("FAIL: --pascal is required unless --emit-only/--verify-only",
                  file=sys.stderr)
            return 2
        if not os.path.exists(args.pascal):
            print("FAIL: pascal binary not found: %s" % args.pascal,
                  file=sys.stderr)
            return 1

    pb = generate_module(os.path.join(args.work, "py"))

    cases_dir = os.path.join(args.work, "cases")
    rt_dir = os.path.join(args.work, "roundtrip")

    # (prefix, pb class, cases). The prefix is what the Pascal side dispatches
    # on to pick a message type. Rebuilt in every phase, including verify —
    # the originals are derived from this file, never read back from disk.
    groups = [
        ("s", pb.Scalars,   build_scalar_cases(pb)),
        ("c", pb.Composite, build_composite_cases(pb)),
    ]

    if not args.verify_only:
        # Wiped, not merged: a leftover roundtrip file from a previous run
        # would be verified as though this run had produced it.
        for d in (cases_dir, rt_dir):
            shutil.rmtree(d, ignore_errors=True)
            os.makedirs(d)

        total = 0
        for prefix, _cls, cases in groups:
            for i, (_name, msg) in enumerate(cases):
                fn = "%s-%03d.bin" % (prefix, i)
                with open(os.path.join(cases_dir, fn), "wb") as f:
                    f.write(msg.SerializeToString())
                total += 1

        print("cases written: %d (scalars %d, composite %d)"
              % (total, len(groups[0][2]), len(groups[1][2])))

    if args.emit_only:
        print("cases dir:     %s" % cases_dir)
        print("roundtrip dir: %s   (empty - run the Pascal binary next)"
              % rt_dir)
        print()
        print("Next, on the machine under test:")
        print("  Nghttp2InteropCodec <cases-dir> <roundtrip-dir>")
        print("Then verify with:")
        print("  %s %s --verify-only --work %s"
              % (os.path.basename(sys.executable), sys.argv[0], args.work))
        return 0

    if run_pascal:
        print("running: %s" % args.pascal)
        proc = subprocess.run([args.pascal, cases_dir, rt_dir],
                              capture_output=True, text=True)
        if proc.stdout.strip():
            for line in proc.stdout.strip().splitlines():
                print("  | " + line)
        if proc.returncode != 0:
            print("FAIL: pascal round-trip exited %d" % proc.returncode,
                  file=sys.stderr)
            if proc.stderr.strip():
                print(proc.stderr, file=sys.stderr)
            return 1
    else:
        # verify-only: the roundtrip dir must already hold output from a run
        # elsewhere. An empty or missing dir is a setup error, not a pass.
        if not os.path.isdir(rt_dir):
            print("FAIL: roundtrip dir does not exist: %s" % rt_dir,
                  file=sys.stderr)
            return 2
        if not [f for f in os.listdir(rt_dir) if f.endswith(".bin")]:
            print("FAIL: roundtrip dir holds no .bin files: %s" % rt_dir,
                  file=sys.stderr)
            print("      Run the Pascal binary against the cases dir first.",
                  file=sys.stderr)
            return 2
        print("verifying existing roundtrip output in: %s" % rt_dir)

    passed = failed = 0
    for prefix, cls, cases in groups:
        print()
        print("  -- %s --" % cls.DESCRIPTOR.name)
        for i, (name, original) in enumerate(cases):
            fn = "%s-%03d.bin" % (prefix, i)
            path = os.path.join(rt_dir, fn)
            if not os.path.exists(path):
                print("  FAIL  %-22s no round-trip output" % name)
                failed += 1
                continue
            with open(path, "rb") as f:
                raw = f.read()
            got = cls()
            try:
                got.ParseFromString(raw)
            except Exception as exc:                   # noqa: BLE001
                print("  FAIL  %-22s reference decoder rejected our bytes: %s"
                      % (name, exc))
                failed += 1
                continue

            diffs = diff_messages(cls, original, got)
            if diffs:
                print("  FAIL  %-22s %s" % (name, "; ".join(diffs)))
                failed += 1
            else:
                print("  PASS  %-22s" % name)
                passed += 1

    print()
    print("Result: %d passed, %d failed" % (passed, failed))
    if failed:
        print("A mismatch here is a REAL interop defect: an independent")
        print("implementation disagrees about what our bytes mean.")
        return 1
    print("Every boundary value survived the round trip through an")
    print("independent protobuf implementation.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
