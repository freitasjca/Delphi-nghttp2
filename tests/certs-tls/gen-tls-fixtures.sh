#!/usr/bin/env bash
# Regenerates the GC2b fixtures (tests/Nghttp2GrpcUnaryClient.dpr, Parts D/E):
# a tiny PKI for SERVER-CERTIFICATE VERIFICATION on the client side, plus mTLS.
#
#   ca.crt                 the test CA the client is told to trust
#   server.crt/.key        signed by ca, SAN = localhost, 127.0.0.1, ::1
#   wrongname.crt/.key     signed by the SAME ca, SAN = DNS:wrong-name.invalid
#                          only - a perfectly valid chain for the wrong peer, so
#                          the ONLY thing that can reject it is the hostname /
#                          IP check (X509_V_ERR 62 by name, 64 by IP literal)
#   client.crt/.key        signed by ca, EKU clientAuth - for mTLS
#
# The CA key is deleted: nothing else may ever be signed by this CA, and no
# test needs it. EC P-256 keys, 100-year validity (a short-lived fixture once
# manufactured a fake regression - see certs-keypw). TEST-ONLY credentials.
#
# The "untrusted" fixtures the tests also use are NOT here on purpose: an
# unrelated self-signed cert + key already exists in ../certs-keypw/
# (cert.pem + key-plain.pem), which is exactly "a CA that did not sign this
# server" and "a client cert this server's CA did not sign".
set -euo pipefail
cd "$(dirname "$0")"

DAYS=36500
key() { openssl ecparam -name prime256v1 -genkey -noout | openssl pkey -out "$1"; }

key ca.key
openssl req -new -x509 -key ca.key -days "$DAYS" -sha256 \
  -subj "/O=Delphi-nghttp2 test/CN=Delphi-nghttp2 GC2b Test CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" -out ca.crt

leaf() {  # name  subject-CN  extfile-body
  key "$1.key"
  openssl req -new -key "$1.key" -subj "/O=Delphi-nghttp2 test/CN=$2" -out "$1.csr"
  printf '%s\n' "$3" > "$1.ext"
  openssl x509 -req -in "$1.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days "$DAYS" -sha256 -extfile "$1.ext" -out "$1.crt"
  rm -f "$1.csr" "$1.ext"
}

leaf server localhost "basicConstraints=CA:FALSE
keyUsage=digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1"

leaf wrongname wrong-name.invalid "basicConstraints=CA:FALSE
keyUsage=digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:wrong-name.invalid"

leaf client gc2b-test-client "basicConstraints=CA:FALSE
keyUsage=digitalSignature
extendedKeyUsage=clientAuth"

rm -f ca.key ca.srl
openssl verify -CAfile ca.crt server.crt wrongname.crt client.crt
