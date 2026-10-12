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


def respond(conn, stream_id, path):
    if path == '/trailers-only':
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
                respond(conn, event.stream_id, path)
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
