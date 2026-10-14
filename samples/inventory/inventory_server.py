#!/usr/bin/env python3
"""inventory_server.py - inventory.proto served by python grpcio.

The same warehouse service as Nghttp2InventoryServer.dpr, written against the
same inventory.proto, in an implementation that shares none of Delphi-nghttp2's
code: its own HTTP/2 stack, its own gRPC framing, its own protobuf codec.
Nghttp2InventoryClient passing against THIS server shows the Pascal client
follows the protocol, not merely the habits of its own server - a bug shared
by our client and our server is invisible to a test that uses both.

Same catalogue, same answers: GetProduct reports a miss as found=False,
CreateShipment numbers shipments from 9001, WatchStock sends five updates
counting the stock down to 0 (and nothing for an unknown barcode).

The stubs are generated at start-up with grpc_tools.protoc into a temporary
directory, so nothing generated is committed.

Needs: grpcio + grpcio-tools (the protogen venv in tools/protogen has both).
Usage: inventory_server.py [PORT] [--lifetime SECONDS] [--interval SECONDS]
Prints "READY <port>" once serving; exits after --lifetime seconds.
"""
import os
import sys
import tempfile
import threading
import time
from concurrent import futures

import grpc
from grpc_tools import protoc

CATALOGUE = [
    (1001, 'ABC123', 'Mechanical keyboard', 17),
    (1002, 'ABC456', 'Laser mouse', 4),
    (1003, 'XYZ001', '27-inch monitor', 0),
    (1004, 'XYZ002', 'USB-C dock', 42),
]


def load_stubs():
    here = os.path.dirname(os.path.abspath(__file__))
    out = tempfile.mkdtemp(prefix='inventory-')
    rc = protoc.main([
        'protoc', '-I' + here,
        '--python_out=' + out, '--grpc_python_out=' + out,
        os.path.join(here, 'inventory.proto'),
    ])
    if rc != 0:
        raise SystemExit('grpc_tools.protoc failed with %d' % rc)
    sys.path.insert(0, out)
    import inventory_pb2
    import inventory_pb2_grpc
    return inventory_pb2, inventory_pb2_grpc


def find(barcode):
    for entry in CATALOGUE:
        if entry[1].lower() == barcode.lower():
            return entry
    return None


def main():
    args = [a for a in sys.argv[1:]]

    def opt(name, default):
        if name in args:
            i = args.index(name)
            value = args[i + 1]
            del args[i:i + 2]
            return value
        return default

    lifetime = float(opt('--lifetime', 60.0))
    interval = float(opt('--interval', 0.4))
    port = int(args[0]) if args else 19010

    pb2, pb2_grpc = load_stubs()
    lock = threading.Lock()
    seq = [0]

    class Inventory(pb2_grpc.InventoryServiceServicer):
        def GetProduct(self, request, context):
            entry = find(request.barcode)
            if entry is None:
                return pb2.GetProductResponse(found=False)
            pid, barcode, name, stock = entry
            return pb2.GetProductResponse(
                found=True,
                product=pb2.Product(id=pid, barcode=barcode, name=name, stock=stock))

        def CreateShipment(self, request, context):
            with lock:
                seq[0] += 1
                shipment = 9000 + seq[0]
            return pb2.CreateShipmentResponse(
                shipment_id=shipment, line_count=len(request.product_ids))

        def WatchStock(self, request, context):
            entry = find(request.barcode)
            if entry is None:
                return
            pid, barcode, name, stock = entry
            for _ in range(5):
                if not context.is_active():
                    return
                yield pb2.Product(id=pid, barcode=barcode, name=name, stock=stock)
                if stock > 0:
                    stock -= 1
                time.sleep(interval)

    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
    pb2_grpc.add_InventoryServiceServicer_to_server(Inventory(), server)
    server.add_insecure_port('127.0.0.1:%d' % port)
    server.start()
    print('READY %d' % port, flush=True)
    server.wait_for_termination(timeout=lifetime)
    server.stop(0)
    return 0


if __name__ == '__main__':
    sys.exit(main())
