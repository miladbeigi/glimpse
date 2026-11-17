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
#   SDKROOT                SDK to build against (default: the active one, or the newest pre-27 SDK when the
#                          Command Line Tools lack the SwiftUI macro plugin that SDK 27 needs)
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

# From the macOS 27 SDK on, SwiftUI's @State is a macro whose compiler plugin ships with Xcode only. With just
# the Command Line Tools, fall back to the newest older SDK they include.
if [ -z "${SDKROOT:-}" ]; then
  DEV="$(xcode-select -p 2>/dev/null || true)"
  SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
  SDK_MAJOR="$(xcrun --show-sdk-version 2>/dev/null | cut -d. -f1)"
  if [ "${SDK_MAJOR:-0}" -ge 27 ] && [ -z "$(find "$DEV" -name 'libSwiftUIMacros*' -print -quit 2>/dev/null)" ]; then
    OLDER="$(ls -d "$(dirname "$SDK")"/MacOSX2[0-6].*.sdk 2>/dev/null | sort -V | tail -1 || true)"
    if [ -n "$OLDER" ]; then
      echo "note: no SwiftUI macro plugin for the macOS $SDK_MAJOR SDK (install Xcode for it); building with $(basename "$OLDER")"
      export SDKROOT="$OLDER"
    fi
  fi
fi

BINS=()
LOG="$(mktemp -t glimpse-build)"
trap 'rm -f "$LOG"' EXIT
for arch in $ARCHS; do
  FLAGS=(-c "$CONFIG" --triple "$arch-apple-macosx14.0" --scratch-path ".build/$arch")
  if ! swift build "${FLAGS[@]}" >"$LOG" 2>&1; then
    grep -E "error" "$LOG" | grep -v "^\[" | head -40 || true
    echo "build failed for $arch (swift build exited non-zero; nothing was packaged)"
    exit 1
  fi
  grep -E "warning: |Build complete" "$LOG" | grep -v "^\[" || true
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
# SwiftPM resource bundles from dependencies, if any.
for b in "$(dirname "${BINS[0]}")"/*.bundle; do [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done

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
