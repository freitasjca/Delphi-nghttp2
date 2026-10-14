#!/usr/bin/env python3
"""client-trailers-peer.py - GC1 independent HTTP/2 peer for Nghttp2ClientTrailers.

Why a second server: TNghttp2Server always answers with a data provider, so
even an empty body goes out as HEADERS + an empty DATA(END_STREAM). It can
never produce the response shapes the GC1 client change has to tell apart:

  /trailers-only   ONE HEADERS block with END_STREAM (gRPC "Trailers-Only":
                   grpc-status sits in the response headers, there is no body
                   and no trailer section)
  /informational   a 1xx HEADERS block, then the final headers, DATA and a
                   trailer section - the 1xx must not make the final headers
                   look like trailers
  /trailers        HEADERS, DATA, trailer HEADERS(END_STREAM), framed by a
                   different implementation than ours
  /empty-data      HEADERS, then an empty DATA(END_STREAM): no body, no
                   trailers, and NOT headers-only (the control for the first)

GC2 adds /gctest.Raw/* - gRPC replies a real gRPC server never sends, for
Nghttp2GrpcUnaryClient part C: each must become a specific gRPC status, never
a decoded "success". The message bytes are EchoReply{text: "raw"}.

  EchoHeaders   GC3: a VALID reply whose text is the request's grpc-timeout and
                x-* headers exactly as they arrived (not an error case)
  NoStatus      body + trailers without grpc-status          -> 13
  TwoMessages   two framed messages + status 0               -> 13
  Compressed    compressed flag set, no grpc-encoding        -> 13
  NotGrpc       HTTP 200, content-type text/html             -> 13
  Http503       HTTP 503, no gRPC fields at all              -> 14
  OkNoMessage   status 0 in trailers, no DATA payload        -> 13
  TrailersOnlyOk  headers-only with grpc-status 0 (no message) -> 13
  BadStatus     grpc-status: abc                             -> 2
  Truncated     header says 10 bytes, 3 present, status 0    -> 13

Uses the `h2` package only (pip install h2). h2c with prior knowledge, one
connection at a time, exits after --lifetime seconds without a connection.

Usage: client-trailers-peer.py PORT [--lifetime SECONDS]
Prints "READY <port>" on stdout once listening.
"""
import socket
import sys

import h2.config
import h2.connection
import h2.events


RAW_MSG = b'\x0a\x03raw'          # EchoReply{text: "raw"}
GRPC_CT = ('content-type', 'application/grpc')


def frame(payload, flag=0):
    return bytes([flag]) + len(payload).to_bytes(4, 'big') + payload


def string_reply(text):
    # EchoReply{text: <text>} - field 1, wire type 2, one-byte varint length
    data = text.encode('utf-8')
    assert len(data) < 128
    return b'\x0a' + bytes([len(data)]) + data


def respond_raw(conn, stream_id, name, headers=()):
    if name == 'EchoHeaders':
        # GC3: the request headers exactly as they arrived on the wire -
        # grpc-timeout (or "-") then the x-* metadata, sorted.
        hdrs = dict(headers)
        xs = sorted((k, v) for k, v in headers if k.startswith('x-'))
        text = 'grpc-timeout=%s|%s' % (hdrs.get('grpc-timeout', '-'),
                                       ';'.join('%s=%s' % kv for kv in xs))
        conn.send_headers(stream_id, [(':status', '200'), GRPC_CT])
        conn.send_data(stream_id, frame(string_reply(text)))
        conn.send_headers(stream_id, [('grpc-status', '0')], end_stream=True)
        return
    if name == 'Http503':
        conn.send_headers(stream_id, [(':status', '503')], end_stream=True)
        return
    if name == 'NotGrpc':
        conn.send_headers(stream_id, [(':status', '200'), ('content-type', 'text/html')])
        conn.send_data(stream_id, b'<html>not grpc</html>', end_stream=True)
        return
    if name == 'TrailersOnlyOk':
        conn.send_headers(stream_id, [(':status', '200'), GRPC_CT, ('grpc-status', '0')],
                          end_stream=True)
        return
    conn.send_headers(stream_id, [(':status', '200'), GRPC_CT])
    trailers = [('grpc-status', '0')]
    if name == 'NoStatus':
        conn.send_data(stream_id, frame(RAW_MSG))
        trailers = [('x-not-a-status', '1')]
    elif name == 'TwoMessages':
        conn.send_data(stream_id, frame(RAW_MSG) + frame(RAW_MSG))
    elif name == 'Compressed':
        conn.send_data(stream_id, frame(RAW_MSG, flag=1))
    elif name == 'OkNoMessage':
        conn.send_data(stream_id, b'')
    elif name == 'BadStatus':
        conn.send_data(stream_id, frame(RAW_MSG))
        trailers = [('grpc-status', 'abc')]
    elif name == 'Truncated':
        conn.send_data(stream_id, bytes([0, 0, 0, 0, 10]) + RAW_MSG[:3])
    else:
        trailers = [('grpc-status', '12'), ('grpc-message', 'no%20such%20raw%20route')]
    conn.send_headers(stream_id, trailers, end_stream=True)


def respond(conn, stream_id, path, headers=()):
    if path.startswith('/gctest.Raw/'):
        respond_raw(conn, stream_id, path[len('/gctest.Raw/'):], headers)
    elif path == '/trailers-only':
        conn.send_headers(stream_id, [
            (':status', '200'),
            ('content-type', 'application/grpc'),
            ('grpc-status', '12'),
            ('grpc-message', 'not%20here'),
        ], end_stream=True)
    elif path == '/informational':
        conn.send_headers(stream_id, [(':status', '103'), ('x-early', 'hint')])
        conn.send_headers(stream_id, [(':status', '200'), ('x-final', 'yes')])
        conn.send_data(stream_id, b'ok')
        conn.send_headers(stream_id, [('x-trailer', 't')], end_stream=True)
    elif path == '/trailers':
        conn.send_headers(stream_id, [
            (':status', '200'),
            ('content-type', 'application/grpc'),
        ])
        conn.send_data(stream_id, b'body')
        conn.send_headers(stream_id, [
            ('grpc-status', '0'),
            ('grpc-message', 'done'),
        ], end_stream=True)
    elif path == '/empty-data':
        conn.send_headers(stream_id, [(':status', '200'), ('x-shape', 'empty-data')])
        conn.send_data(stream_id, b'', end_stream=True)
    else:
        conn.send_headers(stream_id, [(':status', '404')], end_stream=True)


def serve(sock):
    config = h2.config.H2Configuration(client_side=False, header_encoding='utf-8')
    conn = h2.connection.H2Connection(config=config)
    conn.initiate_connection()
    sock.sendall(conn.data_to_send())
    while True:
        data = sock.recv(65535)
        if not data:
            return
        for event in conn.receive_data(data):
            if isinstance(event, h2.events.RequestReceived):
                path = dict(event.headers).get(':path', '')
                respond(conn, event.stream_id, path, event.headers)
            elif isinstance(event, h2.events.ConnectionTerminated):
                out = conn.data_to_send()
                if out:
                    sock.sendall(out)
                return
        out = conn.data_to_send()
        if out:
            sock.sendall(out)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    port = int(sys.argv[1])
    lifetime = 60.0
    if '--lifetime' in sys.argv:
        lifetime = float(sys.argv[sys.argv.index('--lifetime') + 1])

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(('127.0.0.1', port))
    listener.listen(5)
    listener.settimeout(lifetime)
    print('READY %d' % port, flush=True)
    while True:
        try:
            sock, _ = listener.accept()
        except socket.timeout:
            return 0
        sock.settimeout(lifetime)
        try:
            serve(sock)
        except (OSError, socket.timeout):
            pass
        finally:
            sock.close()


if __name__ == '__main__':
    sys.exit(main())
