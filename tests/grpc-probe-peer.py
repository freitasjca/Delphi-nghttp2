#!/usr/bin/env python3
"""grpc-probe-peer.py - GC2 independent gRPC server for Nghttp2GrpcUnaryClient.

Serves gctest.Probe (tests/gctest.proto) with python grpcio: a second,
independent implementation of gRPC framing, status trailers, grpc-message
percent-encoding and the protobuf codec. A bug shared by our client and our
server is invisible to a test that uses both; it is visible here.

The stubs are generated at start-up with grpc_tools.protoc into a temporary
directory, so nothing generated is committed.

GC2b adds TLS: with --certs DIR (tests/certs-tls), the SAME servicer is also
served over TLS on --tls PORT (server.crt) and over mutual TLS on --mtls PORT
(server.crt, client certificate REQUIRED and checked against ca.crt). grpcio's
TLS stack (BoringSSL) is independent of the OpenSSL our client uses.

Needs: grpcio + grpcio-tools (the protogen oracle venv already has both).
Usage: grpc-probe-peer.py PORT [--lifetime SECONDS]
                               [--certs DIR --tls PORT --mtls PORT]
Prints "READY <port>" once serving; exits after --lifetime seconds.
"""
import os
import sys
import tempfile
from concurrent import futures

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
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    port = int(sys.argv[1])
    def opt(name, default=None):
        if name in sys.argv:
            return sys.argv[sys.argv.index(name) + 1]
        return default

    lifetime = float(opt('--lifetime', 60.0))
    certs = opt('--certs')
    tls_port = int(opt('--tls', 0))
    mtls_port = int(opt('--mtls', 0))

    pb2, pb2_grpc = load_stubs()

    class Probe(pb2_grpc.ProbeServicer):
        def Echo(self, request, context):
            return pb2.EchoReply(text='echo:' + request.text, num=request.num + 1)

        def Fail(self, request, context):
            code = next((c for c in grpc.StatusCode if c.value[0] == request.code),
                        grpc.StatusCode.UNKNOWN)
            context.abort(code, request.message)

        def Empty(self, request, context):
            return pb2.EchoReply()

    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
    pb2_grpc.add_ProbeServicer_to_server(Probe(), server)
    server.add_insecure_port('127.0.0.1:%d' % port)
    if certs and (tls_port or mtls_port):
        def read(name):
            with open(os.path.join(certs, name), 'rb') as f:
                return f.read()
        pair = [(read('server.key'), read('server.crt'))]
        if tls_port:
            server.add_secure_port('127.0.0.1:%d' % tls_port,
                                   grpc.ssl_server_credentials(pair))
        if mtls_port:
            server.add_secure_port('127.0.0.1:%d' % mtls_port,
                                   grpc.ssl_server_credentials(
                                       pair, root_certificates=read('ca.crt'),
                                       require_client_auth=True))
    server.start()
    print('READY %d' % port, flush=True)
    server.wait_for_termination(timeout=lifetime)
    server.stop(0)
    return 0


if __name__ == '__main__':
    sys.exit(main())
