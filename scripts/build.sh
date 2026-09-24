#!/bin/bash
# Builds build/Glimpse.app (release). Usage: scripts/build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/build/Glimpse.app"

swift build -c release 2>&1 | grep -vE "^\[|^Building|^Compiling|^Write" || true
BIN="$(swift build -c release --show-bin-path)/Glimpse"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

if [ ! -f "$ROOT/build/AppIcon.icns" ]; then
  swift scripts/make-icon.swift "$ROOT" >/dev/null
  iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$ROOT/build/AppIcon.icns"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Glimpse"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Sign with a real identity if one exists (keeps permissions across rebuilds); otherwise ad-hoc.
LOCAL_KC="$HOME/Library/Application Support/Glimpse-dev/glimpse-signing.keychain-db"
if [ -z "${GLIMPSE_SIGN_IDENTITY:-}" ] && [ -f "$LOCAL_KC" ]; then
  # Local self-signed identity from scripts/setup-signing.sh (stable signature → permissions survive rebuilds).
  security unlock-keychain -p glimpse "$LOCAL_KC" 2>/dev/null || true
  GLIMPSE_SIGN_IDENTITY="$(security find-identity -p codesigning "$LOCAL_KC" 2>/dev/null | awk '/Glimpse Local Signing/ {print $2; exit}')"
fi
IDENTITY="${GLIMPSE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID/ {print $2; exit}')}"
codesign --force --deep --sign "${IDENTITY:--}" ${LOCAL_KC:+--keychain "$LOCAL_KC"} "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

if [ "${1:-}" = "--install" ]; then
  pkill -x Glimpse 2>/dev/null || true
  rm -rf /Applications/Glimpse.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Glimpse.app"
  open /Applications/Glimpse.app
fi
