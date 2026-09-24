# Glimpse — Product Spec

A native macOS menu-bar screenshot tool: fast captures, a floating quick-access thumbnail,
a full annotation editor, pinned screenshots and OCR. Screen recording, cloud upload, capture
history and a background/"beautify" tool are intentionally out of scope for v1.

Target: macOS 14 Sonoma or later (ScreenCaptureKit screenshot APIs). Swift, AppKit + SwiftUI.

---

## 1. Scope

| Area | Features | In v1? |
|---|---|---|
| Capture | Area, Window, Fullscreen, Scrolling, Self-timer, Previous area, all-in-one mode, custom size / aspect lock | ✅ Area, Window, Fullscreen, Scrolling, Self-timer, Previous area. ❌ All-in-one, fixed size |
| Capture options | Crosshair, magnifier, freeze screen, window shadow / padding / background, hide desktop icons | ✅ Crosshair, magnifier, frozen screen, window shadow toggle. ❌ window backgrounds, hide icons |
| Quick Access Overlay | Floating thumbnail in a screen corner, Copy/Save on hover, annotate/pin/close/OCR corner buttons, drag & drop, swipe to dismiss, restore recently closed, position/size/auto-close settings, multi-display | ✅ |
| Annotate | Arrow, line, rectangle, filled rectangle, ellipse, pencil, highlighter, text (styles), counter/steps, blur, pixelate, spotlight, crop, resize, rotate/flip, color picker + eyedropper, undo/redo, editable project files | ✅ all except rotate/flip & project files |
| Pin | Always-on-top screenshot, resize, opacity, arrow-key nudging, lock (click-through) mode | ✅ |
| OCR | Copy text from any area, QR code reading, on-device | ✅ (Vision framework) |
| Automation | `glimpse://` URL commands, optionally with explicit regions | ✅ |
| Background tool | Padding, wallpapers, presets | ❌ (v2) |
| Recording, Cloud, History | — | ❌ |

## 2. Features

### 2.1 Menu bar app
- Lives in the menu bar (no Dock icon) — Dock icon appears only while an Editor or Settings window is open.
- Menu: Capture Area, Capture Previous Area, Capture Fullscreen, Capture Window, Scrolling Capture,
  Self-Timer ▸, Capture Text (OCR), Annotate Image…, Annotate from Clipboard, Pin from Clipboard,
  Restore Recently Closed, Unlock Pinned Screenshots, Open Screenshots Folder, Settings…, Quit.
- Menu items display the currently configured global shortcuts.

### 2.2 Global shortcuts (all re-assignable in Settings)
| Action | Default |
|---|---|
| Capture Area | ⌥⇧⌘4 |
| Capture Fullscreen | ⌥⇧⌘3 |
| Capture Window | ⌥⇧⌘5 |
| Scrolling Capture | ⌥⇧⌘6 |
| Capture Previous Area | ⌥⇧⌘7 |
| Self-Timer (area) | ⌥⇧⌘8 |
| Capture Text (OCR) | ⌥⇧⌘2 |
| Restore Recently Closed | ⌥⇧⌘9 |

(Defaults avoid macOS' own ⇧⌘3/4/5. Users can take those over after disabling them in System Settings ▸ Keyboard ▸ Shortcuts.)

### 2.3 Capture
- **Area**: the screen is frozen; every display gets an overlay. Drag to select. Crosshair lines,
  a pixel magnifier (with coordinates) and a live `W × H` size label. `Space` toggles window mode,
  `Esc` cancels. Releasing the mouse captures instantly.
- **Window**: hover highlights the window under the cursor; click captures it as a standalone window
  image (transparent rounded corners) with an optional soft drop-shadow.
- **Fullscreen**: captures the display under the cursor.
- **Previous area**: repeats the last area selection on the same display (live capture).
- **Self-timer**: select an area (or fullscreen from the menu), then a 3/5/10 s countdown HUD runs before a
  live capture. Click the countdown to cancel.
- **Scrolling capture**: select a region → a border and a control bar appear. The user scrolls normally
  (or presses **Auto-scroll**) and Glimpse stitches frames into one tall image. Detects sticky headers /
  footers, auto-stops at the end of the page in auto mode, and caps height at 40 000 px.
- **Capture Text (OCR)**: select an area → recognised text (and QR code payloads) goes to the clipboard.
- Own UI (overlays, pinned images) is always excluded from captures. Mouse cursor is hidden.

### 2.4 After-capture pipeline (Settings)
- Play shutter sound (on)
- Copy to clipboard (on)
- Save to disk automatically (off) — folder, PNG/JPEG, JPEG quality, save Retina images at 1×
- Show Quick Access Overlay (on)
- Open Editor immediately (off)
- Files are named `Glimpse 2026-09-24 at 14.03.22.png`, with Retina DPI metadata.

### 2.5 Quick Access Overlay
- Thumbnail slides in at a screen corner (bottom-right default; configurable corner & size); new captures stack.
- Hover reveals **Copy** and **Save** buttons in the middle and corner buttons:
  ✕ close (top-left), ✎ annotate (top-right), 📌 pin (bottom-left), 𝐓 copy text/OCR (bottom-right).
- Double-click → annotate. Drag the thumbnail into any app (Finder, Slack, Mail…) → drops a PNG file.
- Horizontal swipe on the trackpad dismisses. Right-click menu with all actions + Save As…/Reveal in Finder.
- Auto-close after N seconds (never by default); timer pauses while hovered.
- "Restore Recently Closed" brings back the last dismissed thumbnail.

### 2.6 Annotation editor
- Tools (shortcut): Select (V), Arrow (A), Line (L), Rectangle (R), Filled rectangle (F), Ellipse (O),
  Pen (P), Highlighter (H), Text (T), Counter (N), Pixelate (X), Blur (B), Spotlight (S), Crop (C).
- Holding **Shift** constrains lines/arrows to 45° and rectangles/ellipses to squares/circles.
- Style bar: colour presets, custom colour, eyedropper (sample from screen), stroke width, text size,
  text style (plain / outline / background pill).
- Every annotation stays editable: click to select, drag to move, handles to resize, Delete to remove,
  double-click text to edit; changing colour/size applies to the selection.
- Counter auto-numbers 1, 2, 3… and renumbers when steps are deleted.
- Pixelate & blur redact the underlying pixels (the originals are not present in the export).
- Spotlight dims everything except the chosen rectangles.
- Crop with handles, rule-of-thirds guides, Return to apply / Esc to cancel; non-destructive.
- Resize output (%, or width × height, aspect locked).
- Zoom (pinch, ⌘+ / ⌘− / ⌘0 fit), undo/redo (⌘Z / ⇧⌘Z).
- Actions: Copy (⌘C), Save (⌘S), Save As… (⇧⌘S), Pin, drag-out handle, Done.
- Closing the editor keeps the edits; the capture returns to the Quick Access Overlay.

### 2.7 Pinned screenshots
- Borderless always-on-top window; drag to move, scroll/pinch to resize, arrow keys nudge (⇧ = 10 pt).
- Right-click: Copy, Save As…, Annotate, Opacity (100/75/50/25 %), Lock (click-through), Close.
- `Esc` or hover ✕ closes. Double-click opens the editor. Locked pins are unlocked from the menu bar.

### 2.8 Settings
- General: launch at login, sound, after-capture actions, save folder, format, quality, 1× option.
- Capture: crosshair, magnifier, window shadow, self-timer duration.
- Quick Access: corner, size, auto-close.
- Shortcuts: recorder per action (click, press combo; ⌫ clears; Esc cancels).
- Permissions: Screen Recording & Accessibility status with buttons to open System Settings.

## 3. Architecture

```
Sources/Glimpse/
  main.swift, AppDelegate.swift      menu bar, main menu, activation policy
  Preferences.swift                  UserDefaults-backed settings
  Hotkeys.swift                      Carbon RegisterEventHotKey + KeyCombo + recorder view
  ScreenCapture.swift                ScreenCaptureKit wrappers, window list, permissions
  SelectionOverlay.swift             frozen-screen area/window selection (multi display)
  CaptureCoordinator.swift           capture modes + after-capture pipeline
  Capture.swift, ImageExporter.swift model, save/clipboard/file naming
  QuickAccess.swift                  floating thumbnails
  PinWindow.swift, HUD.swift, Countdown.swift, TextRecognizer.swift
  ScrollingCapture.swift, Stitcher.swift
  SettingsView.swift
  Editor/ Annotation.swift, EditorModel.swift, Renderer.swift, CanvasView.swift,
          EditorWindowController.swift, EditorToolbar.swift
Tests/GlimpseTests                   stitcher, renderer, key-combo tests
scripts/                             build, install, signing setup, smoke test, icon
```

- One `Renderer` draws annotations for both the on-screen canvas and export, so what you see is what you get.
- Annotation geometry is stored in image *points* (pixels ÷ backing scale) so stroke widths look the same on Retina and non-Retina captures.
- Scrolling stitcher: per-row hashes, detects static top/bottom rows (sticky UI), finds the vertical offset
  with the most matching non-uniform rows (≥ 90 %), appends only newly revealed rows.

## 4. Permissions
- **Screen Recording** — required for every capture (prompted on first launch).
- **Accessibility** — only for scrolling capture's Auto-scroll (synthetic scroll events).

## 5. Out of scope (v1)
Screen recording/GIF, cloud upload, capture history, background tool, rotate/flip, editable project files,
all-in-one mode, hide desktop icons, horizontal scrolling capture.
