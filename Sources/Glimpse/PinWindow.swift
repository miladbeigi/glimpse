import AppKit
import Carbon.HIToolbox

/// A screenshot floating above all windows.
@MainActor
final class PinWindowController: NSObject, NSWindowDelegate {
    private static var all: [PinWindowController] = []

    static var hasLocked: Bool { all.contains { $0.locked } }

    static func pin(capture: Capture) {
        pin(image: capture.image, scale: capture.scale, capture: capture)
    }

    static func pin(image: CGImage, scale: CGFloat, capture: Capture? = nil) {
        let controller = PinWindowController(image: image, scale: scale, capture: capture)
        all.append(controller)
        controller.panel.makeKeyAndOrderFront(nil)
    }

    static func unlockAll() {
        for c in all where c.locked { c.setLocked(false) }
    }

    let panel: PinPanel
    private let image: CGImage
    private let scale: CGFloat
    private let capture: Capture?
    private(set) var locked = false
    private let aspect: CGFloat

    private init(image: CGImage, scale: CGFloat, capture: Capture?) {
        self.image = image
        self.scale = scale
        self.capture = capture
        let pointSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        aspect = pointSize.width / max(pointSize.height, 1)

        let screen = NSScreen.withMouse
        let vf = screen.visibleFrame
        let fit = min(1, (vf.width * 0.6) / pointSize.width, (vf.height * 0.6) / pointSize.height)
        let size = NSSize(width: (pointSize.width * fit).rounded(), height: (pointSize.height * fit).rounded())
        let frame = NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height)

        panel = PinPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                         backing: .buffered, defer: false)
        super.init()
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentAspectRatio = size
        panel.minSize = NSSize(width: 40, height: 40)
        panel.delegate = self

        let view = PinView(image: image, pointSize: pointSize, controller: self)
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
    }

    func close() {
        panel.orderOut(nil)
        PinWindowController.all.removeAll { $0 === self }
    }

    func windowWillClose(_ notification: Notification) {
        PinWindowController.all.removeAll { $0 === self }
    }

    func setLocked(_ value: Bool) {
        locked = value
        panel.ignoresMouseEvents = value
        if value {
            HUD.show("Pinned screenshot locked — unlock from the menu bar", symbol: "lock.fill", duration: 2.2)
        }
    }

    func setOpacity(_ value: CGFloat) {
        panel.alphaValue = value
    }

    func resize(by factor: CGFloat) {
        var frame = panel.frame
        let newWidth = min(max(frame.width * factor, 40), 8000)
        let newHeight = newWidth / aspect
        let center = NSPoint(x: frame.midX, y: frame.midY)
        frame.size = NSSize(width: newWidth, height: newHeight)
        frame.origin = NSPoint(x: center.x - newWidth / 2, y: center.y - newHeight / 2)
        panel.setFrame(frame, display: true)
    }

    func resetSize() {
        var frame = panel.frame
        let ps = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        frame.origin.y += frame.height - ps.height
        frame.size = ps
        panel.setFrame(frame, display: true)
    }

    func move(dx: CGFloat, dy: CGFloat) {
        var frame = panel.frame
        frame.origin.x += dx
        frame.origin.y += dy
        panel.setFrame(frame, display: true)
    }

    func copyImage() {
        Clipboard.copy(image, scale: scale)
        HUD.show("Copied to clipboard", symbol: "doc.on.doc.fill")
    }

    func saveAs() {
        ImageExporter.saveAs(image, scale: scale)
    }

    func annotate() {
        if let capture {
            EditorWindowController.open(capture: capture)
        } else {
            EditorWindowController.open(capture: Capture(image: image, scale: scale))
        }
        close()
    }
}

final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class PinView: NSView {
    private weak var controller: PinWindowController?
    private let closeButton: OverlayIconButton
    private var hovering = false

    @MainActor
    init(image: CGImage, pointSize: CGSize, controller: PinWindowController) {
        self.controller = controller
        closeButton = OverlayIconButton(symbol: "xmark", tooltip: "Close", target: controller,
                                        action: #selector(PinWindowController.closeFromButton))
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 0.5, alpha: 0.5).cgColor
        closeButton.isHidden = true
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        closeButton.frame.origin = NSPoint(x: 6, y: bounds.height - closeButton.frame.height - 6)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            controller?.annotate()
            return
        }
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        guard delta != 0 else { return }
        controller?.resize(by: 1 + delta / 200)
    }

    override func magnify(with event: NSEvent) {
        controller?.resize(by: 1 + event.magnification)
    }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let cmd = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case kVK_Escape: controller?.close()
        case kVK_LeftArrow: controller?.move(dx: -step, dy: 0)
        case kVK_RightArrow: controller?.move(dx: step, dy: 0)
        case kVK_UpArrow: controller?.move(dx: 0, dy: step)
        case kVK_DownArrow: controller?.move(dx: 0, dy: -step)
        case kVK_ANSI_C where cmd: controller?.copyImage()
        case kVK_ANSI_W where cmd: controller?.close()
        case kVK_ANSI_S where cmd: controller?.saveAs()
        case kVK_ANSI_Equal where cmd: controller?.resize(by: 1.1)
        case kVK_ANSI_Minus where cmd: controller?.resize(by: 1 / 1.1)
        case kVK_ANSI_0 where cmd: controller?.resetSize()
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true, event.modifierFlags.contains(.command) else { return false }
        switch Int(event.keyCode) {
        case kVK_ANSI_C, kVK_ANSI_W, kVK_ANSI_S, kVK_ANSI_Equal, kVK_ANSI_Minus, kVK_ANSI_0:
            keyDown(with: event)
            return true
        default:
            return false
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, tag: Int = 0, state: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = controller
            item.tag = tag
            item.state = state ? .on : .off
            return item
        }
        menu.addItem(add("Copy", #selector(PinWindowController.copyFromMenu)))
        menu.addItem(add("Save As…", #selector(PinWindowController.saveFromMenu)))
        menu.addItem(add("Annotate", #selector(PinWindowController.annotateFromMenu)))
        menu.addItem(.separator())
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for pct in [100, 75, 50, 25] {
            sub.addItem(add("\(pct)%", #selector(PinWindowController.opacityFromMenu(_:)), tag: pct,
                            state: abs((window?.alphaValue ?? 1) * 100 - CGFloat(pct)) < 1))
        }
        opacity.submenu = sub
        menu.addItem(opacity)
        menu.addItem(add("Actual Size", #selector(PinWindowController.actualSizeFromMenu)))
        menu.addItem(add("Lock (Click Through)", #selector(PinWindowController.lockFromMenu)))
        menu.addItem(.separator())
        menu.addItem(add("Close", #selector(PinWindowController.closeFromButton)))
        return menu
    }
}

extension PinWindowController {
    @objc func closeFromButton() { close() }
    @objc func copyFromMenu() { copyImage() }
    @objc func saveFromMenu() { saveAs() }
    @objc func annotateFromMenu() { annotate() }
    @objc func actualSizeFromMenu() { resetSize() }
    @objc func lockFromMenu() { setLocked(true) }
    @objc func opacityFromMenu(_ sender: NSMenuItem) { setOpacity(CGFloat(sender.tag) / 100) }
}
