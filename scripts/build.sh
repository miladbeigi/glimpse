#!/bin/bash
# Builds build/Glimpse.app.
#
#   scripts/build.sh             build build/Glimpse.app (universal: Apple silicon + Intel)
#   scripts/build.sh --install   also copy it to /Applications and launch it
#   scripts/build.sh --zip       also write build/Glimpse-<version>.zip and .zip.sha256 (release assets)
#   scripts/build.sh --debug     build a debug-configuration app instead (same bundle id and signature)
#
# Environment:
#   VERSION                app version (default: contents of ./VERSION)
#   GLIMPSE_SIGN_IDENTITY  codesigning identity (default: the local identity from scripts/setup-signing.sh,
#                          else an Apple Development / Developer ID identity, else ad-hoc)
#   ARCHS                  architectures to build (default: "arm64 x86_64")
#   UPDATE_REPO            GitHub "owner/repo" the app checks for updates (default: the origin remote;
#                          set it empty to build without updates)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VERSION="${VERSION:-$(cat VERSION)}"
VERSION="${VERSION#v}"
CONFIG=release
for arg in "$@"; do [ "$arg" = "--debug" ] && CONFIG=debug; done
ARCHS="${ARCHS:-arm64 x86_64}"
if [[ -z "${UPDATE_REPO+x}" ]]; then
  UPDATE_REPO="$(git remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##' || true)"
fi
[ "$CONFIG" = debug ] && ARCHS="$(uname -m)"

BINS=()
for arch in $ARCHS; do
  FLAGS=(-c "$CONFIG" --triple "$arch-apple-macosx14.0" --scratch-path ".build/$arch")
  swift build "${FLAGS[@]}" 2>&1 | grep -E "error|warning: |Compiling Glimpse|Build complete" | grep -v "^\[" || true
  BIN="$(swift build "${FLAGS[@]}" --show-bin-path)/Glimpse"
  [ -x "$BIN" ] || { echo "build failed for $arch"; exit 1; }
  BINS+=("$BIN")
done

if [ ! -f "$ROOT/build/AppIcon.icns" ]; then
  swift scripts/make-icon.swift "$ROOT" >/dev/null
  iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$ROOT/build/AppIcon.icns"
fi

APP="$ROOT/build/Glimpse.app"
[ "$CONFIG" = debug ] && APP="$ROOT/build/debug/Glimpse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/Glimpse"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :UpdateRepository string $UPDATE_REPO" "$APP/Contents/Info.plist"
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Sign. A stable identity keeps macOS permissions (Screen Recording) across rebuilds.
LOCAL_KC="$HOME/Library/Application Support/Glimpse-dev/glimpse-signing.keychain-db"
KC_ARGS=()
if [ -z "${GLIMPSE_SIGN_IDENTITY:-}" ] && [ -f "$LOCAL_KC" ]; then
  security unlock-keychain -p glimpse "$LOCAL_KC" 2>/dev/null || true
  GLIMPSE_SIGN_IDENTITY="$(security find-identity -p codesigning "$LOCAL_KC" 2>/dev/null | awk '/Glimpse Local Signing/ {print $2; exit}')"
  [ -n "$GLIMPSE_SIGN_IDENTITY" ] && KC_ARGS=(--keychain "$LOCAL_KC")
fi
IDENTITY="${GLIMPSE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" ${KC_ARGS[@]+"${KC_ARGS[@]}"} "$APP"
echo "Built $APP (version $VERSION${UPDATE_REPO:+, updates from $UPDATE_REPO}, $(lipo -archs "$APP/Contents/MacOS/Glimpse"), signed: ${IDENTITY:-ad-hoc})"

for arg in "$@"; do
  case "$arg" in
  --zip)
    ZIP="$ROOT/build/Glimpse-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    (cd "$ROOT/build" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
    echo "Wrote $ZIP and $ZIP.sha256"
    ;;
  --install)
    pkill -x Glimpse 2>/dev/null && sleep 1 || true
    rm -rf /Applications/Glimpse.app
    cp -R "$APP" /Applications/
    open /Applications/Glimpse.app
    echo "Installed /Applications/Glimpse.app and launched it"
    ;;
  esac
done
