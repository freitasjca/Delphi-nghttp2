#!/usr/bin/env python3
"""client-failure-peer.py - CL5.5 adverse HTTP/2 peer for Nghttp2ClientFailure.

TNghttp2Server is well-behaved, so it cannot produce the failure shapes a
client-reliability suite has to test. This peer injects them, keyed by the
request :path:

  /ok          HEADERS 200 + DATA "ok" + END_STREAM     (control: the peer works)
  /rst         HEADERS 200, then RST_STREAM(INTERNAL_ERROR) - the stream is reset
               after the response starts but before it finishes
  /refused     RST_STREAM(REFUSED_STREAM) with no prior response - the server
               declares it never processed the stream (RFC 7540 8.1.4: safe to retry)
  /goaway      GOAWAY(last_stream_id=0), then a GRACEFUL close (FIN + drain, so
               the GOAWAY is delivered before any close) - the server declares it
               processed NO stream, so the request is safe to replay
  /truncated   HEADERS 200 + a partial DATA frame WITHOUT END_STREAM, then the
               socket closes under the client (an incomplete body, not a clean end)
  /abrupt      nothing at all - the socket closes before any response byte
  /hang        HEADERS 200, no END_STREAM, no DATA - the stream stays open so the
               client can CancelRequest it mid-flight (CL6a). Connection kept open.
  /rststat     HEADERS 200 + DATA = the number of RST_STREAM frames this peer has
               received from the client so far (CL6a cancel confirmation on the
               wire: 0 if the client never actually sent the RST)

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


def respond(conn, stream_id, path, nreset):
    # Returns one of: 'keep' (leave the connection open), 'close' (close it now),
    # 'goaway' (flush the GOAWAY, then close GRACEFULLY - see serve()).
    # nreset is the count of RST_STREAM frames seen so far (for /rststat).
    if path == '/hang':
        # HEADERS 200 but no END_STREAM: the stream stays open for the client
        # to cancel. The connection stays open so /rststat can be asked after.
        conn.send_headers(stream_id, [(':status', '200'),
                                      ('content-type', 'text/plain')])
        return 'keep'
    if path == '/rststat':
        body = str(nreset).encode('ascii')
        conn.send_headers(stream_id, [(':status', '200'),
                                      ('content-type', 'text/plain')])
        conn.send_data(stream_id, body, end_stream=True)
        return 'keep'
    if path == '/ok':
        conn.send_headers(stream_id, [(':status', '200'),
                                      ('content-type', 'text/plain')])
        conn.send_data(stream_id, b'ok', end_stream=True)
        return 'keep'
    if path == '/rst':
        conn.send_headers(stream_id, [(':status', '200'),
                                      ('content-type', 'text/plain')])
        conn.reset_stream(stream_id,
                          error_code=h2.errors.ErrorCodes.INTERNAL_ERROR)
        return 'keep'
    if path == '/refused':
        # RST_STREAM(REFUSED_STREAM) with NO prior response: the server declares
        # it never processed this stream - RFC 7540 8.1.4 "safe to retry".
        conn.reset_stream(stream_id,
                          error_code=h2.errors.ErrorCodes.REFUSED_STREAM)
        return 'keep'
    if path == '/goaway':
        # last_stream_id 0 => no stream was processed; the client's request is
        # safe to replay on a fresh connection.
        conn.close_connection(error_code=h2.errors.ErrorCodes.NO_ERROR,
                              last_stream_id=0)
        return 'goaway'
    if path == '/truncated':
        conn.send_headers(stream_id, [(':status', '200'),
                                      ('content-type', 'text/plain')])
        # No END_STREAM: more is promised, but the socket closes below.
        conn.send_data(stream_id, b'partial', end_stream=False)
        return 'close'
    # /abrupt (and anything else): send nothing, close immediately.
    return 'close'


def serve(sock):
    config = h2.config.H2Configuration(client_side=False, header_encoding='utf-8')
    conn = h2.connection.H2Connection(config=config)
    conn.initiate_connection()
    sock.sendall(conn.data_to_send())
    nreset = 0   # [CL6a] RST_STREAM frames received from the client
    while True:
        data = sock.recv(65535)
        if not data:
            return
        action = 'keep'
        for event in conn.receive_data(data):
            if isinstance(event, h2.events.RequestReceived):
                path = dict(event.headers).get(':path', '')
                action = respond(conn, event.stream_id, path, nreset)
            elif isinstance(event, h2.events.StreamReset):
                # [CL6a] the client sent RST_STREAM (e.g. CancelRequest). Count
                # it so a later /rststat can confirm the cancel reached the wire.
                nreset += 1
            elif isinstance(event, h2.events.ConnectionTerminated):
                return
        out = conn.data_to_send()
        if out:
            sock.sendall(out)
        if action == 'goaway':
            # The GOAWAY is now on the wire. Close GRACEFULLY: send FIN after it
            # (half-close), then drain whatever the client still sends until it
            # closes. A plain close() here leaves the client's unread bytes in
            # this socket's buffer, so Windows answers with an RST that discards
            # the just-sent GOAWAY before the client reads it - and the client
            # then never sets GoAwayReceived. Draining first avoids that RST.
            try:
                sock.shutdown(socket.SHUT_WR)
                sock.settimeout(2.0)
                while sock.recv(65535):
                    pass
            except OSError:
                pass
            return
        if action != 'keep':
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
