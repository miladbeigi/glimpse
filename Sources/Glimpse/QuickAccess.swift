import AppKit

/// Floating thumbnails that appear in a screen corner after each capture.
@MainActor
final class QuickAccessManager {
    static let shared = QuickAccessManager()

    private var panels: [QuickAccessStackPanel] = [] // newest first
    private(set) var recentlyClosed: Capture?
    private let spacing: CGFloat = 12
    private let margin: CGFloat = 20
    private let maxItems = 6

    func show(_ capture: Capture) {
        if let existing = panels.first(where: { ($0 as? QuickAccessPanel)?.capture.id == capture.id }) as? QuickAccessPanel {
            existing.refresh()
            layout(animated: true)
            return
        }
        add(QuickAccessPanel(capture: capture, manager: self, screen: NSScreen.withMouse))
    }

    func show(_ recording: Recording) {
        add(RecordingPanel(recording: recording, manager: self, screen: NSScreen.withMouse))
    }

    private func add(_ panel: QuickAccessStackPanel) {
        panels.insert(panel, at: 0)
        while panels.count > maxItems, let last = panels.last {
            close(last, remember: false)
        }
        layout(animated: true, newPanel: panel)
    }

    func close(_ panel: QuickAccessStackPanel, remember: Bool = true) {
        guard let index = panels.firstIndex(where: { $0 === panel }) else { return }
        panels.remove(at: index)
        if remember, let capture = (panel as? QuickAccessPanel)?.capture { recentlyClosed = capture }
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

    private func layout(animated: Bool, newPanel: QuickAccessStackPanel? = nil) {
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

    /// Pin to Screen: the screenshot as a floating window of its own (right-click menu). The thumbnail's pin button
    /// keeps the thumbnail itself instead (`QuickAccessPanel.isKept`).
    func pin(_ panel: QuickAccessPanel) {
        PinWindowController.pin(capture: panel.capture)
        close(panel)
    }

    /// Moves the screenshot from its thumbnail to the recent screenshots stack, focused on it there.
    func showInRecent(_ panel: QuickAccessPanel) {
        let capture = panel.capture
        if !RecentStore.shared.captures.contains(where: { $0.id == capture.id }) { RecentStore.shared.add(capture) }
        close(panel, remember: false)
        RecentStackController.shared.show(focus: capture.id)
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

/// A floating item in the Quick Access stack (a screenshot or a recording).
class QuickAccessStackPanel: NSPanel {
    let targetScreen: NSScreen

    @MainActor
    init(size: NSSize, screen: NSScreen) {
        targetScreen = screen
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
    }

    override var canBecomeKey: Bool { true }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
        })
    }
}

final class QuickAccessPanel: QuickAccessStackPanel {
    let capture: Capture
    private weak var manager: QuickAccessManager?
    private var thumbView: QuickAccessView!
    private var closeTimer: Timer?

    @MainActor
    init(capture: Capture, manager: QuickAccessManager, screen: NSScreen) {
        self.capture = capture
        self.manager = manager
        let size = QuickAccessPanel.size(for: capture)
        super.init(size: size, screen: screen)

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

    func refresh() {
        let size = QuickAccessPanel.size(for: capture)
        setContentSize(size)
        thumbView.refresh()
        scheduleAutoClose()
    }

    /// Kept thumbnails don't close by themselves: the pin button toggles it, and Send turns it on so a send you change
    /// your mind about leaves the thumbnail where it was.
    private(set) var isKept = false

    func setKept(_ kept: Bool) {
        guard kept != isKept else { return }
        isKept = kept
        thumbView.keptChanged(kept)
        scheduleAutoClose()
    }

    func scheduleAutoClose() {
        closeTimer?.invalidate()
        closeTimer = nil
        let seconds = Preferences.shared.overlayAutoClose
        guard seconds > 0, !isKept else { return }
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

    override func dismiss() {
        closeTimer?.invalidate()
        super.dismiss()
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
        case .keep: setKept(!isKept)
        case .showInRecent: manager.showInRecent(self)
        case .text: manager.recognizeText(self)
        case .close: manager.close(self)
        case .reveal: manager.reveal(self)
        case .send:
            let capture = self.capture
            // With several sessions running, the overlay stays up while you pick one. It's kept from here on: if you
            // close the menu (or click elsewhere), the thumbnail is still there when you come back to it.
            setKept(true)
            AgentHandoff.send([capture], close: { [weak self, weak manager] in
                guard let self else { return }
                manager?.close(self)
            })
        }
    }
}

/// Circular icon button with a light background, used on the hover layer.
final class OverlayIconButton: NSButton {
    static let side: CGFloat = 26

    convenience init(symbol: String, tooltip: String, target: AnyObject, action: Selector) {
        self.init(frame: NSRect(x: 0, y: 0, width: OverlayIconButton.side, height: OverlayIconButton.side))
        // One size and weight for every glyph, drawn at its natural size in the middle of the circle.
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold, scale: .medium))
        imagePosition = .imageOnly
        imageScaling = .scaleNone
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
    enum Action { case copy, save, saveAs, annotate, pin, keep, showInRecent, text, close, reveal, send }

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

        copyButton = OverlayPillButton(title: "Copy", target: self, action: #selector(copyAction))
        saveButton = OverlayPillButton(title: "Save", target: self, action: #selector(saveAction))
        closeButton = OverlayIconButton(symbol: "xmark", tooltip: "Close", target: self, action: #selector(closeAction))
        // Fixed text: naming the session would mean scanning the running processes on every hover.
        sendButton = OverlayIconButton(symbol: "paperplane", tooltip: "Send to your Claude Code session", target: self,
                                       action: #selector(sendAction))
        keepButton = OverlayIconButton(symbol: "pin", tooltip: Self.keepTip(false), target: self, action: #selector(keepAction))
        // The bottom row, left to right.
        tools = [
            OverlayIconButton(symbol: "pencil", tooltip: "Draw on it", target: self, action: #selector(annotateAction)),
            keepButton,
            OverlayIconButton(symbol: "text.viewfinder", tooltip: "Copy text (OCR)", target: self, action: #selector(textAction)),
            OverlayIconButton(symbol: "rectangle.stack", tooltip: "Show in Recent Screenshots", target: self,
                              action: #selector(showInRecentAction)),
            sendButton,
        ]
        ([copyButton, saveButton, closeButton] + tools).forEach(hoverLayerView.addSubview)

        // Says the thumbnail is kept while the buttons are hidden.
        keptBadge.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Kept")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        keptBadge.contentTintColor = .white
        keptBadge.wantsLayer = true
        keptBadge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        keptBadge.layer?.cornerRadius = 9
        keptBadge.isHidden = true
        addSubview(keptBadge)

        refresh()
    }

    private var keepButton: OverlayIconButton!
    private let keptBadge = NSImageView()

    private static func keepTip(_ kept: Bool) -> String {
        kept ? "Kept on screen: click to let it close by itself" : "Keep on screen (don't close by itself)"
    }

    /// The pin button shows whether the thumbnail is kept; so does a badge in the corner when the pointer is away.
    func keptChanged(_ kept: Bool) {
        keepButton.image = NSImage(systemSymbolName: kept ? "pin.fill" : "pin", accessibilityDescription: "Keep")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold, scale: .medium))
        keepButton.contentTintColor = kept ? .white : NSColor(white: 0.1, alpha: 1)
        keepButton.layer?.backgroundColor = (kept ? NSColor.controlAccentColor : NSColor(white: 1, alpha: 0.92)).cgColor
        keepButton.toolTip = Self.keepTip(kept)
        keptBadge.isHidden = !kept || isHovered
    }

    private var copyButton: OverlayPillButton!
    private var saveButton: OverlayPillButton!
    private var closeButton: OverlayIconButton!
    private var sendButton: OverlayIconButton!
    private var tools: [OverlayIconButton] = []

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
        keptBadge.frame = NSRect(x: bounds.maxX - 24, y: bounds.maxY - 24, width: 18, height: 18)
        for (view, frame) in Self.layout(in: bounds, tools: tools.count) {
            switch view {
            case .close: closeButton.frame = frame
            case .copy: copyButton.frame = frame
            case .save: saveButton.frame = frame
            case .tool(let i): tools[i].frame = frame
            }
        }
    }

    enum Slot: Hashable { case close, copy, save, tool(Int) }

    /// Close in the top-left corner; the tools in one centred, evenly spaced row along the bottom; Copy and Save in
    /// the middle, stacked when there's room, side by side when not, and up beside Close on the shortest thumbnails.
    static func layout(in b: NSRect, tools: Int) -> [Slot: NSRect] {
        let inset: CGFloat = 7, side = OverlayIconButton.side
        // Narrower gaps when the row would otherwise reach the edges (the small size).
        let gap = tools > 1 ? min(8, ((b.width - inset * 2 - CGFloat(tools) * side) / CGFloat(tools - 1)).rounded(.down)) : 8
        let pillHeight: CGFloat = 28, pillGap: CGFloat = 6
        var frames: [Slot: NSRect] = [:]
        frames[.close] = NSRect(x: b.minX + inset, y: b.maxY - inset - side, width: side, height: side)
        let rowWidth = CGFloat(tools) * side + CGFloat(max(tools - 1, 0)) * gap
        for i in 0..<tools {
            frames[.tool(i)] = NSRect(x: (b.midX - rowWidth / 2 + CGFloat(i) * (side + gap)).rounded(), y: b.minY + inset,
                                      width: side, height: side)
        }
        // Between the top row and the bottom row.
        let middle = NSRect(x: b.minX + inset, y: b.minY + inset + side + pillGap, width: b.width - inset * 2,
                            height: b.height - (inset + side + pillGap) * 2)
        let pillWidth: CGFloat = 84
        if middle.height >= pillHeight * 2 + pillGap {
            let top = (middle.midY + pillGap / 2).rounded()
            frames[.copy] = NSRect(x: (b.midX - pillWidth / 2).rounded(), y: top, width: pillWidth, height: pillHeight)
            frames[.save] = NSRect(x: (b.midX - pillWidth / 2).rounded(), y: top - pillGap - pillHeight, width: pillWidth,
                                   height: pillHeight)
            return frames
        }
        // Side by side: in the middle if it's tall enough, else in the top row to the right of Close.
        let inMiddle = middle.height >= pillHeight
        let area = inMiddle ? middle
            : NSRect(x: b.minX + inset + side + pillGap, y: b.maxY - inset - pillHeight + (pillHeight - side) / 2,
                     width: b.width - inset * 2 - side - pillGap, height: pillHeight)
        let width = min(pillWidth, ((area.width - pillGap) / 2).rounded(.down))
        let left = (area.midX - width - pillGap / 2).rounded()
        let y = inMiddle ? (area.midY - pillHeight / 2).rounded() : area.minY
        frames[.copy] = NSRect(x: left, y: y, width: width, height: pillHeight)
        frames[.save] = NSRect(x: left + width + pillGap, y: y, width: width, height: pillHeight)
        return frames
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        keptBadge.isHidden = true // the pin button says it now
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; hoverLayerView.animator().alphaValue = 1 }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        keptBadge.isHidden = panel?.isKept != true
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
        add(panel?.isKept == true ? "Let It Close by Itself" : "Keep on Screen", #selector(keepAction))
        add("Pin to Screen", #selector(pinAction))
        add("Show in Recent Screenshots", #selector(showInRecentAction))
        add("Copy Text (OCR)", #selector(textAction))
        if let capture = panel?.capture {
            add(MainActor.assumeIsolated { AgentHandoff.sendTitle(for: [capture]) }, #selector(sendAction))
        }
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
    @objc private func keepAction() { panel?.perform(.keep) }
    @objc private func showInRecentAction() { panel?.perform(.showInRecent) }
    @objc private func textAction() { panel?.perform(.text) }
    @objc private func closeAction() { panel?.perform(.close) }
    @objc private func revealAction() { panel?.perform(.reveal) }
    @objc private func sendAction() { panel?.perform(.send) }

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
