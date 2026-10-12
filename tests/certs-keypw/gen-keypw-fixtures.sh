#!/usr/bin/env bash
# Regenerates the KEYPW-1 fixtures (tests/Nghttp2KeyPassword.dpr). One EC P-256
# key, one self-signed cert valid for 100 years (a short-lived fixture once
# manufactured a fake regression), and the SAME key in four forms:
#   key-plain.pem         unencrypted
#   key-pkcs8-ascii.pem   PKCS#8 / PBES2 AES-256-CBC, password "horse-keypw-1"
#   key-trad-ascii.pem    traditional PEM (Proc-Type 4,ENCRYPTED), same password
#   key-pkcs8-utf8.pem    PKCS#8 AES-256-CBC, password "pässwörd" as UTF-8 bytes
# The UTF-8 password is written from explicit bytes, so the shell's locale
# cannot change what was used.
set -euo pipefail
cd "$(dirname "$0")"
openssl ecparam -name prime256v1 -genkey -noout -out key-raw.pem
openssl pkey -in key-raw.pem -out key-plain.pem
openssl req -new -x509 -key key-plain.pem -out cert.pem -days 36500 -subj "/CN=localhost"
printf 'horse-keypw-1' > pw-ascii.bin
printf 'p\xc3\xa4ssw\xc3\xb6rd' > pw-utf8.bin
openssl pkey -in key-plain.pem -aes256 -passout file:pw-ascii.bin -out key-pkcs8-ascii.pem
openssl pkey -in key-plain.pem -aes256 -passout file:pw-ascii.bin -traditional -out key-trad-ascii.pem
openssl pkey -in key-plain.pem -aes256 -passout file:pw-utf8.bin  -out key-pkcs8-utf8.pem
rm -f key-raw.pem pw-ascii.bin pw-utf8.bin
