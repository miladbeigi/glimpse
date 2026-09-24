import AppKit
import ScreenCaptureKit
import SwiftUI

@MainActor
final class ScrollingSessionState: ObservableObject {
    @Published var autoScroll = false
    @Published var height = 0
    @Published var frames = 0
    @Published var message = "Scroll the content, then press Done"
}

/// Captures a region repeatedly while the user (or auto-scroll) scrolls, stitching frames together.
@MainActor
final class ScrollingCaptureSession {
    private let screen: NSScreen
    private let rect: CGRect // local top-left points
    private let state = ScrollingSessionState()
    private let stitcher = Stitcher()
    private var borderWindow: NSWindow?
    private var controlPanel: NSPanel?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var running = false
    private var scrollDirection: Int32 = -1
    private var autoStepsWithoutChange = 0
    private var autoStepsTotal = 0
    private var consecutiveNoMatch = 0
    private var escMonitors: [Any] = []

    private let startAutoScroll: Bool

    init(screen: NSScreen, rect: CGRect, startAutoScroll: Bool = false) {
        self.screen = screen
        self.rect = rect.integral
        self.startAutoScroll = startAutoScroll
    }

    /// Returns the stitched image, or nil if cancelled.
    func run() async -> CGImage? {
        // Show our windows first so Glimpse is listed in the shareable content and gets excluded.
        showChrome()
        let filter: SCContentFilter
        do {
            filter = try ScreenCapture.displayFilter(for: screen, content: try await ScreenCapture.shareableContent())
        } catch {
            hideChrome()
            HUD.show("Scrolling capture failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            return nil
        }
        installEscapeMonitors()
        running = true
        if startAutoScroll { toggleAutoScroll() }
        let loop = Task { await captureLoop(filter: filter) }
        let accepted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            continuation = cont
        }
        running = false
        _ = await loop.value
        removeEscapeMonitors()
        hideChrome()
        guard accepted else { return nil }
        return stitcher.makeImage()
    }

    private func finish(_ accepted: Bool) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: accepted)
    }

    private func captureLoop(filter: SCContentFilter) async {
        var isFirstFrame = true
        while running {
            // Always grab the untouched first frame before any auto-scrolling.
            if isFirstFrame {
                isFirstFrame = false
            } else if state.autoScroll {
                postScroll()
                try? await Task.sleep(nanoseconds: 280_000_000)
            } else {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard running else { break }
            guard let frame = try? await ScreenCapture.captureRect(rect, on: screen, filter: filter) else { continue }
            guard running else { break }
            let stitcher = self.stitcher
            let result = await Task.detached(priority: .userInitiated) { stitcher.add(frame) }.value
            state.frames += 1
            state.height = stitcher.height
            trackMatch(result)
            handleAutoScroll(result)
            if stitcher.isFull {
                state.message = "Maximum height reached"
                finish(true)
            }
        }
    }

    private func trackMatch(_ result: Stitcher.AddResult) {
        if result == .noMatch {
            consecutiveNoMatch += 1
            if consecutiveNoMatch >= 3 {
                state.message = "Scrolled too fast — scroll back up a little"
                if state.autoScroll { state.autoScroll = false }
            }
        } else {
            if consecutiveNoMatch >= 3 {
                state.message = state.autoScroll ? "Auto-scrolling…" : "Scroll the content, then press Done"
            }
            consecutiveNoMatch = 0
        }
    }

    private func handleAutoScroll(_ result: Stitcher.AddResult) {
        guard state.autoScroll else { return }
        autoStepsTotal += 1
        switch result {
        case .appended(let rows) where rows > 0:
            autoStepsWithoutChange = 0
        case .first, .noMatch:
            break
        default:
            autoStepsWithoutChange += 1
        }
        // Nothing moved on the first attempts: the page may interpret the event direction the other way.
        if autoStepsTotal == 2 && autoStepsWithoutChange >= 2 && stitcher.height <= Int(rect.height * screen.backingScaleFactor) {
            scrollDirection = -scrollDirection
            autoStepsWithoutChange = 0
            return
        }
        if autoStepsWithoutChange >= 4 {
            state.message = "Reached the end"
            finish(true)
        }
    }

    private var cgCenter: CGPoint {
        CGPoint(x: screen.cgFrame.minX + rect.midX, y: screen.cgFrame.minY + rect.midY)
    }

    private func postScroll() {
        let center = cgCenter
        // If the user moved the pointer away (e.g. towards Stop/Done), pause instead of pulling it back.
        let local = screen.localTopLeft(fromGlobal: NSEvent.mouseLocation)
        guard rect.contains(local) else {
            state.autoScroll = false
            state.message = "Auto-scroll paused"
            return
        }
        let delta = Int32(max(30, rect.height * 0.3)) * scrollDirection
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: delta, wheel2: 0, wheel3: 0) else { return }
        event.location = center
        event.post(tap: .cghidEventTap)
    }

    fileprivate func toggleAutoScroll() {
        if !state.autoScroll {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            guard AXIsProcessTrustedWithOptions(options) else {
                NSLog("Glimpse scroll: Accessibility not granted; auto-scroll unavailable")
                state.message = "Allow Accessibility access for auto-scroll"
                return
            }
            autoStepsWithoutChange = 0
            autoStepsTotal = 0
            CGWarpMouseCursorPosition(cgCenter)
            state.message = "Auto-scrolling…"
        } else {
            state.message = "Scroll the content, then press Done"
        }
        state.autoScroll.toggle()
    }

    private func installEscapeMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == 53 else { return } // Esc
            Task { @MainActor in self?.finish(false) }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { escMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in handler(event); return event }) {
            escMonitors.append(m)
        }
    }

    private func removeEscapeMonitors() {
        escMonitors.forEach(NSEvent.removeMonitor)
        escMonitors.removeAll()
    }

    // MARK: Chrome

    private func showChrome() {
        let global = screen.globalRect(fromLocalTopLeft: rect)
        let border = NSWindow(contentRect: global.insetBy(dx: -3, dy: -3), styleMask: [.borderless], backing: .buffered, defer: false)
        border.level = .statusBar
        border.isOpaque = false
        border.backgroundColor = .clear
        border.ignoresMouseEvents = true
        border.hasShadow = false
        border.isReleasedWhenClosed = false
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        border.contentView = DashedBorderView()
        border.orderFrontRegardless()
        borderWindow = border

        let host = NSHostingView(rootView: ScrollingControls(
            state: state,
            onAuto: { [weak self] in self?.toggleAutoScroll() },
            onDone: { [weak self] in self?.finish(true) },
            onCancel: { [weak self] in self?.finish(false) }))
        let size = host.fittingSize
        let vf = screen.visibleFrame
        var origin = NSPoint(x: global.midX - size.width / 2, y: global.minY - size.height - 12)
        if origin.y < vf.minY + 4 { origin.y = global.maxY + 12 }
        if origin.y + size.height > vf.maxY - 4 { origin.y = global.minY + 12 }
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)

        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.orderFrontRegardless()
        controlPanel = panel
    }

    private func hideChrome() {
        borderWindow?.orderOut(nil)
        controlPanel?.orderOut(nil)
        borderWindow = nil
        controlPanel = nil
    }
}

private final class DashedBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 2
        NSColor.black.withAlphaComponent(0.5).setStroke()
        path.stroke()
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}

private struct ScrollingControls: View {
    @ObservedObject var state: ScrollingSessionState
    let onAuto: () -> Void
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Scrolling Capture").font(.system(size: 12, weight: .semibold))
                Text(state.message).font(.system(size: 11)).foregroundStyle(.secondary)
                Text("\(state.height) px").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
            }
            .frame(width: 210, alignment: .leading)
            Button(action: onAuto) {
                Label(state.autoScroll ? "Stop" : "Auto-scroll",
                      systemImage: state.autoScroll ? "pause.fill" : "arrow.down.circle")
            }
            Button("Cancel", action: onCancel)
            Button("Done", action: onDone).buttonStyle(.borderedProminent)
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
