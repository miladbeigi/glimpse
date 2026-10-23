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
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                .overlay(
                    Group {
                        if model.isMuted {
                            Image(systemName: "mic.slash.fill").font(.system(size: 17, weight: .semibold)).foregroundColor(UITheme.red)
                        } else {
                            HStack(spacing: 5) {
                                WaveGlyph(color: UITheme.green, height: 12)
                                Image(systemName: "mic").font(.system(size: 17, weight: .medium)).foregroundColor(.white)
                                WaveGlyph(color: UITheme.green, heights: [0.4, 0.85, 0.55, 1.0, 0.7, 0.35], height: 12)
                            }
                        }
                    }
                )
                .frame(width: 60, height: 40)

            HStack(alignment: .center, spacing: 3) {
                ForEach(model.levels.indices, id: \.self) { i in
                    Capsule().fill(model.isPaused || model.isMuted ? Color.white.opacity(0.25) : UITheme.green)
                        .frame(width: 3.5, height: model.isPaused ? 4 : 4 + CGFloat(model.levels[i]) * 30)
                        .animation(.easeOut(duration: 0.12), value: model.levels[i])
                }
            }
            .frame(height: 36)

            HStack(spacing: 10) {
                if model.isPaused {
                    Image(systemName: "pause.fill").font(.system(size: 10, weight: .bold)).foregroundColor(UITheme.yellow).frame(width: 10, height: 10)
                } else {
                    Circle().fill(UITheme.red).frame(width: 10, height: 10)
                }
                ZStack(alignment: .leading) {
                    // Reserve width so digits never wrap or jitter.
                    Text(model.elapsed >= 3600 ? "8:88:88" : "88:88").hidden()
                    Text(formatDuration(model.elapsed))
                }
                .font(.system(size: 19, weight: .bold).monospacedDigit())
                .foregroundColor(model.isPaused ? UITheme.secondaryText : .white)
                .lineLimit(1)
                .fixedSize()
            }

            if let toggle = model.onMuteToggle {
                MuteButton(isMuted: model.isMuted, action: toggle)
            }

            if let toggle = model.onPauseToggle {
                Button(action: toggle) {
                    Circle().fill(Color.white.opacity(0.10))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                        .overlay(
                            Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(model.isPaused ? UITheme.green : .white)
                        )
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .help(model.isPaused ? "Resume Recording" : "Pause Recording")
            }

            Button(action: { model.onStop?() }) {
                Circle().fill(Color.white.opacity(0.10))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    .overlay(RoundedRectangle(cornerRadius: 3).fill(UITheme.red).frame(width: 15, height: 15))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .help("Stop Recording")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(UITheme.tint.opacity(0.92))
                .overlay(Capsule().fill(UITheme.red.opacity(model.isMuted ? 0.14 : 0)))
                .overlay(Capsule().strokeBorder(model.isMuted ? UITheme.red.opacity(0.55) : UITheme.stroke, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        )
        .padding(10)
        .fixedSize()
    }
}

/// Circular mic button: white mic when live, red crossed-out mic when muted.
struct MuteButton: View {
    var isMuted: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle().fill(isMuted ? UITheme.red.opacity(0.85) : Color.white.opacity(0.10))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .overlay(
                    Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                )
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .help(isMuted ? "Unmute Microphone (⌃⌥M)" : "Mute Microphone (⌃⌥M)")
    }
}

/// Compact pill shown while the mic is muted and no recording pill is on screen, so a
/// system-wide mute is never invisible.
struct MuteBadgeView: View {
    var onUnmute: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.slash.fill").font(.system(size: 16, weight: .semibold)).foregroundColor(UITheme.red)
            VStack(alignment: .leading, spacing: 1) {
                Text("Microphone muted").font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                Text("All apps · ⌃⌥M to toggle").font(.system(size: 11)).foregroundColor(UITheme.secondaryText)
            }
            MuteButton(isMuted: true, action: onUnmute)
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(UITheme.tint.opacity(0.92))
                .overlay(Capsule().fill(UITheme.red.opacity(0.14)))
                .overlay(Capsule().strokeBorder(UITheme.red.opacity(0.55), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        )
        .padding(10)
        .fixedSize()
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
        panel.isMovableByWindowBackground = true
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
        panel.isMovableByWindowBackground = true
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
