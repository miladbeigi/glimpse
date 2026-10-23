import AppKit
import MeetingDetection
import SwiftUI

final class EndPromptModel: ObservableObject {
    @Published var remaining: TimeInterval
    @Published var recordingElapsed: TimeInterval
    @Published var snapshot: DetectionSnapshot
    let total: TimeInterval
    let quietPeriod: TimeInterval
    let meetingTitle: String
    var onEnd: (() -> Void)?
    var onKeep: (() -> Void)?

    init(total: TimeInterval, quietPeriod: TimeInterval, meetingTitle: String, recordingElapsed: TimeInterval, snapshot: DetectionSnapshot) {
        self.total = total
        self.remaining = total
        self.quietPeriod = quietPeriod
        self.meetingTitle = meetingTitle
        self.recordingElapsed = recordingElapsed
        self.snapshot = snapshot
    }
}

struct EndPromptView: View {
    @ObservedObject var model: EndPromptModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        AppBadge(accent: UITheme.green, size: 46)
                        Text("Glimpse").font(.system(size: 14)).foregroundColor(UITheme.secondaryText)
                    }
                    Text("Still Recording").font(.system(size: 28, weight: .bold)).foregroundColor(.white)
                    Text("Meeting may have ended").font(.system(size: 17, weight: .semibold)).foregroundColor(UITheme.orange)
                    Text("No activity detected for \(Int(model.quietPeriod)) seconds. Glimpse will stop recording unless you keep it running.")
                        .font(.system(size: 13)).foregroundColor(UITheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 20)
                countdown
            }
            Divider().background(UITheme.hairline)
            HStack(spacing: 12) {
                MeetingChip(title: model.meetingTitle)
                Rectangle().fill(UITheme.hairline).frame(width: 1, height: 24)
                Chip(text: "Recording \(formatDuration(model.recordingElapsed))") {
                    Circle().fill(UITheme.red).frame(width: 9, height: 9)
                }
                .fixedSize()
            }
            HStack(spacing: 10) {
                signalChip(icon: "mic", text: model.snapshot.vad.isActive ? "Audio active" : "Audio quiet", quiet: !model.snapshot.vad.isActive)
                signalChip(icon: "macwindow", text: model.snapshot.window.isActive ? "Window open" : "Window quiet", quiet: !model.snapshot.window.isActive)
                signalChip(icon: "dot.radiowaves.left.and.right", text: model.snapshot.webrtc.isActive ? "Network active" : "Network idle", quiet: !model.snapshot.webrtc.isActive)
                signalChip(icon: model.snapshot.camera.isActive ? "video" : "video.slash", text: model.snapshot.camera.isActive ? "Camera on" : "Camera off", quiet: !model.snapshot.camera.isActive)
            }
            HStack(spacing: 14) {
                Button("End Recording") { model.onEnd?() }
                    .buttonStyle(OverlayButtonStyle(kind: .secondaryDestructive, height: 42))
                Button("Keep Recording") { model.onKeep?() }
                    .buttonStyle(OverlayButtonStyle(kind: .primary, height: 42))
            }
        }
        .padding(26)
        .background(GlassBackground(cornerRadius: 24))
    }

    private var countdown: some View {
        let fraction = model.total > 0 ? model.remaining / model.total : 0
        return ZStack {
            Circle().stroke(UITheme.orange.opacity(0.18), lineWidth: 8)
            Circle()
                .trim(from: 0, to: CGFloat(fraction))
                .stroke(LinearGradient(colors: [UITheme.yellow, UITheme.orange], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: UITheme.orange.opacity(0.5), radius: 6)
                .animation(.linear(duration: 0.5), value: fraction)
            VStack(spacing: 2) {
                Text("Auto-stopping in").font(.system(size: 12)).foregroundColor(UITheme.secondaryText)
                Text("\(Int(model.remaining.rounded(.up)))s").font(.system(size: 40, weight: .bold)).foregroundColor(UITheme.yellow)
                    .monospacedDigit()
            }
        }
        .frame(width: 170, height: 170)
    }

    private func signalChip(icon: String, text: String, quiet: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(UITheme.secondaryText)
            Text(text).font(.system(size: 12.5, weight: .semibold)).foregroundColor(.white).lineLimit(1)
            Circle().fill(quiet ? UITheme.green : UITheme.orange).frame(width: 7, height: 7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(UITheme.chipFill))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(UITheme.chipStroke, lineWidth: 1))
        .fixedSize()
    }
}

/// End-of-meeting prompt, centered on the active screen at `.modalPanel` level.
@MainActor
final class EndPromptController {
    static let shared = EndPromptController()
    static let width: CGFloat = 640

    private var panel: OverlayPanel?
    private(set) var model: EndPromptModel?
    private var timer: Timer?
    private var deadline = Date()
    private var recordingStart = Date()

    var isVisible: Bool { panel != nil }

    /// - Parameter onTimeout: called when the countdown reaches zero.
    func show(timeout: TimeInterval, quietPeriod: TimeInterval, meetingTitle: String, recordingStartedAt: Date,
              snapshot: DetectionSnapshot, onEnd: @escaping () -> Void, onKeep: @escaping () -> Void, onTimeout: @escaping () -> Void) {
        close()
        let model = EndPromptModel(total: timeout, quietPeriod: quietPeriod, meetingTitle: meetingTitle,
                                   recordingElapsed: Date().timeIntervalSince(recordingStartedAt), snapshot: snapshot)
        model.onEnd = onEnd
        model.onKeep = onKeep
        self.model = model
        deadline = Date().addingTimeInterval(timeout)
        recordingStart = recordingStartedAt

        let panel = OverlayPanel(level: .modalPanel)
        let size = panel.host(EndPromptView(model: model), width: Self.width)
        let screen = activeScreen().visibleFrame
        panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let model = self.model else { return }
                model.remaining = max(0, self.deadline.timeIntervalSinceNow)
                model.recordingElapsed = Date().timeIntervalSince(self.recordingStart)
                if model.remaining <= 0 {
                    self.close()
                    onTimeout()
                }
            }
        }
    }

    func updateSignals(_ snapshot: DetectionSnapshot) {
        model?.snapshot = snapshot
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }
}
