#!/usr/bin/env python3
"""client-failure-peer.py - CL5.5 adverse HTTP/2 peer for Nghttp2ClientFailure.

TNghttp2Server is well-behaved, so it cannot produce the failure shapes a
client-reliability suite has to test. This peer injects them, keyed by the
request :path:

  /ok          HEADERS 200 + DATA "ok" + END_STREAM     (control: the peer works)
  /rst         HEADERS 200, then RST_STREAM(INTERNAL_ERROR) - the stream is reset
               after the response starts but before it finishes
  /goaway      GOAWAY(last_stream_id=0), then the socket closes - the server
               declares it processed NO stream, so the request is safe to replay
  /truncated   HEADERS 200 + a partial DATA frame WITHOUT END_STREAM, then the
               socket closes under the client (an incomplete body, not a clean end)
  /abrupt      nothing at all - the socket closes before any response byte

The client must, for each, raise rather than hang or return a partial success,
leave no open stream behind (PendingStreams = 0), and free cleanly.

Uses the `h2` package only (pip install h2). h2c with prior knowledge, one
connection at a time, exits after --lifetime seconds without a connection.

Usage: client-failure-peer.py PORT [--lifetime SECONDS]
Prints "READY <port>" on stdout once listening.
"""
import socket
import sys

import h2.config
import h2.connection
import h2.errors
import h2.events


def respond(conn, stream_id, path):
    # Returns True to keep the connection open, False to close it now.
    if path == '/ok':
        conn.send_headers(stream_id, [(':status', '200'),
                                      ('content-type', 'text/plain')])
        conn.send_data(stream_id, b'ok', end_stream=True)
        return True
    if path == '/rst':
        conn.send_headers(stream_id, [(':status', '200'),
                                      ('content-type', 'text/plain')])
        conn.reset_stream(stream_id,
                          error_code=h2.errors.ErrorCodes.INTERNAL_ERROR)
        return True
    if path == '/goaway':
        # last_stream_id 0 => no stream was processed; the client's request is
        # safe to replay on a fresh connection.
        conn.close_connection(error_code=h2.errors.ErrorCodes.NO_ERROR,
                              last_stream_id=0)
        return False
    if path == '/truncated':
        conn.send_headers(stream_id, [(':status', '200'),
                                      ('content-type', 'text/plain')])
        # No END_STREAM: more is promised, but the socket closes below.
        conn.send_data(stream_id, b'partial', end_stream=False)
        return False
    # /abrupt (and anything else): send nothing, close immediately.
    return False


def serve(sock):
    config = h2.config.H2Configuration(client_side=False, header_encoding='utf-8')
    conn = h2.connection.H2Connection(config=config)
    conn.initiate_connection()
    sock.sendall(conn.data_to_send())
    while True:
        data = sock.recv(65535)
        if not data:
            return
        keep = True
        for event in conn.receive_data(data):
            if isinstance(event, h2.events.RequestReceived):
                path = dict(event.headers).get(':path', '')
                keep = respond(conn, event.stream_id, path)
            elif isinstance(event, h2.events.ConnectionTerminated):
                return
        out = conn.data_to_send()
        if out:
            sock.sendall(out)
        if not keep:
            return


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
