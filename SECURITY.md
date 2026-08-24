# Security Policy

## Reporting a vulnerability

**Please report privately, not as a public issue.**

Use GitHub's private reporting: the **Security** tab → **Report a vulnerability**.
That opens a private thread visible only to the maintainers, so a fix can be prepared
before the details are public.

If that is unavailable to you for any reason, open a public issue saying only that you
have a security report and asking for a contact — no details — and you will be given
one.

## What to expect

This is a small project maintained by one person. There is no service-level agreement,
and there will not be a same-day response.

What is promised instead:

- Your report will be read and acknowledged.
- If it is a real issue, it will be fixed and released, and you will be credited in the
  release notes unless you ask otherwise.
- If it is not, you will be told why rather than ignored.
- You will not be asked to keep quiet indefinitely. If a fix is taking long, we agree a
  disclosure date together.

## Scope — what this library actually does

`Delphi-nghttp2` parses **input controlled by whoever connects to your server**:

- HTTP/2 frames, headers and HPACK state, via libnghttp2
- The gRPC 5-byte message framing
- protobuf wire data, in `Nghttp2.Protobuf` and `Nghttp2.Protobuf.Rtti`
- TLS records, when a TLS context is configured

Anything reachable from that input is in scope, and memory-safety issues there are the
highest priority. Out-of-bounds reads or writes, allocations driven by attacker-supplied
lengths, unbounded recursion, and infinite loops are all worth reporting.

Denial of service via sheer request volume is **not** in scope — that is a deployment
concern, and `MaxConnections`, the bounded worker queue and `GRPC_MAX_MESSAGE_BYTES`
exist for it.

## Supported versions

Only the **latest release** receives security fixes. The project moves quickly and there
are no long-term support branches. Upgrading within a major version has so far never
required source changes.

| Version | Supported |
|---|---|
| 1.8.x | Yes |
| < 1.8.0 | No — 1.8.0 fixed two memory-safety defects in the protobuf and gRPC parsers |

## Known history

**1.8.0 (2026-08-24)** fixed five malformed-input defects, two of them memory-safety.
The most serious let a six-byte gRPC request cause a 2 GB out-of-bounds heap read: a
corrupt 4-byte length prefix was cast through `Integer`, which defeated the truncation
guard, and the subsequent copy ran past the end of the buffer.

If you are running anything earlier than 1.8.0 and serving gRPC on a network you do not
control, upgrade.

`tests/Nghttp2ProtobufNegativeTests.dpr` pins all five against regression.
