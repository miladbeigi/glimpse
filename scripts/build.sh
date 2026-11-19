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
#   GLIMPSE_SIGN_IDENTITY  codesigning identity (default: the shared Glimpse identity pinned in
#                          scripts/signing-identity, from scripts/setup-signing.sh --import). Every build should
#                          carry that one: macOS ties Screen Recording and Microphone permission to it, so any
#                          other signature asks for them again. --install refuses another one.
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
  # `xcrun --show-sdk-version` fails on some setups (an SDK it can't look up); then judge by the SDK's name.
  SDK_MAJOR="$( { xcrun --show-sdk-version 2>/dev/null || basename "$(readlink "$SDK" 2>/dev/null || echo "$SDK")" | tr -dc '0-9.'; } | cut -d. -f1)"
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

# Sign with the one shared identity (see scripts/setup-signing.sh): macOS ties Screen Recording and Microphone
# permission to the certificate, so every build, local or released, on any Mac, must carry the same one.
PINNED="$(tr -d '[:space:]' < scripts/signing-identity)"
LOCAL_KC="$HOME/Library/Application Support/Glimpse-dev/glimpse-signing.keychain-db"
KC_ARGS=()
if [ -z "${GLIMPSE_SIGN_IDENTITY:-}" ] && [ -f "$LOCAL_KC" ]; then
  security unlock-keychain -p glimpse "$LOCAL_KC" 2>/dev/null || true
  if security find-identity -p codesigning "$LOCAL_KC" 2>/dev/null | grep -q "$PINNED"; then
    GLIMPSE_SIGN_IDENTITY="$PINNED"
    KC_ARGS=(--keychain "$LOCAL_KC")
  fi
fi
IDENTITY="${GLIMPSE_SIGN_IDENTITY:-}"
SHARED=false
[ "$IDENTITY" = "$PINNED" ] && SHARED=true
if ! $SHARED; then
  echo "warning: not signed with the shared Glimpse identity ($PINNED); macOS will ask for Screen Recording and" >&2
  echo "         Microphone again for this build. Get it with: scripts/setup-signing.sh --import FILE.p12" >&2
fi
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
    $SHARED || { echo "Error: not installing a build without the shared identity (it would cost the permissions)." >&2; exit 1; }
    # Quit the app only: other processes named Glimpse are the MCP servers of running agent sessions.
    BUNDLE_ID="$(defaults read "$APP/Contents/Info.plist" CFBundleIdentifier)"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
    for _ in $(seq 1 20); do pgrep -f '/Applications/Glimpse.app/Contents/MacOS/Glimpse$' >/dev/null || break; sleep 0.5; done
    rm -rf /Applications/Glimpse.app
    cp -R "$APP" /Applications/
    open /Applications/Glimpse.app
    echo "Installed /Applications/Glimpse.app and launched it"
    ;;
  esac
done
