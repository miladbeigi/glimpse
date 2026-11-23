#!/bin/bash
# Glimpse is signed with ONE self-signed "Glimpse Local Signing" identity everywhere: local builds on every Mac
# and the GitHub releases. macOS ties Screen Recording and Microphone permission to the signing certificate, so as
# long as every build carries the same one, installing a local build over a release (or the other way round, or on
# another Mac) never asks for permission again. scripts/signing-identity pins that certificate's SHA-1, and
# build.sh and the Release workflow check it.
#
# The identity lives in its own keychain (~/Library/Application Support/Glimpse-dev). Keep the exported file and
# its password in your password manager: it's how another Mac gets the same identity.
#
#   scripts/setup-signing.sh --import FILE.p12   install the shared identity on this Mac (asks for its password,
#                                                or reads GLIMPSE_SIGNING_PASSWORD)
#   scripts/setup-signing.sh --export FILE.p12   write the identity to FILE.p12 and its password to FILE.p12.password
#   scripts/setup-signing.sh --github            upload the identity to this repo's Actions secrets
#                                                (GLIMPSE_SIGNING_P12, GLIMPSE_SIGNING_PASSWORD) so releases carry it
#   scripts/setup-signing.sh --check             say whether this Mac has the pinned identity
#   scripts/setup-signing.sh --new               mint a NEW identity (only to replace the shared one everywhere:
#                                                then update scripts/signing-identity, --github and --export)
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
D="$HOME/Library/Application Support/Glimpse-dev"
KC="$D/glimpse-signing.keychain-db"
NAME="Glimpse Local Signing"
PINNED="$(tr -d '[:space:]' < "$REPO_DIR/scripts/signing-identity")"

fail() { echo "Error: $*" >&2; exit 1; }

# SHA-1 of the identity in the local keychain, if there is one (the pinned one when there are several).
local_hash() {
  [ -f "$KC" ] || return 0
  security unlock-keychain -p glimpse "$KC" 2>/dev/null || true
  local all
  all="$(security find-identity -p codesigning "$KC" 2>/dev/null | awk -v n="\"$NAME\"" 'index($0, n) {print $2}' | sort -u)"
  if printf '%s\n' "$all" | grep -qx "$PINNED"; then echo "$PINNED"; else printf '%s\n' "$all" | head -n 1; fi
}

make_keychain() {
  mkdir -p "$D"
  [ -f "$KC" ] || security create-keychain -p glimpse "$KC"
  security unlock-keychain -p glimpse "$KC"
  security list-keychains -d user | grep -q "glimpse-signing.keychain-db" \
    || security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KC"
}

# Imports $1 (a p12) with password $2 and lets codesign use it without asking.
import_p12() {
  make_keychain
  security import "$1" -k "$KC" -P "$2" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k glimpse "$KC" >/dev/null
}

# Writes the pinned identity to $1 as a p12 protected by $2.
export_p12() {
  [ "$(local_hash)" = "$PINNED" ] || fail "this Mac doesn't have the pinned identity ($PINNED); import it first."
  local only; only="$(security find-identity -p codesigning "$KC" | grep -c "\"$NAME\"" || true)"
  [ "$only" -le 1 ] || fail "$KC holds more than one Glimpse identity; remove the others first (security delete-identity -Z <sha1>)."
  rm -f "$1"
  security export -k "$KC" -t identities -f pkcs12 -P "$2" -o "$1" >/dev/null
  chmod 600 "$1"
}

case "${1:-}" in
  --import)
    file="${2:-}"; [ -f "$file" ] || fail "usage: scripts/setup-signing.sh --import FILE.p12"
    password="${GLIMPSE_SIGNING_PASSWORD:-}"
    if [ -z "$password" ]; then read -r -s -p "Password for $(basename "$file"): " password; echo; fi
    have="$(local_hash)"
    if [ -n "$have" ] && [ "$have" != "$PINNED" ]; then
      # An older, per-Mac identity: set it aside so builds pick up the shared one.
      security list-keychains -d user -s $(security list-keychains -d user | tr -d '"' | grep -v glimpse-signing)
      mv "$KC" "$KC.old-$(date +%Y%m%d%H%M%S)"
      have=""
    fi
    [ "$have" = "$PINNED" ] || import_p12 "$file" "$password"
    [ "$(local_hash)" = "$PINNED" ] || fail "the imported identity isn't the pinned one ($PINNED)."
    echo "This Mac now signs Glimpse with the shared identity ($PINNED)."
    ;;
  --export)
    file="${2:-}"; [ -n "$file" ] || fail "usage: scripts/setup-signing.sh --export FILE.p12"
    password="$(openssl rand -hex 24)"
    export_p12 "$file" "$password"
    (umask 077; printf '%s\n' "$password" > "$file.password")
    echo "Wrote $file and $file.password. Keep both in your password manager, then delete them here."
    ;;
  --github)
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    password="$(openssl rand -hex 24)"
    export_p12 "$tmp/id.p12" "$password"
    base64 -i "$tmp/id.p12" | (cd "$REPO_DIR" && gh secret set GLIMPSE_SIGNING_P12)
    printf '%s' "$password" | (cd "$REPO_DIR" && gh secret set GLIMPSE_SIGNING_PASSWORD)
    echo "Uploaded the shared identity ($PINNED) to GitHub Actions secrets."
    ;;
  --check)
    have="$(local_hash)"
    if [ "$have" = "$PINNED" ]; then echo "OK: this Mac has the shared identity ($PINNED)."
    elif [ -n "$have" ]; then fail "this Mac has $have, not the shared identity ($PINNED). Run scripts/setup-signing.sh --import FILE.p12."
    else fail "this Mac has no Glimpse signing identity. Run scripts/setup-signing.sh --import FILE.p12."
    fi
    ;;
  --new)
    [ -z "$(local_hash)" ] || fail "an identity already exists in $KC; move it aside first if you really mean to replace the shared one."
    mkdir -p "$D"; cd "$D"
    printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=%s\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' "$NAME" > cert.cnf
    openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
    trap 'rm -f key.pem id.p12' EXIT
    # -legacy keeps the p12 importable by `security` on older macOS.
    openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -out id.p12 -passout pass:glimpse 2>/dev/null \
      || openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:glimpse
    import_p12 id.p12 glimpse
    echo "New identity $(local_hash). Put it in scripts/signing-identity, then run --github and --export."
    ;;
  *)
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
