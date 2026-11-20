#if DEBUG
import AppKit
import Meetings

/// DEBUG-only: renders the README screenshots in `docs/` from a sample image.
///
///   scripts/build.sh --debug
///   open -n build/debug/Glimpse.app --env GLIMPSE_DOCS_DIR="$PWD/docs" --env GLIMPSE_DOCS_SAMPLE=/path/sample.png
///
/// `--env GLIMPSE_DOCS_ONLY=recording` renders just `recording.png` and `settings.png`; `GLIMPSE_DOCS_ONLY=meetings`
/// renders just `meeting.png`, `transcripts.png` and `settings-meetings.png`; `GLIMPSE_DOCS_ONLY=overlay` renders
/// `overlay.png` plus each thumbnail hovered on its own. `GLIMPSE_DOCS_ONLY=recent` renders `editor.png`, `overlay.png`,
/// `recent.png` (the recent screenshots stack), `stitch.png` and `send.png` (the Send menu, with sample sessions).
/// `--env GLIMPSE_DOCS_CALL=/path/call.png` is the video-call window behind the meeting pill (default: the sample).
/// Sample meetings are written to a temporary folder, never to your meeting history or transcripts. Add
/// `--args -meetingsEnabled YES` so Settings › Meetings shows meetings turned on (not saved).
/// `--env GLIMPSE_DOCS_AVATAR=/path/face.png` puts that picture in the camera bubble (use an AI-generated face,
/// not a real person); without it the bubble shows a drawn silhouette.
///
/// Windows are captured with ScreenCaptureKit (needs Screen Recording), so they look exactly like the app.
@MainActor
enum DocsScenario {
    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["GLIMPSE_DOCS_DIR"], let path = env["GLIMPSE_DOCS_SAMPLE"],
              let (sample, scale) = ImageUtil.load(url: URL(fileURLWithPath: path)) else { return false }
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Before anything adds a capture: never read or write your real recent screenshots.
        RecentStore.shared.inMemoryOnly = true
        Task { @MainActor in
            if env["GLIMPSE_DOCS_ONLY"] == "recording" {
                await recording(sample: sample, scale: scale, out: out)
                await settings(out: out)
            } else if env["GLIMPSE_DOCS_ONLY"] == "meetings" {
                await meetings(sample: sample, out: out)
            } else if env["GLIMPSE_DOCS_ONLY"] == "overlay" {
                await overlay(sample: sample, scale: scale, out: out, allHovered: true)
            } else if env["GLIMPSE_DOCS_ONLY"] == "hud" {
                await hud(out: out)
            } else if env["GLIMPSE_DOCS_ONLY"] == "recent" {
                await editor(sample: sample, scale: scale, out: out)
                await overlay(sample: sample, scale: scale, out: out)
                await recent(sample: sample, scale: scale, out: out)
            } else {
                await run(sample: sample, scale: scale, out: out)
            }
            NSLog("Glimpse docs rendered to \(out.path)")
            NSApp.terminate(nil)
        }
        return true
    }

    private static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    /// `hud-<n>.png`: the toast with a few of the messages it shows, to check its layout (GLIMPSE_DOCS_ONLY=hud).
    private static func hud(out: URL) async {
        let messages: [(String, String)] = [
            ("Sent to Claude Code", "paperplane.fill"),
            ("Sent to Claude Code. It reads it when the current turn ends", "paperplane.fill"),
            ("Copied to clipboard", "doc.on.doc.fill"),
            ("OK", "checkmark.circle.fill"),
            ("Press ⌘V in Claude Code to attach it (allow Glimpse in Accessibility to send directly)", "paperplane"),
        ]
        for (i, (text, symbol)) in messages.enumerated() {
            HUD.show(text, symbol: symbol, duration: 5)
            await sleep(0.6)
            if let p = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible && $0.contentView is NSVisualEffectView }),
               let (img, _) = try? await ScreenCapture.captureWindow(CGWindowID(p.windowNumber)) {
                try? ImageExporter.write(img, scale: 1, to: out.appendingPathComponent("hud-\(i + 1).png"))
            }
        }
    }

    /// `overlay.png`: two thumbnails, the newest hovered. With `allHovered` (GLIMPSE_DOCS_ONLY=overlay) it also
    /// shows a tall one and hovers all three, writing each as `overlay-<n>.png` too, to check the buttons' layout
    /// from the shortest thumbnail to the tallest.
    private static func overlay(sample: CGImage, scale: CGFloat, out: URL, allHovered: Bool = false) async {
        let chart = ImageUtil.crop(sample, toPoints: CGRect(x: 220, y: 212, width: 576, height: 254), scale: scale) ?? sample
        if allHovered, let tall = ImageUtil.crop(sample, toPoints: CGRect(x: 0, y: 0, width: 300, height: 420), scale: scale) {
            QuickAccessManager.shared.show(Capture(image: tall, scale: scale))
            await sleep(0.4)
        }
        QuickAccessManager.shared.show(Capture(image: chart, scale: scale))
        await sleep(0.4)
        QuickAccessManager.shared.show(Capture(image: sample, scale: scale))
        await sleep(0.8)
        let panels = NSApp.windows.compactMap { $0 as? QuickAccessPanel }.filter(\.isVisible)
            .sorted { $0.frame.minY < $1.frame.minY } // nearest the corner first
        if allHovered { panels.last?.setKept(true) } // shows what a kept one looks like
        for p in allHovered ? panels : Array(panels.prefix(1)) { p.contentView?.mouseEntered(with: NSEvent()) }
        await sleep(0.5)
        var shots: [CGImage] = []
        for p in panels {
            if let (img, _) = try? await ScreenCapture.captureWindow(CGWindowID(p.windowNumber)) { shots.append(img) }
        }
        if allHovered {
            for (i, shot) in shots.enumerated() {
                try? ImageExporter.write(shot, scale: 1, to: out.appendingPathComponent("overlay-\(i + 1).png"))
            }
        }
        if !shots.isEmpty, let composite = overlayComposite(sample: sample, panels: Array(shots.prefix(2))) {
            try? ImageExporter.write(composite, scale: 1, to: out.appendingPathComponent("overlay.png"))
        }
        QuickAccessManager.shared.closeAll()
        await sleep(0.5)
    }

    /// `editor.png`: the editor with every kind of mark, a pencil arrow and a note beside it.
    private static func editor(sample: CGImage, scale: CGFloat, out: URL) async {
        let capture = Capture(image: sample, scale: scale)
        EditorWindowController.open(capture: capture)
        await sleep(1)
        guard let editor = EditorWindowController.openEditors.first, let window = editor.window else { return }
        let m = editor.model
        func add(_ kind: AnnotationKind, _ s: CGPoint, _ e: CGPoint, _ color: RGBA = .defaultRed,
                 width: CGFloat = 5, text: String = "", style: TextStyle = .outline, points: [CGPoint] = []) {
            var a = Annotation(kind: kind, start: s, end: e, points: points, color: color, lineWidth: width)
            a.text = text
            a.textStyle = style
            a.fontSize = 26
            m.add(a)
        }
        add(.blur, CGPoint(x: 932, y: 256), CGPoint(x: 1084, y: 432))
        add(.highlighter, .zero, .zero, RGBA.presets[2], width: 5,
            points: [CGPoint(x: 220, y: 69), CGPoint(x: 440, y: 69)])
        add(.rectangle, CGPoint(x: 212, y: 90), CGPoint(x: 454, y: 202))
        add(.counter, CGPoint(x: 212, y: 90), .zero)
        // A pencil arrow, curving up and over onto the tallest bar, and its note past the tail.
        let curve = (0...36).map { i -> CGPoint in
            let t = CGFloat(i) / 36, u = 1 - t
            let p0 = CGPoint(x: 470, y: 292), c = CGPoint(x: 640, y: 205), p1 = CGPoint(x: 754, y: 256)
            return CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p1.x, y: u * u * p0.y + 2 * u * t * c.y + t * t * p1.y)
        }
        let arrow = Annotation(kind: .arrow, start: curve[0], end: curve[curve.count - 1], points: curve,
                               color: .defaultRed, lineWidth: 6)
        m.add(arrow)
        var (note, _) = NotePlacement.note("Best month yet", beside: arrow, imageSize: m.imageSize, color: .defaultRed,
                                           fontSize: 26, style: .background)
        note.fontSize = 26
        m.add(note)
        add(.counter, CGPoint(x: 1050, y: 30), .zero, RGBA.presets[4])
        m.tool = .arrow
        m.selectedID = nil
        await sleep(0.8)
        await captureWindow(window, to: out.appendingPathComponent("editor.png"))
        m.annotations.removeAll() // don't carry the demo edits back into the capture
        window.close()
        await sleep(0.5)
        QuickAccessManager.shared.closeAll()
        await sleep(0.3)
    }

    /// Marks drawn on a capture, as if you'd drawn them in the editor.
    private static func mark(_ capture: Capture, _ annotations: [Annotation]) {
        let size = CGSize(width: CGFloat(capture.image.width) / capture.scale, height: CGFloat(capture.image.height) / capture.scale)
        var state = EditorDocumentState(annotations: [], cropRect: CGRect(origin: .zero, size: size), outputScale: 1)
        state.annotations = annotations
        capture.apply(state)
    }

    /// `recent.png`, `stitch.png` and `send.png`.
    private static func recent(sample: CGImage, scale: CGFloat, out: URL) async {
        func crop(_ r: CGRect) -> Capture {
            Capture(image: ImageUtil.crop(sample, toPoints: r, scale: scale) ?? sample, scale: scale)
        }
        let kpis = crop(CGRect(x: 205, y: 70, width: 990, height: 130))
        let customers = crop(CGRect(x: 806, y: 200, width: 394, height: 286))
        let chart = crop(CGRect(x: 212, y: 200, width: 590, height: 286))
        let whole = Capture(image: sample, scale: scale)
        // Yours: a box and a step on the churn card.
        mark(kpis, [
            Annotation(kind: .rectangle, start: CGPoint(x: 498, y: 20), end: CGPoint(x: 728, y: 124), color: .defaultRed, lineWidth: 5),
        ])
        // The agent's: its own colour, a box, an arrow with a note, a number.
        let claude = AgentColors.rgba(for: "Claude")
        let agent = Capture(image: sample, scale: scale)
        agent.author = "Claude"
        agent.label = "spacing"
        var box = Annotation(kind: .rectangle, start: CGPoint(x: 205, y: 82), end: CGPoint(x: 1195, y: 200), color: claude, lineWidth: 5)
        box.text = ""
        let pts = (0...30).map { i -> CGPoint in
            let t = CGFloat(i) / 30, u = 1 - t
            return CGPoint(x: u * u * 560 + 2 * u * t * 470 + t * t * 470, y: u * u * 300 + 2 * u * t * 300 + t * t * 206)
        }
        let arrow = Annotation(kind: .arrow, start: pts[0], end: pts[pts.count - 1], points: pts, color: claude, lineWidth: 6)
        let (note, _) = NotePlacement.note("16 pt gaps here", beside: arrow, imageSize: CGSize(width: 1200, height: 486),
                                           color: claude, fontSize: 26, style: .background)
        mark(agent, [box, arrow, note])
        for c in [whole, chart, customers, kpis, agent] { RecentStore.shared.add(c) }

        let stack = RecentStackController.shared
        stack.show()
        await sleep(1)
        stack.toggleSelection(kpis.id)
        stack.toggleSelection(customers.id)
        await sleep(0.6)
        if let panel = NSApp.windows.first(where: { $0 is StackPanel && $0.isVisible }),
           let (img, s) = try? await ScreenCapture.captureWindow(CGWindowID(panel.windowNumber)),
           let composite = recentComposite(sample: sample, panel: img, panelScale: s) {
            try? ImageExporter.write(composite, scale: 1, to: out.appendingPathComponent("recent.png"))
        }
        stack.hide(animated: false)
        await sleep(0.3)

        if let (image, _) = Collage.render([chart.image, customers.image, kpis.image]) {
            try? ImageExporter.write(image, scale: scale, to: out.appendingPathComponent("stitch.png"))
        }

        await send(chart: crop(CGRect(x: 205, y: 205, width: 995, height: 281)), out: out)
    }

    /// The stack panel at the right edge of a desktop, over a window.
    private static func recentComposite(sample: CGImage, panel: CGImage, panelScale: CGFloat) -> CGImage? {
        let ph = CGFloat(panel.height) / panelScale, pw = CGFloat(panel.width) / panelScale
        let size = CGSize(width: 1100, height: max(640, ph + 72))
        guard let ctx = context(size) else { return nil }
        drawWallpaper(ctx, size)
        drawWindow(sample, at: CGPoint(x: 50, y: (size.height - 486 * 0.62) / 2), scale: 0.62, in: ctx, canvasHeight: size.height)
        let rect = CGRect(x: size.width - pw - 24, y: 36, width: pw, height: ph)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 26, color: CGColor(gray: 0, alpha: 0.45))
        ctx.interpolationQuality = .high
        ctx.draw(panel, in: rect)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// `send.png`: the editor with a drawing and the Send menu open over it, listing sample sessions. The menu is the
    /// one Send builds (titles, subtitles, app icons); the sessions are made up.
    private static func send(chart: Capture, out: URL) async {
        mark(chart, [])
        EditorWindowController.open(capture: chart)
        await sleep(1)
        guard let editor = EditorWindowController.openEditors.first, let window = editor.window else { return }
        let m = editor.model
        let pts = (0...30).map { i -> CGPoint in
            let t = CGFloat(i) / 30, u = 1 - t
            return CGPoint(x: u * u * 335 + 2 * u * t * 475 + t * t * 550, y: u * u * 55 + 2 * u * t * 35 + t * t * 62)
        }
        let arrow = Annotation(kind: .arrow, start: pts[0], end: pts[pts.count - 1], points: pts, color: .defaultRed, lineWidth: 6)
        m.add(arrow)
        let (note, _) = NotePlacement.note("why does Sep jump?", beside: arrow, imageSize: m.imageSize, color: .defaultRed,
                                           fontSize: 24, style: .background)
        m.add(note)
        m.tool = .select
        m.selectedID = nil
        await sleep(0.6)

        let sessions: [(String, String, String)] = [
            ("Revenue chart tooltips", "Claude Code · ~/code/northwind · Ghostty", "com.mitchellh.ghostty"),
            ("Fix the churn calculation", "Claude Code · ~/code/northwind-api · Claude", "com.anthropic.claudefordesktop"),
            ("northwind-ios", "Codex · ~/code/northwind-ios · Terminal", "com.apple.Terminal"),
        ]
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Send to"))
        for (i, (title, detail, bundle)) in sessions.enumerated() {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: i == 0 ? "\r" : "\(i + 1)")
            item.keyEquivalentModifierMask = []
            if #available(macOS 14.4, *) { item.subtitle = detail } else { item.title = "\(title) — \(detail)" }
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            if let url {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 18, height: 18)
                item.image = icon
            }
            menu.addItem(item)
        }
        // With several sessions running, the button reads "Send to…".
        m.sendTitle = "Send to…"
        await sleep(0.3)
        let content = window.contentView!
        let at = NSPoint(x: content.bounds.width * 0.5, y: content.bounds.height * 0.47)
        let shot = out.appendingPathComponent("send.png")
        var captured = false
        // The menu runs its own loop on the main thread, so the main actor can't run anything until it closes:
        // capture from a timer in that loop, synchronously, then close the menu. `screencapture -l` with the menu's
        // window gives the window it opened over with the menu on top, and the window's shadow.
        let timer = Timer(timeInterval: 0.8, repeats: false) { _ in
            let pid = ProcessInfo.processInfo.processIdentifier
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            if let info = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid
                    && ($0[kCGWindowLayer as String] as? Int ?? 0) >= 101 }),
               let id = info[kCGWindowNumber as String] as? CGWindowID {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-l", "\(id)", shot.path]
                try? p.run()
                p.waitUntilExit()
                captured = p.terminationStatus == 0
            }
            menu.cancelTracking()
        }
        RunLoop.main.add(timer, forMode: .common)
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: menu.items[1], at: at, in: content)
        timer.invalidate()
        if !captured { NSLog("Glimpse docs: could not capture the Send menu") }
        m.annotations.removeAll()
        window.close()
        await sleep(0.3)
    }

    private static func run(sample: CGImage, scale: CGFloat, out: URL) async {
        // 1. Editor with annotations.
        await editor(sample: sample, scale: scale, out: out)
        QuickAccessManager.shared.closeAll()
        await sleep(0.5)

        // 2. Quick Access Overlay (hovered) on a desktop-like background.
        await overlay(sample: sample, scale: scale, out: out)
        let chart = ImageUtil.crop(sample, toPoints: CGRect(x: 220, y: 212, width: 576, height: 254), scale: scale) ?? sample

        // 3. Area selection with magnifier, over a fake desktop.
        if let screen = NSScreen.main {
            let size = CGSize(width: 1500, height: 820)
            if let desktop = fakeDesktop(size: size, sample: sample, at: CGPoint(x: 150, y: 90)) {
                let frame = NSRect(origin: .zero, size: size)
                let view = SelectionView.debugView(frame: frame, screen: screen, frozen: desktop)
                // End the drag on the edge of the last chart bar so the magnifier shows real detail.
                view.debugSet(mouse: CGPoint(x: 150 + 745, y: 90 + 330),
                              selection: CGRect(x: 150 + 210, y: 90 + 88, width: 535, height: 242))
                if let img = render(view.superview ?? view) {
                    try? ImageExporter.write(img, scale: 1, to: out.appendingPathComponent("selection.png"))
                }
            }
        }

        // 4. Settings.
        await settings(out: out)

        // 5. Pinned screenshot over the fake desktop.
        PinWindowController.pin(image: chart, scale: scale)
        await sleep(0.6)
        if let pin = NSApp.windows.first(where: { $0 is PinPanel && $0.isVisible }),
           let (img, _) = try? await ScreenCapture.captureWindow(CGWindowID(pin.windowNumber)),
           let composite = pinComposite(sample: sample, pin: img) {
            try? ImageExporter.write(composite, scale: 1, to: out.appendingPathComponent("pin.png"))
            pin.orderOut(nil)
        }

        // 6. Screen recording: control bar and camera bubble.
        await recording(sample: sample, scale: scale, out: out)

        // 7. Meetings: recording pill over a call, transcription history, Settings › Meetings.
        await meetings(sample: sample, out: out)
    }

    private static func settings(tab: String = "recording", out: URL, name: String = "settings.png") async {
        SettingsWindowController.show(tab: tab)
        await sleep(1)
        if let w = SettingsWindowController.shared?.window {
            w.makeFirstResponder(nil) // no focus ring on the first control
            await sleep(0.3)
            await captureWindow(w, to: out.appendingPathComponent(name))
            w.close()
        }
    }

    /// The meeting recording pill under a video call, the Transcription History window with sample meetings, and
    /// Settings › Meetings. Meetings data goes to a temporary folder that is deleted afterwards.
    private static func meetings(sample: CGImage, out: URL) async {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("glimpse-docs-\(UUID().uuidString)")
        Meetings.debugUseScratchFolder(scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        Meetings.debugAddSampleMeetings()

        let call = ProcessInfo.processInfo.environment["GLIMPSE_DOCS_CALL"]
            .flatMap { ImageUtil.load(url: URL(fileURLWithPath: $0))?.0 } ?? sample
        let pill = Meetings.debugShowRecordingPill(elapsed: 23 * 60 + 41)
        await sleep(1.2) // let the level meter move
        var pillShot: CGImage?
        if let pill { pillShot = try? await ScreenCapture.captureWindow(CGWindowID(pill.windowNumber)).0 }
        Meetings.debugHideRecordingPill()
        if let pillShot, let composite = meetingComposite(call: call, pill: pillShot) {
            try? ImageExporter.write(composite, scale: 1, to: out.appendingPathComponent("meeting.png"))
        } else {
            NSLog("Glimpse docs: could not capture the meeting pill")
        }

        if let w = Meetings.debugShowHistory() {
            await sleep(1.2)
            w.makeFirstResponder(nil)
            await sleep(0.3)
            await captureWindow(w, to: out.appendingPathComponent("transcripts.png"))
            w.close()
        }

        await settings(tab: "meetings", out: out, name: "settings-meetings.png")
    }

    /// A video-call window with the meeting recording pill centred below it.
    private static func meetingComposite(call: CGImage, pill: CGImage) -> CGImage? {
        let size = CGSize(width: 1100, height: 700)
        guard let ctx = context(size) else { return nil }
        drawWallpaper(ctx, size)
        let windowScale = min(0.72, 900 / CGFloat(call.width))
        let w = CGFloat(call.width) * windowScale
        drawWindow(call, at: CGPoint(x: (size.width - w) / 2, y: 40), scale: windowScale, in: ctx, canvasHeight: size.height)
        // The pill sits where Glimpse puts it: bottom centre, above the Dock. Captures are 2× on Retina.
        let pillScale: CGFloat = (NSScreen.main?.backingScaleFactor ?? 2) > 1 ? 0.5 : 1
        let r = CGRect(x: (size.width - CGFloat(pill.width) * pillScale) / 2, y: 30,
                       width: CGFloat(pill.width) * pillScale, height: CGFloat(pill.height) * pillScale)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: CGColor(gray: 0, alpha: 0.45))
        ctx.interpolationQuality = .high
        ctx.draw(pill, in: r)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// The recording control bar and a camera bubble (a still picture, not a real camera) over the fake desktop.
    private static func recording(sample: CGImage, scale: CGFloat, out: URL) async {
        let face = ProcessInfo.processInfo.environment["GLIMPSE_DOCS_AVATAR"].flatMap { ImageUtil.load(url: URL(fileURLWithPath: $0))?.0 }
        guard let screen = NSScreen.main, let avatar = face ?? avatar(size: CGSize(width: 440, height: 440)) else { return }
        let bubble = CameraBubble.debugPanel(image: avatar, width: 190)
        bubble.setFrameOrigin(NSPoint(x: screen.frame.minX + 40, y: screen.frame.minY + 40))
        bubble.orderFrontRegardless()
        let bar = RecordingController.shared.debugShowRecordingControls(on: screen, seconds: 83)
        await sleep(1)
        let bubbleShot = try? await ScreenCapture.captureWindow(CGWindowID(bubble.windowNumber)).0
        var barShot: CGImage?
        if let bar { barShot = try? await ScreenCapture.captureWindow(CGWindowID(bar.windowNumber)).0 }
        RecordingController.shared.debugHideControls()
        bubble.orderOut(nil)
        guard let bubbleShot, let barShot, let composite = recordingComposite(sample: sample, bubble: bubbleShot, bar: barShot)
        else {
            NSLog("Glimpse docs: could not capture the recording UI")
            return
        }
        try? ImageExporter.write(composite, scale: 1, to: out.appendingPathComponent("recording.png"))
    }

    /// A neutral stand-in for a webcam picture: a silhouette on a warm gradient.
    private static func avatar(size: CGSize) -> CGImage? {
        guard let ctx = context(size) else { return nil }
        let colors = [CGColor(srgbRed: 0.98, green: 0.80, blue: 0.62, alpha: 1),
                      CGColor(srgbRed: 0.93, green: 0.55, blue: 0.52, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: ImageUtil.sRGB, colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
        let w = size.width
        ctx.fillEllipse(in: CGRect(x: w * 0.34, y: w * 0.44, width: w * 0.32, height: w * 0.36)) // head
        ctx.fillEllipse(in: CGRect(x: w * 0.14, y: -w * 0.30, width: w * 0.72, height: w * 0.66)) // shoulders
        return ctx.makeImage()
    }

    private static func recordingComposite(sample: CGImage, bubble: CGImage, bar: CGImage) -> CGImage? {
        let size = CGSize(width: 1100, height: 700)
        guard let ctx = context(size) else { return nil }
        drawWallpaper(ctx, size)
        let windowScale: CGFloat = 0.72
        let origin = CGPoint(x: 90, y: 56)
        drawWindow(sample, at: origin, scale: windowScale, in: ctx, canvasHeight: size.height)
        // The recorded area: a dashed border around the window.
        let w = CGFloat(sample.width) * windowScale, h = CGFloat(sample.height) * windowScale
        let area = CGRect(x: origin.x, y: size.height - origin.y - h, width: w, height: h).insetBy(dx: -6, dy: -6)
        ctx.saveGState()
        ctx.setLineWidth(2)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.5))
        ctx.stroke(area)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.stroke(area)
        ctx.restoreGState()
        // Bubble in the area's bottom-left corner, bar centred below it. Captures are 2× on Retina.
        func draw(_ img: CGImage, at p: CGPoint, scale: CGFloat, blur: CGFloat) {
            let r = CGRect(x: p.x, y: p.y, width: CGFloat(img.width) * scale, height: CGFloat(img.height) * scale)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: blur, color: CGColor(gray: 0, alpha: 0.45))
            ctx.interpolationQuality = .high
            ctx.draw(img, in: r)
            ctx.restoreGState()
        }
        let bubbleScale = 190 / CGFloat(bubble.width)
        draw(bubble, at: CGPoint(x: area.minX + 28, y: area.minY + 28), scale: bubbleScale, blur: 26)
        let barScale = bubbleScale // same backing scale
        let barWidth = CGFloat(bar.width) * barScale
        draw(bar, at: CGPoint(x: area.midX - barWidth / 2, y: area.minY - CGFloat(bar.height) * barScale - 16),
             scale: barScale, blur: 20)
        return ctx.makeImage()
    }

    private static func captureWindow(_ window: NSWindow, to url: URL) async {
        guard let (img, scale) = try? await ScreenCapture.captureWindow(CGWindowID(window.windowNumber)) else {
            NSLog("Glimpse docs: could not capture \(url.lastPathComponent)")
            return
        }
        try? ImageExporter.write(ImageUtil.addShadow(to: img, scale: scale), scale: scale, to: url)
    }

    private static func render(_ view: NSView) -> CGImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    // MARK: Compositing

    private static func context(_ size: CGSize) -> CGContext? {
        CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: ImageUtil.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Soft blue–purple wallpaper.
    private static func drawWallpaper(_ ctx: CGContext, _ size: CGSize) {
        let colors = [CGColor(srgbRed: 0.33, green: 0.45, blue: 0.95, alpha: 1),
                      CGColor(srgbRed: 0.62, green: 0.40, blue: 0.93, alpha: 1),
                      CGColor(srgbRed: 0.96, green: 0.62, blue: 0.78, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: ImageUtil.sRGB, colors: colors, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
    }

    /// Draws `image` with its top-left at `p` (top-left coordinates), with a window-like shadow and corners.
    private static func drawWindow(_ image: CGImage, at p: CGPoint, scale: CGFloat = 1, in ctx: CGContext, canvasHeight: CGFloat) {
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        let rect = CGRect(x: p.x, y: canvasHeight - p.y - h, width: w, height: h)
        let path = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: CGColor(gray: 0, alpha: 0.4))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }

    private static func fakeDesktop(size: CGSize, sample: CGImage, at p: CGPoint) -> CGImage? {
        guard let ctx = context(size) else { return nil }
        drawWallpaper(ctx, size)
        drawWindow(sample, at: p, in: ctx, canvasHeight: size.height)
        return ctx.makeImage()
    }

    private static func overlayComposite(sample: CGImage, panels: [CGImage]) -> CGImage? {
        let size = CGSize(width: 1100, height: 640)
        guard let ctx = context(size) else { return nil }
        drawWallpaper(ctx, size)
        drawWindow(sample, at: CGPoint(x: 60, y: 60), scale: 0.62, in: ctx, canvasHeight: size.height)
        // Panels arrive nearest-the-corner first; stack them upwards from the bottom-right.
        var bottom: CGFloat = 36
        for img in panels {
            let w = CGFloat(img.width), h = CGFloat(img.height)
            let rect = CGRect(x: size.width - 36 - w, y: bottom, width: w, height: h)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: CGColor(gray: 0, alpha: 0.45))
            ctx.draw(img, in: rect)
            ctx.restoreGState()
            bottom += h + 12
        }
        return ctx.makeImage()
    }

    private static func pinComposite(sample: CGImage, pin: CGImage) -> CGImage? {
        let size = CGSize(width: 1100, height: 640)
        guard let ctx = context(size) else { return nil }
        drawWallpaper(ctx, size)
        drawWindow(sample, at: CGPoint(x: 60, y: 60), scale: 0.62, in: ctx, canvasHeight: size.height)
        let w = CGFloat(pin.width) * 0.9, h = CGFloat(pin.height) * 0.9
        let rect = CGRect(x: size.width - w - 70, y: 70, width: w, height: h)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: CGColor(gray: 0, alpha: 0.5))
        ctx.interpolationQuality = .high
        ctx.draw(pin, in: rect)
        ctx.restoreGState()
        return ctx.makeImage()
    }
}
#endif
