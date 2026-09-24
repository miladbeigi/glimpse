# Glimpse

A native macOS menu-bar screenshot tool: area / window / fullscreen / scrolling / self-timer captures,
a Quick Access Overlay, a full annotation editor, pinned screenshots and OCR.
See [SPEC.md](SPEC.md) for the complete feature list and design notes.

## Features

- **Capture** — area (frozen screen, crosshair, pixel magnifier, size label), window (transparent corners,
  optional shadow), fullscreen, previous area, self-timer, scrolling capture with sticky header/footer
  detection and optional auto-scroll, and text capture (OCR + QR codes).
- **Quick Access Overlay** — a thumbnail after every capture: Copy / Save on hover, corner buttons for close,
  annotate, pin and copy-text, drag & drop into any app, swipe to dismiss, restore recently closed.
- **Annotation editor** — arrow, line, rectangle, filled rectangle, ellipse, pen, highlighter, text (plain /
  outline / background), numbered steps, pixelate, blur, spotlight, crop and resize; every annotation stays
  editable; undo/redo; zoom; eyedropper.
- **Pinned screenshots** — always on top, resizable, adjustable opacity, click-through lock mode.
- **Automation** — `glimpse://` URL commands.

## Build & install

Requirements: macOS 14+, Xcode or the Swift toolchain.

```bash
scripts/build.sh            # builds build/Glimpse.app
scripts/build.sh --install  # also copies it to /Applications and launches it
swift test                  # unit tests (stitcher, renderer, editor model)
```

### Signing and permissions

Glimpse needs **Screen Recording** permission for every capture, and **Accessibility** only for auto-scroll
in Scrolling Capture. A setup window guides you through both on first launch; macOS applies the Screen
Recording grant after Glimpse relaunches.

macOS ties these permissions to the app's code signature. Without a signing identity the build is ad-hoc
signed and the permission is lost on every rebuild. For development, create a local self-signed identity
once (it lives in its own keychain under `~/Library/Application Support/Glimpse-dev/`):

```bash
scripts/setup-signing.sh
```

`build.sh` uses it automatically. You can also set `GLIMPSE_SIGN_IDENTITY` to any signing identity
(e.g. an Apple Developer ID).

## Default shortcuts

| Action | Shortcut |
|---|---|
| Capture Area (Space toggles window mode) | ⌥⇧⌘4 |
| Capture Fullscreen | ⌥⇧⌘3 |
| Capture Window | ⌥⇧⌘5 |
| Scrolling Capture | ⌥⇧⌘6 |
| Capture Previous Area | ⌥⇧⌘7 |
| Self-Timer (area) | ⌥⇧⌘8 |
| Capture Text (OCR) | ⌥⇧⌘2 |
| Restore Recently Closed | ⌥⇧⌘9 |

All can be changed in Settings › Shortcuts.

**Editor tools:** V select · A arrow · L line · R rectangle · F filled rect · O ellipse · P pen ·
H highlighter · T text · N counter · X pixelate · B blur · S spotlight · C crop.
Shift constrains angles/squares, Delete removes, arrow keys nudge, ⌘D duplicates, ⌘Z / ⇧⌘Z undo/redo,
⌘C copy, ⌘S save, ⇧⌘S save as, ⌘P pin, ⌘0 fit, ⌘+/⌘− zoom.

## URL commands

```bash
open "glimpse://capture-area"                     # interactive selection
open "glimpse://capture-area?x=100&y=80&width=800&height=400"   # points, top-left of display
open "glimpse://capture-fullscreen?delay=3"
open "glimpse://capture-window"
open "glimpse://scrolling-capture?x=0&y=120&width=1200&height=900&autoscroll=1"
open "glimpse://self-timer?x=200&y=150&width=1000&height=600&delay=5"
open "glimpse://capture-text?x=0&y=0&width=1200&height=300"
open "glimpse://annotate?filepath=/path/to/image.png"
```

Also: `capture-previous-area`, `restore-recently-closed`, `annotate-clipboard`, `pin-clipboard`,
`pin?filepath=…`, `open-settings`, `permissions`. Region commands accept `display=N` (1-based).

## Testing

- `swift test` — unit tests.
- `scripts/smoke-test.sh [outdir]` — end-to-end captures against the installed app via URL commands
  (needs Screen Recording). Test settings are passed as launch arguments, so saved preferences are untouched.
- DEBUG builds can render every window to PNG without any permission:
  `GLIMPSE_DEBUG_SCENARIO=1 GLIMPSE_DEBUG_IMAGE=some.png GLIMPSE_SNAPSHOT_DIR=/tmp/snaps .build/debug/Glimpse`

## Project layout

```
Sources/Glimpse/          app (menu bar, capture, overlay, pin, OCR, settings, URL commands)
Sources/Glimpse/Editor/   annotation model, renderer, canvas, toolbars
Tests/GlimpseTests/       unit tests
scripts/                  build, signing setup, smoke test, icon generation
```
