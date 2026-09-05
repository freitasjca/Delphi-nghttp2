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
            google.protobuf reference implementation      -> cases/NNN.bin
    Pascal  reads each case, DECODES it, RE-ENCODES it     -> roundtrip/NNN.bin
    Python  decodes the round-tripped bytes and compares FIELD VALUES against
            the originals

Values are compared, not bytes, and that is deliberate. Our encoder emits
default-valued scalars (the `DEVIATES` rows in the conformance probe) where
canonical proto3 omits them. That is non-canonical but perfectly decodable —
a peer reads the same value either way. Comparing bytes would fail on a known,
benign difference and hide the real question, which is whether any VALUE
changes crossing the boundary.

USAGE
-----
    python3 interop_check.py --pascal <path-to-Nghttp2InteropCodec>

Exit code 0 = every case round-tripped with identical values.
"""

import argparse
import os
import shutil
import struct
import subprocess
import sys

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


def build_cases(pb):
    """The boundary values. Each entry is (name, message)."""
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pascal", required=True,
                    help="path to the compiled Nghttp2InteropCodec binary")
    ap.add_argument("--work", default=os.path.join(HERE, ".interop-out"))
    args = ap.parse_args()

    if not os.path.exists(args.pascal):
        print("FAIL: pascal binary not found: %s" % args.pascal, file=sys.stderr)
        return 1

    pb = generate_module(os.path.join(args.work, "py"))

    cases_dir = os.path.join(args.work, "cases")
    rt_dir = os.path.join(args.work, "roundtrip")
    # Wiped, not merged: a leftover roundtrip file from a previous run would be
    # verified as though this run had produced it.
    for d in (cases_dir, rt_dir):
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)

    cases = build_cases(pb)
    for i, (name, msg) in enumerate(cases):
        with open(os.path.join(cases_dir, "%03d.bin" % i), "wb") as f:
            f.write(msg.SerializeToString())

    print("cases written: %d" % len(cases))
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

    passed = failed = 0
    for i, (name, original) in enumerate(cases):
        path = os.path.join(rt_dir, "%03d.bin" % i)
        if not os.path.exists(path):
            print("  FAIL  %-16s no round-trip output" % name)
            failed += 1
            continue
        with open(path, "rb") as f:
            raw = f.read()
        got = pb.Scalars()
        try:
            got.ParseFromString(raw)
        except Exception as exc:                       # noqa: BLE001
            print("  FAIL  %-16s reference decoder rejected our bytes: %s"
                  % (name, exc))
            failed += 1
            continue

        # Field-by-field so the report names the field, not just the message.
        diffs = []
        for fd in pb.Scalars.DESCRIPTOR.fields:
            a = getattr(original, fd.name)
            b = getattr(got, fd.name)
            if a != b:
                diffs.append("%s: sent %r, got back %r" % (fd.name, a, b))
        if diffs:
            print("  FAIL  %-16s %s" % (name, "; ".join(diffs)))
            failed += 1
        else:
            print("  PASS  %-16s" % name)
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
