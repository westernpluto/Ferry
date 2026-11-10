#!/usr/bin/env bash
# Creates the TLS certificate the app's built-in HTTPS server needs.
#
# Output (in ./local-cert by default):
#   rootCA.mobileconfig  Install on the iPhone (AirDrop/Files/Mail), then enable full
#                        trust in Settings > General > About > Certificate Trust Settings.
#   server.p12           Import in the app (Settings > Import .p12 certificate).
#   rootCA.key           Keep private. Anyone with it can impersonate HTTPS sites on a
#                        device that trusts this root. Delete it if you don't need to
#                        issue more certificates.
#
# Usage: scripts/make-local-cert.sh [output-dir] [p12-password]
set -euo pipefail

OUT="${1:-local-cert}"
PASSWORD="${2:-ferry}"
mkdir -p "$OUT"
cd "$OUT"

# The root is limited (name constraints) to the loopback names so it can't be used for other sites.
cat > root.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no
[dn]
CN = Ferry Local Root
O = Ferry
[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
nameConstraints = critical, permitted;DNS:localhost, permitted;IP:127.0.0.1/255.255.255.255, permitted;IP:0:0:0:0:0:0:0:1/FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF
EOF

cat > server.cnf <<'EOF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = localhost
O = Ferry
[v3_server]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost, IP:127.0.0.1, IP:::1
authorityKeyIdentifier = keyid
subjectKeyIdentifier = hash
EOF

openssl req -x509 -new -nodes -newkey rsa:2048 -sha256 -days 3650 \
  -keyout rootCA.key -out rootCA.pem -config root.cnf

openssl req -new -nodes -newkey rsa:2048 -sha256 \
  -keyout server.key -out server.csr -config server.cnf

# iOS rejects TLS server certificates valid for more than 825 days.
openssl x509 -req -in server.csr -CA rootCA.pem -CAkey rootCA.key -CAcreateserial \
  -out server.pem -days 800 -sha256 -extfile server.cnf -extensions v3_server

# iOS's PKCS#12 importer needs the older SHA1/3DES encryption.
openssl pkcs12 -export -out server.p12 -inkey server.key -in server.pem -certfile rootCA.pem \
  -name "Ferry Local Server" -passout "pass:$PASSWORD" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

# Configuration profile that installs the root certificate.
ROOT_B64="$(openssl x509 -in rootCA.pem -outform der | base64 | tr -d '\n')"
uuid() { python3 -c 'import uuid; print(str(uuid.uuid4()).upper())'; }
cat > rootCA.mobileconfig <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadCertificateFileName</key><string>rootCA.cer</string>
      <key>PayloadContent</key><data>${ROOT_B64}</data>
      <key>PayloadDisplayName</key><string>Ferry Local Root</string>
      <key>PayloadIdentifier</key><string>com.example.Ferry.root.$(uuid)</string>
      <key>PayloadType</key><string>com.apple.security.root</string>
      <key>PayloadUUID</key><string>$(uuid)</string>
      <key>PayloadVersion</key><integer>1</integer>
    </dict>
  </array>
  <key>PayloadDescription</key><string>Lets Ferry serve apps over HTTPS on this iPhone (localhost only).</string>
  <key>PayloadDisplayName</key><string>Ferry Local Root</string>
  <key>PayloadIdentifier</key><string>com.example.Ferry.profile.$(uuid)</string>
  <key>PayloadType</key><string>Configuration</string>
  <key>PayloadUUID</key><string>$(uuid)</string>
  <key>PayloadVersion</key><integer>1</integer>
</dict>
</plist>
EOF

rm -f server.csr rootCA.srl root.cnf server.cnf
echo
echo "Created in $(pwd):"
echo "  rootCA.mobileconfig  -> install on the iPhone, then enable full trust"
echo "  server.p12           -> import in the app (password: $PASSWORD)"
