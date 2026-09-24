#!/bin/bash
# OPTIONAL, run it yourself: creates a self-signed "Glimpse Local Signing" identity in a dedicated
# keychain so rebuilt apps keep the same signature (and keep their Screen Recording permission).
set -euo pipefail
D="$HOME/Library/Application Support/Glimpse-dev"; mkdir -p "$D"; cd "$D"
KC="$D/glimpse-signing.keychain-db"
printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Glimpse Local Signing\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > cert.cnf
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -out id.p12 -passout pass:glimpse 2>/dev/null \
  || openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:glimpse
[ -f "$KC" ] || security create-keychain -p glimpse "$KC"
security unlock-keychain -p glimpse "$KC"
security import id.p12 -k "$KC" -P glimpse -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k glimpse "$KC" >/dev/null
rm -f key.pem id.p12
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KC"
echo "Done. Build with: GLIMPSE_SIGN_IDENTITY='Glimpse Local Signing' scripts/build.sh --install"
