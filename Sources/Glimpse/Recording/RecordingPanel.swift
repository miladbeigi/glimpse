import AppKit
import AVFoundation

/// A finished screen recording, already saved in the screenshots folder.
@MainActor
final class Recording {
    let id = UUID()
    private(set) var url: URL
    let duration: Double
    private(set) var thumbnail: CGImage?
    /// Video size in pixels.
    private(set) var pixelSize = CGSize(width: 16, height: 9)

    init(url: URL, duration: Double) {
        self.url = url
        self.duration = duration
    }

    func loadThumbnail() async {
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), size.width > 0, size.height > 0 {
            pixelSize = size
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        thumbnail = try? await generator.image(at: CMTime(seconds: min(0.5, duration / 2), preferredTimescale: 600)).image
    }
}

/// Quick Access item for a recording: play, copy, show in Finder, drag the file anywhere.
final class RecordingPanel: QuickAccessStackPanel {
    let recording: Recording
    private weak var manager: QuickAccessManager?
    private var view: RecordingThumbnailView!
    private var closeTimer: Timer?

    @MainActor
    init(recording: Recording, manager: QuickAccessManager, screen: NSScreen) {
        self.recording = recording
        self.manager = manager
        let width = Preferences.shared.overlaySize.width
        let aspect = recording.pixelSize.height / max(recording.pixelSize.width, 1)
        let size = NSSize(width: width, height: min(max(width * aspect, width * 0.45), width * 1.25).rounded())
        super.init(size: size, screen: screen)
        view = RecordingThumbnailView(panel: self)
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        contentView = view
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
                if self.view.isHovered { self.scheduleAutoClose() } else { self.closeItem() }
            }
        }
    }

    override func dismiss() {
        closeTimer?.invalidate()
        super.dismiss()
    }

    @MainActor func closeItem() { manager?.close(self, remember: false) }

    @MainActor func open() {
        NSWorkspace.shared.open(recording.url)
        closeItem()
    }

    @MainActor func copy() {
        Clipboard.copy(fileURL: recording.url)
        HUD.show("Recording copied", symbol: "doc.on.doc.fill")
        closeItem()
    }

    @MainActor func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([recording.url])
        closeItem()
    }

    @MainActor func trash() {
        NSWorkspace.shared.recycle([recording.url]) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                HUD.show("Could not delete: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            }
        }
        HUD.show("Moved to Trash", symbol: "trash")
        closeItem()
    }
}

private final class RecordingThumbnailView: NSView, NSDraggingSource {
    private weak var panel: RecordingPanel?
    private let imageLayer = CALayer()
    private let badge: DurationBadge
    private let hoverLayerView = NSView()
    private(set) var isHovered = false
    private var mouseDownPoint: NSPoint?
    private var didDrag = false
    private var swipeAccumulator: CGFloat = 0

    @MainActor
    init(panel: RecordingPanel) {
        self.panel = panel
        badge = DurationBadge(text: RecordingGeometry.formatDuration(panel.recording.duration))
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
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)

        addSubview(badge)

        hoverLayerView.wantsLayer = true
        hoverLayerView.layer?.backgroundColor = NSColor(white: 0, alpha: 0.42).cgColor
        hoverLayerView.alphaValue = 0
        addSubview(hoverLayerView)
        let play = OverlayPillButton(title: "Play", target: self, action: #selector(openAction))
        let copy = OverlayPillButton(title: "Copy", target: self, action: #selector(copyAction))
        let close = OverlayIconButton(symbol: "xmark", tooltip: "Close", target: self, action: #selector(closeAction))
        let reveal = OverlayIconButton(symbol: "folder", tooltip: "Show in Finder", target: self, action: #selector(revealAction))
        let trash = OverlayIconButton(symbol: "trash", tooltip: "Move to Trash", target: self, action: #selector(trashAction))
        play.identifier = NSUserInterfaceItemIdentifier("play")
        copy.identifier = NSUserInterfaceItemIdentifier("copy")
        close.identifier = NSUserInterfaceItemIdentifier("close")
        reveal.identifier = NSUserInterfaceItemIdentifier("reveal")
        trash.identifier = NSUserInterfaceItemIdentifier("trash")
        [play, copy, close, reveal, trash].forEach(hoverLayerView.addSubview)
        imageLayer.contents = panel.recording.thumbnail
        toolTip = panel.recording.url.lastPathComponent
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
        let b = bounds
        badge.frame = NSRect(origin: NSPoint(x: 8, y: 8), size: badge.intrinsicContentSize)
        hoverLayerView.frame = b
        for v in hoverLayerView.subviews {
            let s = v.frame.size
            switch v.identifier?.rawValue {
            case "play": v.frame.origin = NSPoint(x: b.midX - s.width / 2, y: b.midY + 3)
            case "copy": v.frame.origin = NSPoint(x: b.midX - s.width / 2, y: b.midY - s.height - 3)
            case "close": v.frame.origin = NSPoint(x: 7, y: b.maxY - s.height - 7)
            case "reveal": v.frame.origin = NSPoint(x: b.maxX - s.width - 7, y: b.maxY - s.height - 7)
            case "trash": v.frame.origin = NSPoint(x: b.maxX - s.width - 7, y: 7)
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
        if event.clickCount == 2 { panel?.open() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !didDrag, let panel else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        didDrag = true
        let item = NSDraggingItem(pasteboardWriter: panel.recording.url as NSURL)
        let image = panel.recording.thumbnail.map { NSImage(cgImage: $0, size: bounds.size) }
            ?? NSWorkspace.shared.icon(forFile: panel.recording.url.path)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else { return }
        if event.phase == .began { swipeAccumulator = 0 }
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) { swipeAccumulator += event.scrollingDeltaX }
        if abs(swipeAccumulator) > 60 {
            swipeAccumulator = 0
            panel?.closeItem()
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
        add("Play", #selector(openAction))
        add("Copy", #selector(copyAction))
        add("Show in Finder", #selector(revealAction))
        menu.addItem(.separator())
        add("Move to Trash", #selector(trashAction))
        add("Close", #selector(closeAction))
        return menu
    }

    @objc private func openAction() { panel?.open() }
    @objc private func copyAction() { panel?.copy() }
    @objc private func closeAction() { panel?.closeItem() }
    @objc private func revealAction() { panel?.reveal() }
    @objc private func trashAction() { panel?.trash() }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        mouseDownPoint = nil
        if operation != [], Preferences.shared.closeOverlayAfterDrag { panel?.closeItem() }
    }
}

/// "▶ 1:05" pill in the thumbnail's corner.
private final class DurationBadge: NSView {
    private let text: NSAttributedString
    private let icon = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))?.tinted(.white)

    init(text: String) {
        self.text = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: (8 + (icon?.size.width ?? 0) + 4 + text.size().width + 8).rounded(.up), height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.62).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        var x: CGFloat = 8
        if let icon {
            icon.draw(in: NSRect(x: x, y: (bounds.height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
            x += icon.size.width + 4
        }
        let size = text.size()
        text.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
    }
}
