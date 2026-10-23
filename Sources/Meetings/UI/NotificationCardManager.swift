import AppKit
import SwiftUI

/// Stacks cards downward from the top-right corner of the active screen. Cards slide
/// in from the right and auto-dismiss after 15 s (paused while hovered); the processing card
/// stays until replaced.
@MainActor
final class NotificationCardManager {
    static let shared = NotificationCardManager()

    static let cardWidth: CGFloat = 500
    static let padding: CGFloat = 10  // transparent padding for the hover close button
    static let margin: CGFloat = 8
    static let autoDismiss: TimeInterval = 15

    private struct Entry {
        let model: CardModel
        let panel: OverlayPanel
        var remaining: TimeInterval
    }

    private var entries: [Entry] = []
    private var timer: Timer?
    private var screen: NSScreen?

    var onCancelRecording: (() -> Void)?

    @discardableResult
    func show(_ kind: CardKind, onRecord: (() -> Void)? = nil) -> UUID {
        let model = CardModel(kind: kind)
        model.onRecord = { [weak self] in
            self?.dismiss(model.id)
            onRecord?()
        }
        model.onCancelRecording = { [weak self] in self?.onCancelRecording?() }
        model.onOpenTranscript = { [weak self] url in
            NSWorkspace.shared.open(url)
            self?.dismiss(model.id)
        }
        model.onClose = { [weak self] in self?.dismiss(model.id) }

        let panel = OverlayPanel()
        let view = NotificationCardView(model: model)
        _ = panel.host(view, width: Self.cardWidth + Self.padding * 2)

        if entries.isEmpty { screen = activeScreen() }
        entries.append(Entry(model: model, panel: panel, remaining: Self.autoDismiss))
        layout(animatedEntry: model.id)
        startTimer()
        return model.id
    }

    /// Replace a card's content in place (e.g. processing → ready).
    func update(_ id: UUID, kind: CardKind) {
        guard let i = entries.firstIndex(where: { $0.model.id == id }) else { return }
        entries[i].model.kind = kind
        entries[i].remaining = Self.autoDismiss
        rehost(i)
        layout()
    }

    /// Update the processing card's progress without restarting its layout animation.
    func updateProgress(_ id: UUID, fraction: Double, status: String) {
        guard let i = entries.firstIndex(where: { $0.model.id == id }),
              case .processing(let title, _, _) = entries[i].model.kind else { return }
        entries[i].model.kind = .processing(title: title, status: status, fraction: fraction)
    }

    func contains(_ id: UUID) -> Bool { entries.contains { $0.model.id == id } }

    func kind(of id: UUID) -> CardKind? { entries.first { $0.model.id == id }?.model.kind }

    func dismiss(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.model.id == id }) else { return }
        let entry = entries.remove(at: i)
        slideOut(entry.panel)
        layout()
    }

    /// Dismiss all cards matching a predicate.
    func dismiss(where predicate: (CardKind) -> Bool) {
        for e in entries where predicate(e.model.kind) { dismiss(e.model.id) }
    }

    func dismissAll() {
        for e in entries { e.panel.orderOut(nil) }
        entries.removeAll()
        timer?.invalidate()
        timer = nil
    }

    private func rehost(_ i: Int) {
        let view = NotificationCardView(model: entries[i].model)
        let frame = entries[i].panel.frame
        let size = entries[i].panel.host(view, width: Self.cardWidth + Self.padding * 2)
        entries[i].panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    private func layout(animatedEntry: UUID? = nil) {
        let screen = self.screen ?? activeScreen()
        let visible = screen.visibleFrame
        var top = visible.maxY - Self.margin + Self.padding
        for entry in entries {
            let size = entry.panel.contentView?.fittingSize ?? entry.panel.frame.size
            let x = visible.maxX - size.width - Self.margin + Self.padding
            let target = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
            if entry.model.id == animatedEntry {
                entry.panel.setFrame(target.offsetBy(dx: size.width + 40, dy: 0), display: false)
                entry.panel.alphaValue = 0
                entry.panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.35
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    entry.panel.animator().setFrame(target, display: true)
                    entry.panel.animator().alphaValue = 1
                }
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    entry.panel.animator().setFrame(target, display: true)
                }
            }
            // Next card's visible top sits 8pt below this card's visible bottom.
            top = target.minY + Self.padding * 2 - 8
        }
    }

    private func slideOut(_ panel: OverlayPanel) {
        let frame = panel.frame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(frame.offsetBy(dx: frame.width + 40, dy: 0), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        var expired: [UUID] = []
        for i in entries.indices {
            let e = entries[i]
            if e.model.kind.isPersistent || e.model.hovering { continue }
            entries[i].remaining -= 0.5
            if entries[i].remaining <= 0 { expired.append(e.model.id) }
        }
        expired.forEach(dismiss)
        if entries.isEmpty {
            timer?.invalidate()
            timer = nil
            screen = nil
        }
    }
}
