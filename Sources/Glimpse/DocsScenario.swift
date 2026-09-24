#if DEBUG
import AppKit

/// DEBUG-only: renders the README screenshots in `docs/` from a sample image.
///
///   scripts/build.sh --debug
///   open -n build/debug/Glimpse.app --env GLIMPSE_DOCS_DIR="$PWD/docs" --env GLIMPSE_DOCS_SAMPLE=/path/sample.png
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
        Task { @MainActor in
            await run(sample: sample, scale: scale, out: out)
            NSApp.terminate(nil)
        }
        return true
    }

    private static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    private static func run(sample: CGImage, scale: CGFloat, out: URL) async {
        // 1. Editor with annotations.
        let capture = Capture(image: sample, scale: scale)
        EditorWindowController.open(capture: capture)
        await sleep(1)
        if let editor = EditorWindowController.openEditors.first, let window = editor.window {
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
            add(.arrow, CGPoint(x: 640, y: 150), CGPoint(x: 735, y: 262), width: 6)
            add(.text, CGPoint(x: 520, y: 108), .zero, text: "Best month yet", style: .background)
            add(.counter, CGPoint(x: 1050, y: 30), .zero, RGBA.presets[4])
            m.tool = .arrow
            m.selectedID = nil
            await sleep(0.8)
            await captureWindow(window, to: out.appendingPathComponent("editor.png"))
            editor.model.annotations.removeAll() // don't carry the demo edits back into the capture
            window.close()
            await sleep(0.5)
        }
        QuickAccessManager.shared.closeAll()
        await sleep(0.5)

        // 2. Quick Access Overlay (hovered) on a desktop-like background.
        let chart = ImageUtil.crop(sample, toPoints: CGRect(x: 220, y: 212, width: 576, height: 254), scale: scale) ?? sample
        QuickAccessManager.shared.show(Capture(image: chart, scale: scale))
        await sleep(0.4)
        QuickAccessManager.shared.show(Capture(image: sample, scale: scale))
        await sleep(0.8)
        let panels = NSApp.windows.compactMap { $0 as? QuickAccessPanel }.filter(\.isVisible)
            .sorted { $0.frame.minY < $1.frame.minY } // nearest the corner first
        if let newest = panels.first { newest.contentView?.mouseEntered(with: NSEvent()) }
        await sleep(0.5)
        var shots: [CGImage] = []
        for p in panels {
            if let (img, _) = try? await ScreenCapture.captureWindow(CGWindowID(p.windowNumber)) { shots.append(img) }
        }
        if !shots.isEmpty, let composite = overlayComposite(sample: sample, panels: shots) {
            try? ImageExporter.write(composite, scale: 1, to: out.appendingPathComponent("overlay.png"))
        }
        QuickAccessManager.shared.closeAll()
        await sleep(0.5)

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
        SettingsWindowController.show()
        await sleep(1)
        if let w = SettingsWindowController.shared?.window {
            await captureWindow(w, to: out.appendingPathComponent("settings.png"))
            w.close()
        }

        // 5. Pinned screenshot over the fake desktop.
        PinWindowController.pin(image: chart, scale: scale)
        await sleep(0.6)
        if let pin = NSApp.windows.first(where: { $0 is PinPanel && $0.isVisible }),
           let (img, _) = try? await ScreenCapture.captureWindow(CGWindowID(pin.windowNumber)),
           let composite = pinComposite(sample: sample, pin: img) {
            try? ImageExporter.write(composite, scale: 1, to: out.appendingPathComponent("pin.png"))
            pin.orderOut(nil)
        }
        NSLog("Glimpse docs rendered to \(out.path)")
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
