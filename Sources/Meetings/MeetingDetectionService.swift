import Foundation
import MeetingDetection

/// Runs the detection loop: one snapshot per poll, fed to the state machine. Signal
/// collection runs on a background queue; events are delivered on the main actor.
@MainActor
final class MeetingDetectionService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastSnapshot = DetectionSnapshot()
    @Published private(set) var state: MeetingState = .idle

    /// Event sink (AppState).
    var onEvent: ((MeetingStateEvent, DetectionSnapshot) -> Void)?
    /// Whether a calendar event is current (provided by AppState).
    var calendarEventProvider: (() -> Bool)?
    /// Whether a recording is in progress (keeps VAD alive).
    var isRecordingProvider: (() -> Bool)?

    let machine: MeetingStateMachine
    private let collector: SignalCollector
    private let pollQueue = DispatchQueue(label: "glimpse.meetings.detection", qos: .utility)
    private var pollTimer: Timer?
    private var promptTimer: Timer?
    private var polling = false
    private var lastWindowDiagnostic = Date.distantPast
    private var config: DetectionConfig

    static let windowDiagnosticInterval: TimeInterval = 120

    init(config: DetectionConfig) {
        self.config = config
        self.machine = MeetingStateMachine(config: config)
        self.collector = SignalCollector(config: config)
        collector.log = { message in log(message) }
    }

    func apply(config: DetectionConfig) {
        self.config = config
        machine.config = config
        collector.apply(config: config)
        if isRunning { scheduleTimer() }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        scheduleTimer()
        log("🔍 Meeting detection started (poll \(Int(config.signalPollInterval))s, quiet \(Int(config.endDetectionQuietPeriod))s, prompt \(Int(config.endPromptTimeout))s)")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        promptTimer?.invalidate()
        promptTimer = nil
        isRunning = false
        collector.shutdown()
        log("🔍 Meeting detection stopped")
    }

    private func scheduleTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: config.signalPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        promptTimer?.invalidate()
        promptTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickPrompt() }
        }
    }

    private func poll() {
        guard !polling else { return }
        polling = true
        let calendarEvent = calendarEventProvider?() ?? false
        let keepVAD = isRecordingProvider?() ?? false
        let collector = self.collector
        pollQueue.async { [weak self] in
            let snapshot = collector.snapshot(calendarEvent: calendarEvent, keepVADAlive: keepVAD)
            DispatchQueue.main.async {
                self?.handle(snapshot)
            }
        }
    }

    private func handle(_ snapshot: DetectionSnapshot) {
        polling = false
        guard isRunning else { return }  // a poll that finished after stop()
        lastSnapshot = snapshot
        diagnoseWindows(snapshot)

        let wasSuppressed = machine.startSuppressed
        let events = machine.process(snapshot)
        if wasSuppressed && !machine.startSuppressed {
            log("👂 Start detection re-enabled (meeting signals cleared)")
        }
        state = machine.state
        for event in events {
            logEvent(event, snapshot)
            onEvent?(event, snapshot)
        }
    }

    private func tickPrompt() {
        guard isRunning else { return }
        for event in machine.tick() {
            state = machine.state
            logEvent(event, lastSnapshot)
            onEvent?(event, lastSnapshot)
        }
    }

    private func logEvent(_ event: MeetingStateEvent, _ snapshot: DetectionSnapshot) {
        switch event {
        case .meetingStarted: log("🔍 Meeting started [\(snapshot.logDescription)]")
        case .quietPeriodStarted: log("🔍 Quiet period started [\(snapshot.logDescription)]")
        case .quietPeriodAborted: log("🔍 Quiet period aborted (sustained activity) [\(snapshot.logDescription)]")
        case .promptUser:
            log("🔔 End prompt shown")
            log(String(format: "🔎 Signals at prompt: %@", snapshot.logDescription))
        case .meetingEnded: log("🔍 Meeting ended")
        }
    }

    /// When WebRTC is active but no meeting window matched, log candidate window titles so the
    /// patterns can be fixed from real data (throttled).
    private func diagnoseWindows(_ s: DetectionSnapshot) {
        guard s.webrtc.isActive, !s.window.isActive,
              Date().timeIntervalSince(lastWindowDiagnostic) >= Self.windowDiagnosticInterval else { return }
        lastWindowDiagnostic = Date()
        let collector = self.collector
        pollQueue.async {
            let titles = collector.window.candidateWindowTitles()
            log("🪟 WebRTC active (\(s.webrtcServices.joined(separator: ", "))) but no meeting window matched. Visible titles: \(titles.isEmpty ? "(none)" : titles.joined(separator: " | "))")
        }
    }

    // MARK: - Controls forwarded to the state machine

    func markMeetingActive() {
        machine.markMeetingActive()
        state = machine.state
    }

    func keepRecording() {
        machine.keepRecording()
        state = machine.state
    }

    func endMeeting() {
        machine.endMeeting()
        state = machine.state
    }

    func resetToIdle(suppressStart: Bool = false) {
        machine.resetToIdle(suppressStartUntilClear: suppressStart)
        state = machine.state
        if suppressStart { log("🙈 Start detection suppressed until the current meeting's signals clear") }
    }

    func promptRemaining() -> TimeInterval? { machine.promptRemaining() }

    /// Route recording-mic samples to the VAD detector.
    func setRecordingFeed(_ enabled: Bool) {
        collector.useExternalVADFeed(enabled)
    }

    nonisolated func ingestMicSamples(_ samples: [Float]) {
        collector.vad.ingest48k(samples)
    }

}
