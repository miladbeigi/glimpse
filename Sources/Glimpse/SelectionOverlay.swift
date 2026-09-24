import AppKit
import Carbon.HIToolbox

enum SelectionMode {
    case area
    case window
}

struct SelectionResult {
    let screen: NSScreen
    /// Local top-left points on `screen`.
    let rect: CGRect
    /// Frozen screenshot of `screen` taken before the overlay appeared.
    let frozen: CGImage
    let scale: CGFloat
    /// Set when the user picked a window rather than dragging an area.
    let windowID: CGWindowID?
}

/// Freezes every display and lets the user drag an area or pick a window.
@MainActor
final class SelectionController {
    private var windows: [SelectionWindow] = []
    private var continuation: CheckedContinuation<SelectionResult?, Never>?
    fileprivate var mode: SelectionMode
    fileprivate let allowModeToggle: Bool
    fileprivate let windowList: [WindowInfo]
    private var keyMonitor: Any?

    private init(mode: SelectionMode, allowModeToggle: Bool, windowList: [WindowInfo]) {
        self.mode = mode
        self.allowModeToggle = allowModeToggle
        self.windowList = windowList
    }

    private static var active: SelectionController?

    static func select(mode: SelectionMode, allowModeToggle: Bool = true) async -> SelectionResult? {
        guard active == nil else { return nil }
        let windowList = ScreenCapture.onScreenWindows()

        var frozen: [(NSScreen, CGImage)] = []
        do {
            let content = try await ScreenCapture.shareableContent()
            for screen in NSScreen.screens {
                let image = try await ScreenCapture.captureScreen(screen, content: content)
                frozen.append((screen, image))
            }
        } catch {
            NSLog("Glimpse: freeze failed: \(error)")
            HUD.show("Capture failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            return nil
        }

        let controller = SelectionController(mode: mode, allowModeToggle: allowModeToggle, windowList: windowList)
        active = controller
        let result = await withCheckedContinuation { (cont: CheckedContinuation<SelectionResult?, Never>) in
            controller.continuation = cont
            controller.present(frozen)
        }
        active = nil
        return result
    }

    private func present(_ frozen: [(NSScreen, CGImage)]) {
        let mouse = NSEvent.mouseLocation
        for (screen, image) in frozen {
            let window = SelectionWindow(screen: screen, frozen: image, controller: self)
            windows.append(window)
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        let keyWindow = windows.first { NSMouseInRect(mouse, $0.targetScreen.frame, false) } ?? windows.first
        keyWindow?.makeKey()
        for w in windows { w.selectionView.updateMouse(global: mouse) }

        // Keys are handled by the key window, but also watch locally in case focus shifts between overlays.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
        NSCursor.crosshair.set()
    }

    fileprivate func handleKey(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape:
            finish(nil)
            return true
        case kVK_Space:
            if allowModeToggle && !event.isARepeat {
                mode = (mode == .area) ? .window : .area
                for w in windows {
                    w.selectionView.resetDrag()
                    w.selectionView.updateMouse(global: NSEvent.mouseLocation)
                }
            }
            return true
        default:
            return false
        }
    }

    fileprivate func finish(_ result: SelectionResult?) {
        guard let cont = continuation else { return }
        continuation = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
        cont.resume(returning: result)
    }

    fileprivate func mouseMoved(global: NSPoint) {
        for w in windows { w.selectionView.updateMouse(global: global) }
        if let w = windows.first(where: { NSMouseInRect(global, $0.targetScreen.frame, false) }), !w.isKeyWindow {
            w.makeKey()
        }
    }

    /// Topmost window under a CG-global point.
    fileprivate func window(atCG p: CGPoint) -> WindowInfo? {
        windowList.first { $0.frame.contains(p) }
    }
}

final class SelectionWindow: NSWindow {
    let targetScreen: NSScreen
    let selectionView: SelectionView

    @MainActor
    init(screen: NSScreen, frozen: CGImage, controller: SelectionController) {
        targetScreen = screen
        selectionView = SelectionView(screen: screen, frozen: frozen, controller: controller)
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none

        let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let imageView = NSImageView(frame: container.bounds)
        imageView.image = NSImage(cgImage: frozen, size: screen.frame.size)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]
        container.addSubview(imageView)
        selectionView.frame = container.bounds
        selectionView.autoresizingMask = [.width, .height]
        container.addSubview(selectionView)
        contentView = container
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SelectionView: NSView {
    private weak var controller: SelectionController?
    private let screen: NSScreen
    private let frozen: CGImage
    private var scale: CGFloat
    private var mouse: CGPoint?
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hoveredWindow: WindowInfo?

    @MainActor
    init(screen: NSScreen, frozen: CGImage, controller: SelectionController) {
        self.screen = screen
        self.frozen = frozen
        self.controller = controller
        self.scale = CGFloat(frozen.width) / max(screen.frame.width, 1)
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var mode: SelectionMode { controller?.mode ?? .area }

    func resetDrag() {
        dragStart = nil
        selection = nil
        needsDisplay = true
    }

    func updateMouse(global: NSPoint) {
        if NSMouseInRect(global, screen.frame, false) {
            mouse = screen.localTopLeft(fromGlobal: global)
        } else {
            mouse = nil
        }
        if mode == .window, let m = mouse {
            let cg = CGPoint(x: screen.cgFrame.minX + m.x, y: screen.cgFrame.minY + m.y)
            hoveredWindow = controller?.window(atCG: cg)
        } else {
            hoveredWindow = nil
        }
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        controller?.mouseMoved(global: NSEvent.mouseLocation)
    }

    override func mouseExited(with event: NSEvent) {
        controller?.mouseMoved(global: NSEvent.mouseLocation)
    }

    override func keyDown(with event: NSEvent) {
        if controller?.handleKey(event) != true { super.keyDown(with: event) }
    }

    private func localPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    override func mouseDown(with event: NSEvent) {
        let p = localPoint(event)
        mouse = p
        if mode == .window { return }
        dragStart = p
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area, let start = dragStart else { return }
        let p = localPoint(event)
        mouse = p
        selection = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                           width: abs(p.x - start.x), height: abs(p.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller else { return }
        if mode == .window {
            let p = localPoint(event)
            let cg = CGPoint(x: screen.cgFrame.minX + p.x, y: screen.cgFrame.minY + p.y)
            guard let win = controller.window(atCG: cg) else { return }
            let local = CGRect(x: win.frame.minX - screen.cgFrame.minX, y: win.frame.minY - screen.cgFrame.minY,
                               width: win.frame.width, height: win.frame.height).intersection(bounds)
            controller.finish(SelectionResult(screen: screen, rect: local, frozen: frozen, scale: scale, windowID: win.id))
            return
        }
        defer { dragStart = nil }
        guard let sel = selection?.integral.intersection(bounds), sel.width >= 4, sel.height >= 4 else {
            selection = nil
            needsDisplay = true
            return
        }
        controller.finish(SelectionResult(screen: screen, rect: sel, frozen: frozen, scale: scale, windowID: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.finish(nil)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let prefs = Preferences.shared

        if mode == .window {
            if let win = hoveredWindow {
                let r = CGRect(x: win.frame.minX - screen.cgFrame.minX, y: win.frame.minY - screen.cgFrame.minY,
                               width: win.frame.width, height: win.frame.height)
                ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor)
                ctx.fill(r)
                ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
                ctx.setLineWidth(2)
                ctx.stroke(r.insetBy(dx: 1, dy: 1))
                drawLabel(win.ownerName.isEmpty ? "\(Int(r.width)) × \(Int(r.height))" : win.ownerName,
                          centeredIn: r, ctx: ctx)
            }
            drawHint("Click a window to capture it" + (controller?.allowModeToggle == true ? " · Space for area" : "") + " · Esc to cancel", ctx: ctx)
            return
        }

        if let sel = selection, sel.width > 0, sel.height > 0 {
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(sel)
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.38))
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            ctx.setLineWidth(1)
            ctx.stroke(sel.insetBy(dx: -0.5, dy: -0.5))
            drawSizeLabel(for: sel, ctx: ctx)
        } else if let m = mouse, prefs.showCrosshair {
            drawCrosshair(at: m, ctx: ctx)
        }

        if let m = mouse {
            if prefs.showMagnifier { drawMagnifier(at: m, ctx: ctx) }
        }
        if selection == nil && dragStart == nil {
            drawHint("Drag to select an area" + (controller?.allowModeToggle == true ? " · Space for window" : "") + " · Esc to cancel", ctx: ctx)
        }
    }

    private func drawCrosshair(at p: CGPoint, ctx: CGContext) {
        let x = p.x.rounded(.down) + 0.5
        let y = p.y.rounded(.down) + 0.5
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.45))
        ctx.strokeLineSegments(between: [CGPoint(x: 0, y: y + 1), CGPoint(x: bounds.width, y: y + 1),
                                         CGPoint(x: x + 1, y: 0), CGPoint(x: x + 1, y: bounds.height)])
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.75))
        ctx.strokeLineSegments(between: [CGPoint(x: 0, y: y), CGPoint(x: bounds.width, y: y),
                                         CGPoint(x: x, y: 0), CGPoint(x: x, y: bounds.height)])
        ctx.restoreGState()
    }

    private func drawSizeLabel(for sel: CGRect, ctx: CGContext) {
        let text = "\(Int(sel.width.rounded())) × \(Int(sel.height.rounded()))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        var box = CGRect(x: sel.midX - size.width / 2 - 8, y: sel.maxY + 8, width: size.width + 16, height: size.height + 6)
        if box.maxY > bounds.height - 4 { box.origin.y = sel.maxY - box.height - 8 }
        box.origin.x = min(max(box.minX, 4), bounds.width - box.width - 4)
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        NSColor(white: 0, alpha: 0.72).setFill()
        path.fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 8, y: box.minY + 3), withAttributes: attrs)
    }

    private func drawLabel(_ text: String, centeredIn r: CGRect, ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let box = CGRect(x: r.midX - size.width / 2 - 10, y: r.midY - size.height / 2 - 5,
                         width: size.width + 20, height: size.height + 10)
        NSColor(white: 0, alpha: 0.65).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 10, y: box.minY + 5), withAttributes: attrs)
    }

    private func drawHint(_ text: String, ctx: CGContext) {
        guard let m = mouse else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let box = CGRect(x: bounds.midX - size.width / 2 - 12, y: bounds.height - size.height - 40,
                         width: size.width + 24, height: size.height + 12)
        // Keep the hint out of the way when the cursor is near it.
        guard !box.insetBy(dx: -60, dy: -60).contains(m) else { return }
        NSColor(white: 0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 12, y: box.minY + 6), withAttributes: attrs)
    }

    private func drawMagnifier(at p: CGPoint, ctx: CGContext) {
        let pixels = 15 // odd → a well-defined centre pixel
        let zoom: CGFloat = 8
        let side = CGFloat(pixels) * zoom
        let labelHeight: CGFloat = 22

        var origin = CGPoint(x: p.x + 24, y: p.y + 24)
        if origin.x + side > bounds.width - 4 { origin.x = p.x - 24 - side }
        if origin.y + side + labelHeight > bounds.height - 4 { origin.y = p.y - 24 - side - labelHeight }
        let box = CGRect(origin: origin, size: CGSize(width: side, height: side))

        let cx = Int((p.x * scale).rounded(.down))
        let cy = Int((p.y * scale).rounded(.down))
        let half = pixels / 2
        let src = CGRect(x: cx - half, y: cy - half, width: pixels, height: pixels)
        let imageBounds = CGRect(x: 0, y: 0, width: frozen.width, height: frozen.height)
        let clipped = src.intersection(imageBounds)

        ctx.saveGState()
        let rounded = CGPath(roundedRect: box, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.addPath(rounded)
        ctx.clip()
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(box)
        if !clipped.isNull, clipped.width > 0, let crop = frozen.cropping(to: clipped) {
            let dest = CGRect(x: box.minX + (clipped.minX - src.minX) * zoom,
                              y: box.minY + (clipped.minY - src.minY) * zoom,
                              width: clipped.width * zoom, height: clipped.height * zoom)
            ctx.interpolationQuality = .none
            drawImageFlipped(crop, in: dest, context: ctx)
        }
        // Grid
        ctx.setStrokeColor(CGColor(gray: 0.5, alpha: 0.18))
        ctx.setLineWidth(0.5)
        for i in 1..<pixels {
            let o = CGFloat(i) * zoom
            ctx.strokeLineSegments(between: [CGPoint(x: box.minX + o, y: box.minY), CGPoint(x: box.minX + o, y: box.maxY),
                                             CGPoint(x: box.minX, y: box.minY + o), CGPoint(x: box.maxX, y: box.minY + o)])
        }
        // Centre pixel
        let centre = CGRect(x: box.minX + CGFloat(half) * zoom, y: box.minY + CGFloat(half) * zoom, width: zoom, height: zoom)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(1.5)
        ctx.stroke(centre)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.8))
        ctx.setLineWidth(0.75)
        ctx.stroke(centre.insetBy(dx: -1, dy: -1))
        ctx.restoreGState()

        ctx.addPath(rounded)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.setLineWidth(1.5)
        ctx.strokePath()

        // Coordinates
        let text = "\(Int(p.x)), \(Int(p.y))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let label = CGRect(x: box.midX - size.width / 2 - 6, y: box.maxY + 4, width: size.width + 12, height: size.height + 4)
        NSColor(white: 0, alpha: 0.72).setFill()
        NSBezierPath(roundedRect: label, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: label.minX + 6, y: label.minY + 2), withAttributes: attrs)
    }
}

#if DEBUG
extension SelectionController {
    /// Builds (but doesn't show) an overlay window for snapshot testing.
    static func debugWindow(screen: NSScreen, frozen: CGImage, mode: SelectionMode) -> SelectionWindow {
        let controller = SelectionController(mode: mode, allowModeToggle: true, windowList: [])
        debugControllers.append(controller)
        return SelectionWindow(screen: screen, frozen: frozen, controller: controller)
    }
    private static var debugControllers: [SelectionController] = []
}

extension SelectionView {
    /// A standalone selection view of any size (for README screenshots).
    static func debugView(frame: NSRect, screen: NSScreen, frozen: CGImage) -> SelectionView {
        let window = SelectionController.debugWindow(screen: screen, frozen: frozen, mode: .area)
        let view = window.selectionView
        view.removeFromSuperview()
        view.frame = frame
        view.scale = CGFloat(frozen.width) / max(frame.width, 1)
        let container = NSView(frame: frame)
        let imageView = NSImageView(frame: frame)
        imageView.image = NSImage(cgImage: frozen, size: frame.size)
        imageView.imageScaling = .scaleAxesIndependently
        container.addSubview(imageView)
        container.addSubview(view)
        debugContainers.append(container)
        return view
    }
    private static var debugContainers: [NSView] = []

    func debugSet(mouse: CGPoint, selection: CGRect?) {
        self.mouse = mouse
        self.selection = selection
        dragStart = selection?.origin
        needsDisplay = true
    }
}
#endif
