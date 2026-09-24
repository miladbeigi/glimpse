import AppKit

/// Floating thumbnails that appear in a screen corner after each capture.
@MainActor
final class QuickAccessManager {
    static let shared = QuickAccessManager()

    private var panels: [QuickAccessPanel] = [] // newest first
    private(set) var recentlyClosed: Capture?
    private let spacing: CGFloat = 12
    private let margin: CGFloat = 20
    private let maxItems = 6

    func show(_ capture: Capture) {
        if let existing = panels.first(where: { $0.capture.id == capture.id }) {
            existing.refresh()
            layout(animated: true)
            return
        }
        let screen = NSScreen.withMouse
        let panel = QuickAccessPanel(capture: capture, manager: self, screen: screen)
        panels.insert(panel, at: 0)
        while panels.count > maxItems, let last = panels.last {
            close(last, remember: false)
        }
        layout(animated: true, newPanel: panel)
    }

    func close(_ panel: QuickAccessPanel, remember: Bool = true) {
        guard let index = panels.firstIndex(where: { $0 === panel }) else { return }
        panels.remove(at: index)
        if remember { recentlyClosed = panel.capture }
        panel.dismiss()
        layout(animated: true)
    }

    func closeAll() {
        for p in panels { close(p) }
    }

    func restoreRecentlyClosed() {
        guard let capture = recentlyClosed else {
            HUD.show("Nothing to restore", symbol: "clock.arrow.circlepath")
            return
        }
        recentlyClosed = nil
        show(capture)
    }

    private func layout(animated: Bool, newPanel: QuickAccessPanel? = nil) {
        let corner = Preferences.shared.overlayCorner
        var offsets: [CGDirectDisplayID: CGFloat] = [:]
        for panel in panels { // newest nearest the corner
            let offset = offsets[panel.targetScreen.displayID] ?? 0
            let vf = panel.targetScreen.visibleFrame
            let size = panel.frame.size
            let x = corner.isLeft ? vf.minX + margin : vf.maxX - margin - size.width
            let y = corner.isTop ? vf.maxY - margin - offset - size.height : vf.minY + margin + offset
            let target = NSRect(x: x, y: y, width: size.width, height: size.height)
            offsets[panel.targetScreen.displayID] = offset + size.height + spacing

            if panel === newPanel {
                var start = target
                start.origin.x += corner.isLeft ? -(size.width + margin) : (size.width + margin)
                panel.setFrame(start, display: false)
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.28
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(target, display: true)
                    panel.animator().alphaValue = 1
                }
            } else if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    panel.animator().setFrame(target, display: true)
                }
            } else {
                panel.setFrame(target, display: true)
            }
        }
    }

    // MARK: Actions

    func copy(_ panel: QuickAccessPanel) {
        Clipboard.copy(panel.capture.image, scale: panel.capture.scale)
        HUD.show("Copied to clipboard", symbol: "doc.on.doc.fill")
        close(panel)
    }

    func save(_ panel: QuickAccessPanel) {
        do {
            let url = try panel.capture.saveToDefaultLocation()
            HUD.show("Saved to \(url.deletingLastPathComponent().lastPathComponent)", symbol: "square.and.arrow.down.fill")
            close(panel)
        } catch {
            HUD.show("Save failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
        }
    }

    func saveAs(_ panel: QuickAccessPanel) {
        let capture = panel.capture
        ImageExporter.saveAs(capture.image, scale: capture.scale, date: capture.date) { [weak self] url in
            capture.savedURL = url
            self?.close(panel)
        }
    }

    func annotate(_ panel: QuickAccessPanel) {
        let capture = panel.capture
        close(panel, remember: false)
        EditorWindowController.open(capture: capture)
    }

    func pin(_ panel: QuickAccessPanel) {
        PinWindowController.pin(capture: panel.capture)
        close(panel)
    }

    func recognizeText(_ panel: QuickAccessPanel) {
        let image = panel.capture.image
        Task {
            let text = await TextRecognizer.recognize(image)
            if text.isEmpty {
                HUD.show("No text found", symbol: "text.viewfinder")
            } else {
                Clipboard.copy(text: text)
                HUD.show("Text copied to clipboard", symbol: "text.viewfinder")
            }
        }
    }

    func reveal(_ panel: QuickAccessPanel) {
        if let url = panel.capture.savedURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

final class QuickAccessPanel: NSPanel {
    let capture: Capture
    let targetScreen: NSScreen
    private weak var manager: QuickAccessManager?
    private var thumbView: QuickAccessView!
    private var closeTimer: Timer?

    @MainActor
    init(capture: Capture, manager: QuickAccessManager, screen: NSScreen) {
        self.capture = capture
        self.manager = manager
        self.targetScreen = screen
        let size = QuickAccessPanel.size(for: capture)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none

        thumbView = QuickAccessView(panel: self)
        thumbView.frame = NSRect(origin: .zero, size: size)
        thumbView.autoresizingMask = [.width, .height]
        contentView = thumbView
        scheduleAutoClose()
    }

    static func size(for capture: Capture) -> NSSize {
        let width = Preferences.shared.overlaySize.width
        let ps = capture.pointSize
        let aspect = ps.height / max(ps.width, 1)
        let height = min(max(width * aspect, width * 0.45), width * 1.25)
        return NSSize(width: width, height: height.rounded())
    }

    override var canBecomeKey: Bool { true }

    func refresh() {
        let size = QuickAccessPanel.size(for: capture)
        setContentSize(size)
        thumbView.refresh()
        scheduleAutoClose()
    }

    func scheduleAutoClose() {
        closeTimer?.invalidate()
        closeTimer = nil
        let seconds = Preferences.shared.overlayAutoClose
        guard seconds > 0 else { return }
        closeTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.thumbView.isHovered {
                    self.scheduleAutoClose()
                } else {
                    self.manager?.close(self)
                }
            }
        }
    }

    func dismiss() {
        closeTimer?.invalidate()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
        })
    }

    // Actions invoked by the view
    func perform(_ action: QuickAccessView.Action) {
        guard let manager else { return }
        switch action {
        case .copy: manager.copy(self)
        case .save: manager.save(self)
        case .saveAs: manager.saveAs(self)
        case .annotate: manager.annotate(self)
        case .pin: manager.pin(self)
        case .text: manager.recognizeText(self)
        case .close: manager.close(self)
        case .reveal: manager.reveal(self)
        }
    }
}

/// Circular icon button with a light background, used on the hover layer.
final class OverlayIconButton: NSButton {
    convenience init(symbol: String, tooltip: String, target: AnyObject, action: Selector) {
        self.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        imagePosition = .imageOnly
        isBordered = false
        toolTip = tooltip
        self.target = target
        self.action = action
        contentTintColor = NSColor(white: 0.1, alpha: 1)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.92).cgColor
        layer?.cornerRadius = 13
    }
}

/// Pill-shaped text button ("Copy", "Save").
final class OverlayPillButton: NSButton {
    convenience init(title: String, target: AnyObject, action: Selector) {
        self.init(frame: NSRect(x: 0, y: 0, width: 84, height: 28))
        self.title = title
        isBordered = false
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.95).cgColor
        layer?.cornerRadius = 14
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor(white: 0.1, alpha: 1),
        ])
    }
}

final class QuickAccessView: NSView, NSDraggingSource {
    enum Action { case copy, save, saveAs, annotate, pin, text, close, reveal }

    private weak var panel: QuickAccessPanel?
    private let imageLayer = CALayer()
    private let hoverLayerView = NSView()
    private(set) var isHovered = false
    private var mouseDownPoint: NSPoint?
    private var didDrag = false
    private var swipeAccumulator: CGFloat = 0

    @MainActor
    init(panel: QuickAccessPanel) {
        self.panel = panel
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.25).cgColor

        imageLayer.contentsGravity = .resizeAspect
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)

        hoverLayerView.wantsLayer = true
        hoverLayerView.layer?.backgroundColor = NSColor(white: 0, alpha: 0.42).cgColor
        hoverLayerView.alphaValue = 0
        addSubview(hoverLayerView)

        let copy = OverlayPillButton(title: "Copy", target: self, action: #selector(copyAction))
        let save = OverlayPillButton(title: "Save", target: self, action: #selector(saveAction))
        let close = OverlayIconButton(symbol: "xmark", tooltip: "Close", target: self, action: #selector(closeAction))
        let edit = OverlayIconButton(symbol: "pencil", tooltip: "Annotate", target: self, action: #selector(annotateAction))
        let pin = OverlayIconButton(symbol: "pin.fill", tooltip: "Pin to screen", target: self, action: #selector(pinAction))
        let text = OverlayIconButton(symbol: "text.viewfinder", tooltip: "Copy text (OCR)", target: self, action: #selector(textAction))
        copy.identifier = NSUserInterfaceItemIdentifier("copy")
        save.identifier = NSUserInterfaceItemIdentifier("save")
        close.identifier = NSUserInterfaceItemIdentifier("close")
        edit.identifier = NSUserInterfaceItemIdentifier("edit")
        pin.identifier = NSUserInterfaceItemIdentifier("pin")
        text.identifier = NSUserInterfaceItemIdentifier("text")
        [copy, save, close, edit, pin, text].forEach(hoverLayerView.addSubview)

        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        guard let capture = panel?.capture else { return }
        imageLayer.contents = capture.image
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
        hoverLayerView.frame = bounds
        let b = bounds
        for v in hoverLayerView.subviews {
            let s = v.frame.size
            switch v.identifier?.rawValue {
            case "copy": v.frame.origin = NSPoint(x: b.midX - s.width / 2, y: b.midY + 3)
            case "save": v.frame.origin = NSPoint(x: b.midX - s.width / 2, y: b.midY - s.height - 3)
            case "close": v.frame.origin = NSPoint(x: 7, y: b.maxY - s.height - 7)
            case "edit": v.frame.origin = NSPoint(x: b.maxX - s.width - 7, y: b.maxY - s.height - 7)
            case "pin": v.frame.origin = NSPoint(x: 7, y: 7)
            case "text": v.frame.origin = NSPoint(x: b.maxX - s.width - 7, y: 7)
            default: break
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; hoverLayerView.animator().alphaValue = 1 }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; hoverLayerView.animator().alphaValue = 0 }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Buttons live inside hoverLayerView; everything else (the background) handles click/drag.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for v in hoverLayerView.subviews where v.frame.contains(local) && hoverLayerView.alphaValue > 0.01 {
            return v
        }
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        didDrag = false
        if event.clickCount == 2 {
            panel?.perform(.annotate)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !didDrag else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4, let capture = panel?.capture, let url = capture.fileForDragging() else { return }
        didDrag = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let dragImage = NSImage(cgImage: capture.image, size: bounds.size)
        item.setDraggingFrame(bounds, contents: dragImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else { return }
        if event.phase == .began { swipeAccumulator = 0 }
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            swipeAccumulator += event.scrollingDeltaX
        }
        if abs(swipeAccumulator) > 60 {
            swipeAccumulator = 0
            panel?.perform(.close)
        }
        if event.phase == .ended || event.phase == .cancelled { swipeAccumulator = 0 }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add("Copy", #selector(copyAction))
        add("Save", #selector(saveAction))
        add("Save As…", #selector(saveAsAction))
        menu.addItem(.separator())
        add("Annotate", #selector(annotateAction))
        add("Pin to Screen", #selector(pinAction))
        add("Copy Text (OCR)", #selector(textAction))
        if panel?.capture.savedURL != nil {
            add("Show in Finder", #selector(revealAction))
        }
        menu.addItem(.separator())
        add("Close", #selector(closeAction))
        return menu
    }

    @objc private func copyAction() { panel?.perform(.copy) }
    @objc private func saveAction() { panel?.perform(.save) }
    @objc private func saveAsAction() { panel?.perform(.saveAs) }
    @objc private func annotateAction() { panel?.perform(.annotate) }
    @objc private func pinAction() { panel?.perform(.pin) }
    @objc private func textAction() { panel?.perform(.text) }
    @objc private func closeAction() { panel?.perform(.close) }
    @objc private func revealAction() { panel?.perform(.reveal) }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        mouseDownPoint = nil
        if operation != [], Preferences.shared.closeOverlayAfterDrag {
            panel?.perform(.close)
        }
    }
}
