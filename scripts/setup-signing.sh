#!/bin/bash
# OPTIONAL, run it yourself: creates a self-signed "Glimpse Local Signing" identity in a dedicated
# keychain so rebuilt apps keep the same signature (and keep their Screen Recording permission).
#
#   scripts/setup-signing.sh            create the local identity
#   scripts/setup-signing.sh --github   also upload it to this repo's Actions secrets (GLIMPSE_SIGNING_P12,
#                                       GLIMPSE_SIGNING_PASSWORD) so releases carry the same signature
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
D="$HOME/Library/Application Support/Glimpse-dev"; mkdir -p "$D"; cd "$D"
KC="$D/glimpse-signing.keychain-db"
printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Glimpse Local Signing\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > cert.cnf
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
trap 'rm -f key.pem id.p12' EXIT
# p12: <password>. -legacy keeps it importable by `security` on older macOS.
p12() { openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -out id.p12 -passout "pass:$1" 2>/dev/null \
  || openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout "pass:$1"; }
p12 glimpse
[ -f "$KC" ] || security create-keychain -p glimpse "$KC"
security unlock-keychain -p glimpse "$KC"
security import id.p12 -k "$KC" -P glimpse -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k glimpse "$KC" >/dev/null
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KC"
if [ "${1:-}" = --github ]; then
  password="$(openssl rand -hex 24)"
  p12 "$password"
  base64 -i id.p12 | (cd "$REPO_DIR" && gh secret set GLIMPSE_SIGNING_P12)
  printf '%s' "$password" | (cd "$REPO_DIR" && gh secret set GLIMPSE_SIGNING_PASSWORD)
  echo "Uploaded the identity to GitHub Actions secrets."
fi
echo "Done. scripts/build.sh now signs with 'Glimpse Local Signing'."
