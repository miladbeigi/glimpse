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

        let content = HUDContent(text: text, symbol: symbol, maxWidth: 520)
        let width = min(max(content.fittingWidth, 120), 520)
        let height = content.height
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
        content.frame = bg.bounds
        content.autoresizingMask = [.width, .height]
        bg.addSubview(content)
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

/// The toast's icon and text, drawn so both sit on the pill's centre line: the icon by its middle, one line of text
/// by the middle of its capitals (a label's frame also holds the descenders, which pushes the words off centre).
/// Text too long for one line wraps to two in a taller pill, so a hint or an error's details aren't cut off.
private final class HUDContent: NSView {
    private let text: String
    private let icon: NSImage?
    /// Whether the text needs two lines to fit `maxWidth`.
    private let wraps: Bool
    private static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let left: CGFloat = 16, right: CGFloat = 18, gap: CGFloat = 8
    private static let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
    private var attributes: [NSAttributedString.Key: Any] { [.font: Self.font, .foregroundColor: NSColor.white] }

    init(text: String, symbol: String, maxWidth: CGFloat) {
        // Drawn as one line, anything after a newline would vanish.
        self.text = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white])))
        let iconWidth = icon.map { $0.size.width + Self.gap } ?? 0
        let textWidth = (self.text as NSString).size(withAttributes: [.font: Self.font]).width
        wraps = Self.left + iconWidth + textWidth + Self.right > maxWidth
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var iconWidth: CGFloat { icon.map { $0.size.width + Self.gap } ?? 0 }

    var fittingWidth: CGFloat {
        (Self.left + iconWidth + (text as NSString).size(withAttributes: attributes).width + Self.right).rounded(.up)
    }

    var height: CGFloat { wraps ? (Self.lineHeight * 2 + 20).rounded(.up) : 40 }

    override func draw(_ dirtyRect: NSRect) {
        let mid = bounds.midY
        var x = Self.left
        if let icon {
            let s = icon.size
            icon.draw(in: NSRect(x: x, y: mid - s.height / 2, width: s.width, height: s.height))
            x += iconWidth
        }
        let width = bounds.width - x - Self.right
        if wraps {
            // Two lines at most, centred as a block; the second ends in "…" if it still doesn't fit.
            let height = Self.lineHeight * 2
            (text as NSString).draw(with: NSRect(x: x, y: mid - height / 2, width: width, height: height),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
            return
        }
        let line = fitted(text, width: width) as NSString
        // Without .usesLineFragmentOrigin the rect's origin is the baseline.
        let baseline = mid - Self.font.capHeight / 2
        line.draw(with: NSRect(x: x, y: baseline, width: width, height: 0), options: [], attributes: attributes)
    }

    /// The text, cut short with an ellipsis if it's wider than `width`.
    private func fitted(_ s: String, width: CGFloat) -> String {
        func w(_ t: String) -> CGFloat { (t as NSString).size(withAttributes: attributes).width }
        guard w(s) > width else { return s }
        var t = s
        while !t.isEmpty, w(t + "…") > width { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Big countdown number in the middle of the screen. Click it to cancel.
@MainActor
final class Countdown {
    /// Centred on `rect` (Cocoa global) if given, else on the screen.
    static func run(seconds: Int, on screen: NSScreen, centeredOn rect: NSRect? = nil) async -> Bool {
        guard seconds > 0 else { return true }
        let countdown = Countdown(screen: screen, center: rect.map { NSPoint(x: $0.midX, y: $0.midY) })
        active = countdown
        defer { if active === countdown { active = nil } }
        return await countdown.start(seconds: seconds)
    }

    private static weak var active: Countdown?

    /// Cancels a running countdown (its `run` returns false).
    static func cancelActive() {
        active?.cancelled = true
    }

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var cancelled = false

    private init(screen: NSScreen, center: NSPoint? = nil) {
        let size: CGFloat = 150
        let c = center ?? NSPoint(x: screen.frame.midX, y: screen.frame.midY)
        let frame = NSRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)
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

            // Vision misreads text in images with alpha (window captures have transparent corners).
            let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
            let handler = VNImageRequestHandler(cgImage: opaque ? image : ImageExporter.flattened(image) ?? image, options: [:])
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
