#!/usr/bin/env python3
"""grpc-meta-client.py - CL5.6 independent grpcio CLIENT for the server-side
call context.

Connects to OUR Delphi-hosted gctest.Probe server (the serve-meta mode of
Nghttp2GrpcUnaryClient) over h2c, sends an application metadata header
x-echo-key=<uid>, calls Meta, and checks that the server read it back through
TGrpcCallContext.Current:

    reply.text must equal <uid>        - the metadata reached the handler
    reply.num  must be 1               - the server's decision-3 filter flag:
                                         reserved headers hidden, app header +
                                         Path visible

Part A (our client -> our server) already proves the context in-process; a bug
shared by our client and our server is invisible there. This foreign client,
whose HTTP/2 framing and metadata encoding share none of our code, makes the
server's header parsing visible.

Exits 0 on a full match, 1 on a mismatch, 2 on any connect/RPC failure, so the
parent harness gates on the exit code. The stubs are generated at start-up with
grpc_tools.protoc from gctest.proto; nothing generated is committed.

Usage: grpc-meta-client.py PORT UID
Needs: grpcio + grpcio-tools (the protogen oracle venv has both).
"""
import os
import sys
import tempfile

import grpc
from grpc_tools import protoc


def load_stubs():
    here = os.path.dirname(os.path.abspath(__file__))
    out = tempfile.mkdtemp(prefix='gctest-')
    rc = protoc.main([
        'protoc', '-I' + here,
        '--python_out=' + out, '--grpc_python_out=' + out,
        os.path.join(here, 'gctest.proto'),
    ])
    if rc != 0:
        raise SystemExit('grpc_tools.protoc failed with %d' % rc)
    sys.path.insert(0, out)
    import gctest_pb2
    import gctest_pb2_grpc
    return gctest_pb2, gctest_pb2_grpc


def main():
    if len(sys.argv) < 3:
        sys.stderr.write('usage: grpc-meta-client.py PORT UID\n')
        return 2
    port = int(sys.argv[1])
    uid = sys.argv[2]

    pb2, pb2_grpc = load_stubs()

    channel = grpc.insecure_channel('127.0.0.1:%d' % port)
    try:
        try:
            grpc.channel_ready_future(channel).result(timeout=10)
        except grpc.FutureTimeoutError:
            sys.stderr.write('connect to 127.0.0.1:%d timed out\n' % port)
            return 2
        stub = pb2_grpc.ProbeStub(channel)
        try:
            reply = stub.Meta(pb2.EchoRequest(text='', num=0),
                              metadata=(('x-echo-key', uid),),
                              timeout=10)
        except grpc.RpcError as e:
            sys.stderr.write('Meta RPC failed: %s %s\n' % (e.code(), e.details()))
            return 2
    finally:
        channel.close()

    ok = True
    if reply.text != uid:
        sys.stderr.write('mismatch: server echoed text=%r, expected %r\n'
                         % (reply.text, uid))
        ok = False
    if reply.num != 1:
        sys.stderr.write('filter flag num=%d, expected 1 '
                         '(a reserved header leaked, or the app header / Path was missing)\n'
                         % reply.num)
        ok = False
    if ok:
        print('OK x-echo-key=%s echoed, decision-3 filter held' % uid)
        return 0
    return 1


if __name__ == '__main__':
    sys.exit(main())
