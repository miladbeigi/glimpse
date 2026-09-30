import AppKit
@preconcurrency import AVFoundation

/// The floating webcam view shown while recording.
///
/// It's a real window that the recording includes (every other Glimpse window is left out), so what you see is
/// what gets recorded: drag it anywhere, even mid-recording. Scroll or pinch to resize, double-click to cycle
/// sizes, right-click for shape, mirroring and size.
@MainActor
final class CameraBubble {
    let panel: CameraBubblePanel
    private let view: CameraBubbleView
    private let session = AVCaptureSession()
    private let preview: AVCaptureVideoPreviewLayer
    private let device: AVCaptureDevice
    /// Starts and stops in order (startRunning blocks, so it can't run on the main thread).
    private let sessionQueue = DispatchQueue(label: "glimpse.camera")
    /// The recorded area in Cocoa global coordinates; the bubble's saved position is relative to it.
    private var area: NSRect = .zero
    /// The recorded screen: the bubble stays on it, since anywhere else it wouldn't be recorded.
    private var screen: NSScreen?
    private var width: CGFloat

    var onHide: (() -> Void)?

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }
    var isVisible: Bool { panel.isVisible }

    init(device: AVCaptureDevice) throws {
        self.device = device
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw RecordingError.cameraUnavailable
        }
        guard session.canAddInput(input) else { throw RecordingError.cameraUnavailable }
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        session.addInput(input)
        session.commitConfiguration()
        preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill

        width = Preferences.shared.cameraSize.width
        view = CameraBubbleView(preview: preview)
        panel = CameraBubblePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: width), view: view)
        view.bubble = self
        applyStyle()
    }

    /// Shows the bubble inside `area` (Cocoa global), where it was last left, or in the bottom-left corner.
    func show(in area: NSRect, on screen: NSScreen) {
        self.area = area
        self.screen = screen
        let size = bubbleSize
        let center: CGPoint
        if let saved = Preferences.shared.cameraCenter {
            center = CGPoint(x: area.minX + saved.x * area.width, y: area.maxY - saved.y * area.height)
        } else {
            let margin: CGFloat = 28
            center = CGPoint(x: area.minX + margin + size.width / 2, y: area.minY + margin + size.height / 2)
        }
        panel.setFrame(clamped(NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                      width: size.width, height: size.height)), display: true)
        panel.orderFrontRegardless()
        let session = self.session
        sessionQueue.async { if !session.isRunning { session.startRunning() } }
    }

    func hide() {
        panel.orderOut(nil)
        let session = self.session
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
    }

    // MARK: Style

    private var bubbleSize: NSSize {
        let prefs = Preferences.shared
        return NSSize(width: width, height: prefs.cameraShape == .circle ? width : (width * 3 / 4).rounded())
    }

    func applyStyle() {
        let prefs = Preferences.shared
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = prefs.cameraMirror
        }
        let size = bubbleSize
        var frame = panel.frame
        frame.origin.x += (frame.width - size.width) / 2
        frame.origin.y += (frame.height - size.height) / 2
        frame.size = size
        panel.setFrame(panel.isVisible ? clamped(frame) : frame, display: true)
        view.cornerRadius = prefs.cameraShape == .circle ? size.width / 2 : min(size.width, size.height) * 0.14
        panel.invalidateShadow()
    }

    fileprivate func resize(by factor: CGFloat) {
        width = min(max(width * factor, 96), 520)
        applyStyle()
    }

    fileprivate func cycleSize() {
        let sizes = CameraSize.allCases
        let next = sizes.first { $0.width > width + 1 } ?? sizes[0]
        setSize(next)
    }

    fileprivate func setSize(_ size: CameraSize) {
        Preferences.shared.cameraSize = size
        width = size.width
        applyStyle()
    }

    // MARK: Moving

    /// Keeps the bubble fully on the recorded screen.
    private func clamped(_ frame: NSRect) -> NSRect {
        guard let bounds = (screen ?? NSScreen.main)?.frame else { return frame }
        var f = frame
        f.origin.x = min(max(f.minX, bounds.minX), bounds.maxX - f.width)
        f.origin.y = min(max(f.minY, bounds.minY), bounds.maxY - f.height)
        return f
    }

    fileprivate func move(to origin: NSPoint) {
        panel.setFrameOrigin(clamped(NSRect(origin: origin, size: panel.frame.size)).origin)
    }

    fileprivate func didFinishMoving() {
        let f = panel.frame
        // Left outside the recorded area: not a position worth remembering.
        guard area.width > 0, area.height > 0, area.contains(NSPoint(x: f.midX, y: f.midY)) else { return }
        Preferences.shared.cameraCenter = CGPoint(x: min(max((f.midX - area.minX) / area.width, 0), 1),
                                                  y: min(max((area.maxY - f.midY) / area.height, 0), 1))
    }

    // MARK: Menu

    fileprivate func menu() -> NSMenu {
        let prefs = Preferences.shared
        let menu = NSMenu()
        for size in CameraSize.allCases {
            let item = BlockMenuItem(title: size.title) { [weak self] in self?.setSize(size) }
            item.state = abs(size.width - width) < 1 ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for shape in CameraShape.allCases {
            let item = BlockMenuItem(title: shape.title) { [weak self] in
                prefs.cameraShape = shape
                self?.applyStyle()
            }
            item.state = prefs.cameraShape == shape ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let mirror = BlockMenuItem(title: "Mirror Camera") { [weak self] in
            prefs.cameraMirror.toggle()
            self?.applyStyle()
        }
        mirror.state = prefs.cameraMirror ? .on : .off
        menu.addItem(mirror)
        menu.addItem(.separator())
        menu.addItem(BlockMenuItem(title: "Hide Camera") { [weak self] in self?.onHide?() })
        return menu
    }
}

/// A menu item that runs a closure.
final class BlockMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

final class CameraBubblePanel: NSPanel {
    @MainActor
    init(contentRect: NSRect, view: NSView) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Glimpse Camera"
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        // The window server shades the rounded shape, and the shadow is recorded along with it.
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        animationBehavior = .none
        view.frame = NSRect(origin: .zero, size: contentRect.size)
        view.autoresizingMask = [.width, .height]
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CameraBubbleView: NSView {
    weak var bubble: CameraBubble?
    private let preview: AVCaptureVideoPreviewLayer
    fileprivate let placeholder = CALayer()
    private let ring = CALayer()
    private var dragOffset: NSPoint?

    var cornerRadius: CGFloat = 0 { didSet { needsLayout = true } }

    @MainActor
    init(preview: AVCaptureVideoPreviewLayer) {
        self.preview = preview
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor

        // Shown until the first camera frame covers it.
        let symbol = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 44, weight: .regular))
        placeholder.contents = symbol?.tinted(NSColor(white: 1, alpha: 0.35))
        placeholder.contentsGravity = .center
        layer?.addSublayer(placeholder)
        layer?.addSublayer(preview)

        ring.borderColor = NSColor(white: 1, alpha: 0.85).cgColor
        ring.borderWidth = 2
        layer?.addSublayer(ring)
        toolTip = "Drag to move · scroll to resize · right-click for options"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = cornerRadius
        placeholder.frame = bounds
        preview.frame = bounds
        ring.frame = bounds
        ring.cornerRadius = cornerRadius
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            bubble?.cycleSize()
            return
        }
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        dragOffset = NSPoint(x: mouse.x - window.frame.minX, y: mouse.y - window.frame.minY)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOffset else { return }
        let mouse = NSEvent.mouseLocation
        bubble?.move(to: NSPoint(x: mouse.x - dragOffset.x, y: mouse.y - dragOffset.y))
    }

    override func mouseUp(with event: NSEvent) {
        if dragOffset != nil { bubble?.didFinishMoving() }
        dragOffset = nil
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        guard delta != 0 else { return }
        bubble?.resize(by: 1 + max(min(delta, 40), -40) / 200)
    }

    override func magnify(with event: NSEvent) {
        bubble?.resize(by: 1 + event.magnification)
    }

    override func menu(for event: NSEvent) -> NSMenu? { bubble?.menu() }
}

#if DEBUG
extension CameraBubble {
    /// A bubble showing `image` instead of a camera (README screenshots).
    static func debugPanel(image: CGImage, width: CGFloat, shape: CameraShape = .circle) -> NSPanel {
        let height = shape == .circle ? width : (width * 3 / 4).rounded()
        let view = CameraBubbleView(preview: AVCaptureVideoPreviewLayer())
        view.debugShow(image)
        view.cornerRadius = shape == .circle ? width / 2 : min(width, height) * 0.14
        return CameraBubblePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height), view: view)
    }
}

extension CameraBubbleView {
    fileprivate func debugShow(_ image: CGImage) {
        placeholder.contents = image
        placeholder.contentsGravity = .resizeAspectFill
    }
}
#endif
