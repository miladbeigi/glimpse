import AppKit
import SwiftUI

final class RecordingIndicatorModel: ObservableObject {
    static let barCount = 26
    @Published var levels: [Float] = Array(repeating: 0, count: barCount)
    @Published var elapsed: TimeInterval = 0
    @Published var isPaused = false
    @Published var isMuted = false
    var onStop: (() -> Void)?
    /// nil hides the mute button.
    var onMuteToggle: (() -> Void)?
    /// nil hides the pause button.
    var onPauseToggle: (() -> Void)?

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }
}

struct RecordingIndicatorView: View {
    @ObservedObject var model: RecordingIndicatorModel

    var body: some View {
        HStack(spacing: 6) {
            BarGrip()
            BarTimer(elapsed: formatDuration(model.elapsed), paused: model.isPaused)
            if model.isMuted {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(UITheme.red)
                    .frame(height: 18)
                    .help("Microphone muted")
            } else {
                BarLevelMeter(level: model.isPaused ? 0 : model.levels.last ?? 0)
            }
            BarDivider()
            if let toggle = model.onMuteToggle {
                BarButton(symbol: model.isMuted ? "mic.slash.fill" : "mic.fill",
                          tint: model.isMuted ? UITheme.red : nil,
                          help: model.isMuted ? "Unmute Microphone (⌃⌥M)" : "Mute Microphone (⌃⌥M)", action: toggle)
            }
            if let toggle = model.onPauseToggle {
                BarButton(symbol: model.isPaused ? "play.fill" : "pause.fill",
                          help: model.isPaused ? "Resume Recording" : "Pause Recording", action: toggle)
            }
            BarStopButton(help: "Stop Recording") { model.onStop?() }
        }
        .compactBar(alert: model.isMuted)
        .padding(10)
    }
}

/// Compact pill shown while the mic is muted and no recording pill is on screen, so a
/// system-wide mute is never invisible.
struct MuteBadgeView: View {
    var onUnmute: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            BarGrip()
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UITheme.red)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) {
                Text("Microphone muted").font(.system(size: 12, weight: .semibold))
                Text("All apps · ⌃⌥M").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.trailing, 4)
            BarDivider()
            Button(action: onUnmute) {
                Text("Unmute").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(.white.opacity(0.14)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Unmute Microphone (⌃⌥M)")
        }
        .compactBar(alert: true)
        .padding(10)
    }
}

@MainActor
final class MuteBadge {
    static let shared = MuteBadge()
    private var panel: OverlayPanel?
    var isVisible: Bool { panel != nil }

    func show(onUnmute: @escaping () -> Void) {
        guard panel == nil else { return }
        let panel = OverlayPanel(level: .statusBar)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = true
        let hosting = NSHostingView(rootView: MuteBadgeView(onUnmute: onUnmute))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        let visible = activeScreen().visibleFrame
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + 14, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Recording pill: bottom-center of the active screen above the Dock.
@MainActor
final class RecordingIndicator: NSObject, NSWindowDelegate {
    static let shared = RecordingIndicator()

    private var panel: OverlayPanel?
    private let model = RecordingIndicatorModel()
    private var tickTimer: Timer?
    private var followTimer: Timer?
    private var startedAt = Date()
    private var userMoved = false
    private var programmaticMove = false
    private var wasOverHour = false
    private var syntheticLevels = false
    private var pausedAt: Date?

    var isVisible: Bool { panel != nil }

    /// - Parameters:
    ///   - synthetic: animate a fake waveform (dev instance)
    ///   - onPauseToggle: the pause/resume button's action (nil hides the button)
    ///   - onStop: the stop button's action for this recording
    func show(startedAt: Date, synthetic: Bool = false, isMuted: Bool = false, onMuteToggle: (() -> Void)? = nil,
              onPauseToggle: (() -> Void)? = nil, onStop: @escaping () -> Void) {
        hide()
        model.onStop = onStop
        model.onMuteToggle = onMuteToggle
        model.isMuted = isMuted
        model.onPauseToggle = onPauseToggle
        model.isPaused = false
        pausedAt = nil
        self.startedAt = startedAt
        syntheticLevels = synthetic
        userMoved = false
        model.levels = Array(repeating: 0, count: RecordingIndicatorModel.barCount)
        model.elapsed = Date().timeIntervalSince(startedAt)
        wasOverHour = model.elapsed >= 3600

        let panel = OverlayPanel(level: .statusBar)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = true
        panel.delegate = self
        self.panel = panel
        rehost()
        position()
        panel.orderFrontRegardless()

        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        followTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.userMoved else { return }
                self.position()
            }
        }
    }

    func hide() {
        tickTimer?.invalidate()
        followTimer?.invalidate()
        tickTimer = nil
        followTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    func setMuted(_ muted: Bool) {
        model.isMuted = muted
    }

    /// Pill frame on screen.
    var frame: NSRect? { panel?.frame }

    /// Called when the pill moves, so attached panels can follow.
    var onMove: (() -> Void)?

    /// Freeze the timer and dim the waveform; on resume the paused time is excluded.
    func setPaused(_ paused: Bool) {
        guard paused != model.isPaused else { return }
        if paused {
            pausedAt = Date()
        } else if let pausedAt {
            startedAt = startedAt.addingTimeInterval(Date().timeIntervalSince(pausedAt))
            self.pausedAt = nil
        }
        model.isPaused = paused
    }

    func push(level: Float) {
        guard !syntheticLevels, !model.isPaused else { return }
        model.push(level: level)
    }

    private func tick() {
        model.elapsed = (pausedAt ?? Date()).timeIntervalSince(startedAt)
        if syntheticLevels && !model.isPaused {
            let t = Date().timeIntervalSinceReferenceDate
            let v = Float(0.45 + 0.35 * sin(t * 3.1) * sin(t * 1.3) + Double.random(in: -0.15...0.15))
            model.push(level: max(0.05, min(1, v)))
        }
        // Grow once at the 1 h mark and re-center.
        let overHour = model.elapsed >= 3600
        if overHour != wasOverHour {
            wasOverHour = overHour
            rehost()
            if !userMoved { position() }
        }
    }

    private func rehost() {
        guard let panel else { return }
        let hosting = NSHostingView(rootView: RecordingIndicatorView(model: model))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        var frame = panel.frame
        let midX = frame.midX
        frame.size = size
        frame.origin.x = midX - size.width / 2
        programmaticMove = true
        panel.setFrame(frame, display: true)
        programmaticMove = false
    }

    private func position() {
        guard let panel else { return }
        let visible = activeScreen().visibleFrame
        let size = panel.frame.size
        programmaticMove = true
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 14))
        programmaticMove = false
        onMove?()
    }

    nonisolated func windowDidMove(_ notification: Notification) {
        MainActor.assumeIsolated {
            if !programmaticMove { userMoved = true }
            onMove?()
        }
    }
}
