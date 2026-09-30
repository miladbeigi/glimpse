import AppKit
import Combine
import SwiftUI

/// The border around the recorded area and the floating control bar. Neither appears in the recording.
@MainActor
final class RecordingChrome {
    private let target: RecordingTarget
    private weak var controller: RecordingController?
    private var borderWindow: NSWindow?
    private var controlPanel: NSPanel?
    private var observer: AnyCancellable?

    init(target: RecordingTarget, controller: RecordingController) {
        self.target = target
        self.controller = controller
    }

    func show() {
        guard let controller else { return }
        if !target.isFullScreen {
            let border = NSWindow(contentRect: target.globalRect.insetBy(dx: -3, dy: -3), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            border.level = .statusBar
            border.isOpaque = false
            border.backgroundColor = .clear
            border.ignoresMouseEvents = true
            border.hasShadow = false
            border.isReleasedWhenClosed = false
            border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            border.contentView = DashedBorderView()
            border.orderFrontRegardless()
            borderWindow = border
        }

        let host = FirstMouseHostingView(rootView: RecordingControlsView(controller: controller, target: target))
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = host
        panel.setFrameOrigin(initialOrigin(for: host.fittingSize))
        panel.orderFrontRegardless()
        controlPanel = panel

        // Each phase has different controls: keep the bar centred on where it was.
        observer = controller.$phase.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitControls() }
        }
    }

    /// Below the area if there's room, otherwise inside its bottom edge.
    private func initialOrigin(for size: NSSize) -> NSPoint {
        let vf = target.screen.visibleFrame
        let area = target.globalRect
        var origin = NSPoint(x: area.midX - size.width / 2, y: area.minY - size.height - 14)
        if origin.y < vf.minY + 8 { origin.y = max(area.minY, vf.minY) + 24 }
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        return origin
    }

    private func fitControls() {
        guard let panel = controlPanel, let host = panel.contentView else { return }
        let size = host.fittingSize
        let old = panel.frame
        guard old.size != size else { return }
        panel.setFrame(NSRect(x: old.midX - size.width / 2, y: old.minY, width: size.width, height: size.height), display: true)
    }

    func setControlsHidden(_ hidden: Bool) {
        if hidden { controlPanel?.orderOut(nil) } else { controlPanel?.orderFrontRegardless() }
    }

    func hideAreaBorder() {
        borderWindow?.orderOut(nil)
    }

    func close() {
        observer = nil
        borderWindow?.orderOut(nil)
        controlPanel?.orderOut(nil)
        borderWindow = nil
        controlPanel = nil
    }
}

/// Lets the first click on a non-activating panel press its buttons.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct RecordingControlsView: View {
    @ObservedObject var controller: RecordingController
    let target: RecordingTarget

    var body: some View {
        HStack(spacing: 6) {
            switch controller.phase {
            case .recording, .paused: recording
            case .saving: saving
            default: ready
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .fixedSize()
    }

    private var sizeLabel: String {
        target.isFullScreen ? "Full Screen" : "\(Int(target.rect.width)) × \(Int(target.rect.height))"
    }

    @ViewBuilder private var ready: some View {
        ControlButton(symbol: controller.cameraOn ? "video.fill" : "video.slash.fill", active: controller.cameraOn,
                      help: controller.cameraOn ? "Turn camera off" : "Turn camera on") {
            controller.setCamera(!controller.cameraOn)
        }
        ControlButton(symbol: controller.micOn ? "mic.fill" : "mic.slash.fill", active: controller.micOn,
                      help: controller.micOn ? "Don't record the microphone" : "Record the microphone") {
            controller.setMicrophone(!controller.micOn)
        }
        ControlButton(symbol: controller.systemAudioOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                      active: controller.systemAudioOn,
                      help: controller.systemAudioOn ? "Don't record system audio" : "Record system audio") {
            controller.setSystemAudio(!controller.systemAudioOn)
        }
        Divider().frame(height: 22).padding(.horizontal, 2)
        Text(sizeLabel)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        Button { controller.start() } label: {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text("Start Recording").font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(.white.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(controller.phase != .ready)
        ControlButton(symbol: "xmark", help: "Cancel (Esc)") { controller.discard() }
    }

    @ViewBuilder private var recording: some View {
        HStack(spacing: 7) {
            if controller.phase == .paused {
                Image(systemName: "pause.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.orange)
            } else {
                RecordingDot()
            }
            Text(RecordingGeometry.formatDuration(controller.elapsed))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .frame(minWidth: 38, alignment: .leading)
        }
        .padding(.leading, 6)
        if controller.micOn {
            LevelMeter(level: controller.phase == .paused ? 0 : controller.micLevel)
                .help("Microphone level")
        }
        Divider().frame(height: 22).padding(.horizontal, 2)
        ControlButton(symbol: controller.phase == .paused ? "play.fill" : "pause.fill",
                      help: controller.phase == .paused ? "Resume" : "Pause") { controller.togglePause() }
        ControlButton(symbol: "arrow.counterclockwise", help: "Restart") { controller.restart() }
        ControlButton(symbol: controller.cameraOn ? "video.fill" : "video.slash.fill", active: controller.cameraOn,
                      help: controller.cameraOn ? "Hide camera" : "Show camera") {
            controller.setCamera(!controller.cameraOn)
        }
        ControlButton(symbol: "trash", help: "Discard") { controller.discard() }
        Button { controller.stop() } label: {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 9, height: 9)
                Text("Stop").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(Color.red))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Stop and save")
    }

    @ViewBuilder private var saving: some View {
        ProgressView().controlSize(.small)
        Text("Saving recording…").font(.system(size: 12, weight: .medium)).padding(.trailing, 6)
    }
}

private struct ControlButton: View {
    let symbol: String
    var active = true
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(hovered ? 0.14 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

private struct RecordingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 10, height: 10)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// Five bars that light up with the microphone level.
private struct LevelMeter: View {
    let level: Float

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5) { i in
                let on = level > Float(i) / 5 + 0.02
                RoundedRectangle(cornerRadius: 1)
                    .fill(on ? Color.green : Color.white.opacity(0.2))
                    .frame(width: 3, height: 6 + CGFloat(i) * 2.5)
            }
        }
        .frame(height: 18)
        .animation(.linear(duration: 0.1), value: level)
    }
}
