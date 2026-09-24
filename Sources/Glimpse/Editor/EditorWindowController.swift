import AppKit
import SwiftUI

/// Keeps a document smaller than the viewport centred.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        let frame = doc.frame
        if rect.width > frame.width { rect.origin.x = (frame.width - rect.width) / 2 }
        if rect.height > frame.height { rect.origin.y = (frame.height - rect.height) / 2 }
        return rect
    }
}

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private(set) static var openEditors: [EditorWindowController] = []

    static func open(capture: Capture) {
        if let existing = openEditors.first(where: { $0.capture.id == capture.id }) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = EditorWindowController(capture: capture)
        openEditors.append(controller)
        AppDelegate.refreshActivationPolicy()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeFirstResponder(controller.canvas)
        controller.window?.layoutIfNeeded()
        controller.fitToWindow()
    }

    static func openImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let (image, scale) = ImageUtil.load(url: url) else {
            HUD.show("Could not open image", symbol: "exclamationmark.triangle")
            return
        }
        open(capture: Capture(image: image, scale: scale))
    }

    let capture: Capture
    let model: EditorModel
    private let scrollView = NSScrollView()
    private(set) var canvas: CanvasView!
    private var autoFit = true
    private var closing = false

    init(capture: Capture) {
        self.capture = capture
        model = EditorModel(image: capture.baseImage, scale: capture.scale, state: capture.document)

        let screen = NSScreen.withMouse
        let vf = screen.visibleFrame
        let chromeHeight: CGFloat = 46 + 44 + 28
        let img = model.displayRect.size
        let fit = min(1, (vf.width * 0.85 - 40) / img.width, (vf.height * 0.85 - chromeHeight - 40) / img.height)
        let contentSize = NSSize(width: min(max(1000, img.width * fit + 40), vf.width * 0.95),
                                 height: min(max(520, img.height * fit + chromeHeight + 40), vf.height * 0.95))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 900, height: 360)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: vf.midX - window.frame.width / 2, y: vf.midY - window.frame.height / 2))
        super.init(window: window)
        window.delegate = self
        buildContent()
        wireModel()
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() {
        guard let window else { return }
        canvas = CanvasView(model: model)
        canvas.onDisplayRectChange = { [weak self] in
            guard let self else { return }
            self.updateTitle()
            if self.autoFit { self.fitToWindow() }
        }

        let clip = CenteringClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 16
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.86, alpha: 1)
        }
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let top = NSHostingView(rootView: EditorTopBar(model: model))
        let bottom = NSHostingView(rootView: EditorBottomBar(model: model, makeDragFile: { [weak self] in self?.dragFile() }))
        top.translatesAutoresizingMaskIntoConstraints = false
        bottom.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(top)
        container.addSubview(scrollView)
        container.addSubview(bottom)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: container.topAnchor),
            top.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            top.heightAnchor.constraint(equalToConstant: 46),
            scrollView.topAnchor.constraint(equalTo: top.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bottom.heightAnchor.constraint(equalToConstant: 44),
        ])
        window.contentView = container

        NotificationCenter.default.addObserver(self, selector: #selector(liveMagnifyEnded),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollFrameChanged),
                                               name: NSView.frameDidChangeNotification, object: scrollView)
    }

    private func wireModel() {
        model.onCopy = { [weak self] in self?.copyImage() }
        model.onSave = { [weak self] in self?.saveImage() }
        model.onSaveAs = { [weak self] in self?.saveImageAs() }
        model.onPin = { [weak self] in self?.pinImage() }
        model.onDone = { [weak self] in self?.window?.performClose(nil) }
        model.onZoom = { [weak self] action in self?.zoom(action) }
    }

    private func updateTitle() {
        let size = model.outputPixelSize
        window?.title = "Glimpse — \(Int(size.width)) × \(Int(size.height))"
    }

    // MARK: Zoom

    func fitToWindow() {
        guard let doc = scrollView.documentView else { return }
        let avail = scrollView.frame.size
        guard avail.width > 0, avail.height > 0, doc.frame.width > 0, doc.frame.height > 0 else { return }
        let mag = min(1, (avail.width - 40) / doc.frame.width, (avail.height - 40) / doc.frame.height)
        setMagnification(max(mag, scrollView.minMagnification))
        autoFit = true
    }

    private func setMagnification(_ m: CGFloat) {
        let clamped = min(max(m, scrollView.minMagnification), scrollView.maxMagnification)
        let centre = NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        scrollView.setMagnification(clamped, centeredAt: centre)
        model.magnification = clamped
        canvas.needsDisplay = true
    }

    private func zoom(_ action: EditorModel.ZoomAction) {
        switch action {
        case .fit:
            fitToWindow()
        case .actual:
            autoFit = false
            setMagnification(1)
        case .zoomIn:
            autoFit = false
            setMagnification(scrollView.magnification * 1.25)
        case .zoomOut:
            autoFit = false
            setMagnification(scrollView.magnification / 1.25)
        }
    }

    @objc private func liveMagnifyEnded() {
        autoFit = false
        model.magnification = scrollView.magnification
        canvas.needsDisplay = true
    }

    @objc private func scrollFrameChanged() {
        if autoFit { fitToWindow() }
    }

    // MARK: Output

    private func rendered() -> CGImage? {
        canvas.commitText()
        return model.render()
    }

    private func dragFile() -> URL? {
        guard let image = rendered() else { return nil }
        return try? ImageExporter.writeTemporary(image, scale: capture.scale, date: capture.date)
    }

    private func commitToCapture() {
        guard model.hasChanges || capture.document != nil, let image = rendered() else { return }
        capture.update(rendered: image, document: model.state)
    }

    func copyImage() {
        guard let image = rendered() else { return }
        Clipboard.copy(image, scale: capture.scale)
        HUD.show("Copied to clipboard", symbol: "doc.on.doc.fill")
    }

    func saveImage() {
        commitToCapture()
        do {
            let url = try capture.saveToDefaultLocation()
            HUD.show("Saved \(url.lastPathComponent)", symbol: "square.and.arrow.down.fill")
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func saveImageAs() {
        guard let image = rendered() else { return }
        ImageExporter.saveAs(image, scale: capture.scale, date: capture.date, window: window) { [weak self] url in
            self?.capture.savedURL = url
            self?.commitToCapture()
        }
    }

    func pinImage() {
        guard let image = rendered() else { return }
        PinWindowController.pin(image: image, scale: capture.scale)
    }

    // MARK: Menu actions (reached through the responder chain)

    @objc func editorUndo(_ sender: Any?) { model.undo() }
    @objc func editorRedo(_ sender: Any?) { model.redo() }

    @objc func copy(_ sender: Any?) { copyImage() }
    @objc func editorSave(_ sender: Any?) { saveImage() }
    @objc func editorSaveAs(_ sender: Any?) { saveImageAs() }
    @objc func delete(_ sender: Any?) { model.deleteSelected() }
    @objc func editorDuplicate(_ sender: Any?) { model.duplicateSelected() }
    @objc func editorBringToFront(_ sender: Any?) { model.bringSelectedToFront() }
    @objc func zoomIn(_ sender: Any?) { zoom(.zoomIn) }
    @objc func zoomOut(_ sender: Any?) { zoom(.zoomOut) }
    @objc func zoomToFit(_ sender: Any?) { zoom(.fit) }
    @objc func zoomActualSize(_ sender: Any?) { zoom(.actual) }
    @objc func editorPin(_ sender: Any?) { pinImage() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(editorUndo(_:)): return model.canUndo
        case #selector(editorRedo(_:)): return model.canRedo
        case #selector(delete(_:)), #selector(editorDuplicate(_:)), #selector(editorBringToFront(_:)):
            return model.selectedID != nil
        default: return true
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard !closing else { return }
        closing = true
        let changed = model.hasChanges
        commitToCapture()
        if changed && Preferences.shared.copyToClipboard {
            Clipboard.copy(capture.image, scale: capture.scale)
        }
        NotificationCenter.default.removeObserver(self)
        EditorWindowController.openEditors.removeAll { $0 === self }
        if Preferences.shared.showOverlay {
            QuickAccessManager.shared.show(capture)
        }
        DispatchQueue.main.async { AppDelegate.refreshActivationPolicy() }
    }
}
