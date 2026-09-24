#!/bin/bash
# End-to-end checks of real captures via the glimpse:// URL scheme.
# Needs Screen Recording permission for /Applications/Glimpse.app (Accessibility for the auto-scroll test).
set -uo pipefail
OUT="${1:-$(mktemp -d)}"
mkdir -p "$OUT"
# Test settings are passed as launch arguments (NSUserDefaults argument domain): they apply to
# that process only and are never written to the user's saved preferences.
launch_test() {
  pkill -x Glimpse; while pgrep -x Glimpse >/dev/null; do sleep 0.2; done
  open -a /Applications/Glimpse.app --args -autoSave YES -showOverlay NO -copyToClipboard NO -playSound NO -saveDirectory "$1"
  sleep 1.5
}
restore() {
  pkill -x Glimpse; while pgrep -x Glimpse >/dev/null; do sleep 0.2; done
  open /Applications/Glimpse.app
}
trap restore EXIT

fail=0
# run <name> <url> [timeout]: triggers a capture into $OUT/<name>/ and waits for the file.
run() {
  local dir="$OUT/$1"; mkdir -p "$dir"
  launch_test "$dir"
  open "$2"
  for i in $(seq 1 $((${3:-10} * 2))); do ls "$dir"/*.png >/dev/null 2>&1 && break; sleep 0.5; done
  if ls "$dir"/*.png >/dev/null 2>&1; then
    printf "PASS %-12s %s\n" "$1" "$(sips -g pixelWidth -g pixelHeight "$dir"/*.png | awk '/pixel/ {printf "%s ", $2}')"
  else
    printf "FAIL %-12s no file\n" "$1"; fail=1
  fi
}

[ -z "${ONLY_SCROLL:-}" ] && run fullscreen "glimpse://capture-fullscreen"
[ -z "${ONLY_SCROLL:-}" ] && run area       "glimpse://capture-area?x=100&y=80&width=800&height=400"
if [ -n "${WINDOW_ID:-}" ]; then run window "glimpse://capture-window?windowid=$WINDOW_ID"; fi
if [ -n "${SCROLL_REGION:-}" ]; then run scrolling "glimpse://scrolling-capture?$SCROLL_REGION&autoscroll=1" 40; fi

[ -n "${ONLY_SCROLL:-}" ] && exit $fail
# OCR: clipboard should receive text from the top-left of the screen.
launch_test "$OUT/ocr"
echo -n "" | pbcopy
open "glimpse://capture-text?x=0&y=0&width=1200&height=300"
for i in $(seq 1 20); do [ -n "$(pbpaste)" ] && break; sleep 0.5; done
if [ -n "$(pbpaste)" ]; then echo "PASS ocr          $(pbpaste | head -c 80 | tr '\n' ' ')"; else echo "FAIL ocr          empty clipboard"; fail=1; fi
exit $fail
