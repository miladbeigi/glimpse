import AppKit
import Vision

/// Small transient toast near the bottom of the active screen.
@MainActor
enum HUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, symbol: String = "checkmark.circle.fill", duration: TimeInterval = 1.6) {
        hideWork?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        icon.contentTintColor = .white

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 18)

        let width = min(max(stack.fittingSize.width, 120), 520)
        let height = max(stack.fittingSize.height, 40)
        let screen = NSScreen.withMouse
        let frame = NSRect(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.minY + 90, width: width, height: height)

        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.appearance = NSAppearance(named: .vibrantDark)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = height / 2
        bg.layer?.masksToBounds = true
        stack.frame = bg.bounds
        stack.autoresizingMask = [.width, .height]
        bg.addSubview(stack)
        p.contentView = bg
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        panel = p

        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }) {
                p.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

/// Big countdown number in the middle of the screen. Click it to cancel.
@MainActor
final class Countdown {
    static func run(seconds: Int, on screen: NSScreen) async -> Bool {
        guard seconds > 0 else { return true }
        let countdown = Countdown(screen: screen)
        return await countdown.start(seconds: seconds)
    }

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var cancelled = false

    private init(screen: NSScreen) {
        let size: CGFloat = 150
        let frame = NSRect(x: screen.frame.midX - size / 2, y: screen.frame.midY - size / 2, width: size, height: size)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = CountdownBackground(frame: NSRect(origin: .zero, size: frame.size))
        label.font = .monospacedDigitSystemFont(ofSize: 72, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (size - 90) / 2 + 8, width: size, height: 90)
        bg.addSubview(label)
        let hint = NSTextField(labelWithString: "Click to cancel")
        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.textColor = NSColor.white.withAlphaComponent(0.7)
        hint.alignment = .center
        hint.frame = NSRect(x: 0, y: 16, width: size, height: 16)
        bg.addSubview(hint)
        panel.contentView = bg
        bg.onClick = { [weak self] in self?.cancelled = true }
    }

    private func start(seconds: Int) async -> Bool {
        panel.orderFrontRegardless()
        for remaining in stride(from: seconds, through: 1, by: -1) {
            label.stringValue = "\(remaining)"
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if cancelled { break }
            }
            if cancelled { break }
        }
        panel.orderOut(nil)
        // Give the window server a moment to remove the panel before capturing.
        try? await Task.sleep(nanoseconds: 120_000_000)
        return !cancelled
    }
}

private final class CountdownBackground: NSView {
    var onClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.72).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 28, yRadius: 28).fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

enum TextRecognizer {
    /// Recognised text (top-to-bottom) plus any QR/barcode payloads.
    static func recognize(_ image: CGImage) async -> String {
        await Task.detached(priority: .userInitiated) { () -> String in
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            textRequest.automaticallyDetectsLanguage = true
            let barcodeRequest = VNDetectBarcodesRequest()

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([textRequest, barcodeRequest])
            } catch {
                NSLog("Glimpse: OCR failed: \(error)")
                return ""
            }

            var parts: [String] = []
            let codes = (barcodeRequest.results ?? []).compactMap { $0.payloadStringValue }
            parts.append(contentsOf: codes)

            // Vision uses a bottom-left origin: sort top to bottom, then merge observations sharing a line.
            let observations = (textRequest.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            var groups: [[VNRecognizedTextObservation]] = []
            for obs in observations {
                if let last = groups.last?.first,
                   abs(last.boundingBox.midY - obs.boundingBox.midY) <= min(last.boundingBox.height, obs.boundingBox.height) * 0.5 {
                    groups[groups.count - 1].append(obs)
                } else {
                    groups.append([obs])
                }
            }
            let lines = groups.map { group in
                group.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
            }.filter { !$0.isEmpty }
            let text = lines.joined(separator: "\n")
            if !text.isEmpty && !codes.contains(text) { parts.append(text) }
            return parts.joined(separator: "\n\n")
        }.value
    }
}
