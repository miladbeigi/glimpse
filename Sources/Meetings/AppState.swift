import AppKit
import Combine
import MeetingDetection

enum AppStatus: String {
    case idle = "Idle"
    case monitoring = "Monitoring"
    case recording = "Recording"
    case ending = "Ending"
    case paused = "Paused"
}

/// Central app state and orchestration.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var status: AppStatus = .idle
    @Published private(set) var currentMeeting: Meeting?
    /// Transcriptions running now (a new recording and a recovered one can overlap).
    @Published private var processingCount = 0
    var isProcessing: Bool { processingCount > 0 }
    /// False while meetings are turned off: nothing may start a recording.
    private(set) var isEnabled = true
    @Published private(set) var isPaused = false

    let settings = AppSettings.shared
    let calendar = CalendarService.shared
    let detector = MeetingDetector()
    let detection: MeetingDetectionService
    let cards = NotificationCardManager.shared
    let endPrompt = EndPromptController.shared
    let indicator = RecordingIndicator.shared
    let history = TranscriptionHistoryStore.shared
    let mute = MicMuteController.shared

    private var detectionCardId: UUID?
    private var cancellables = Set<AnyCancellable>()

    static let retryAttemptsKey = "startupTranscriptionRetryAttempts"
    static let maxStartupRetries = 2

    var isRecording: Bool { detector.isRecording }

    private init() {
        detection = MeetingDetectionService(config: AppSettings.shared.data.detectionConfig)
    }

    // MARK: - Lifecycle

    func start() {
        cards.onCancelRecording = { [weak self] in self?.cancelRecording() }
        detector.onLevel = { [weak self] level in self?.indicator.push(level: level) }
        let detection = self.detection
        detector.onMicSamples = { samples in detection.ingestMicSamples(samples) }

        detection.onEvent = { [weak self] event, snapshot in self?.handleDetection(event, snapshot) }
        detection.calendarEventProvider = { [weak self] in self?.currentCalendarMeeting() != nil }
        detection.isRecordingProvider = { [weak self] in self?.isRecording ?? false }

        mute.$isMuted
            .removeDuplicates()
            .sink { [weak self] muted in
                self?.indicator.setMuted(muted)
                self?.updateMuteBadge(muted: muted)
            }
            .store(in: &cancellables)

        settings.$data
            .removeDuplicates()
            .sink { [weak self] data in self?.applySettings(data) }
            .store(in: &cancellables)

        if MeetingsHost.isUITestMode {
            log("🐞 UI test mode: calendar polling, detection and startup recovery disabled")
            return
        }
        calendar.startPolling(intervalMinutes: settings.data.calendarRefreshMinutes)
        detection.start()
        updateStatus()
        Task {
            await recoverCrashedRecordings()
            await retryIncompleteTranscriptions()
        }
    }

    /// A crash mid-recording leaves raw spools behind; turn them into WAVs and transcribe them
    /// like a normal stop. Runs before any capture can start.
    private func recoverCrashedRecordings() async {
        let recovered = [Paths.inProgressRecordings, Paths.tempRecordings].flatMap {
            CombinedAudioCapture.recoverOrphans(in: $0)
        }
        for item in recovered {
            let cardId = cards.show(.processing(title: item.meeting.title, status: "Recovering recording from previous session…", fraction: 0.02))
            await process(url: item.wavURL, meeting: item.meeting, cardId: cardId)
        }
    }

    private var lastAppliedRefresh: Int?

    private func applySettings(_ data: SettingsData) {
        detection.apply(config: data.detectionConfig)
        ProviderRegistry.shared.activeDiarizationId = data.diarizationProvider == .disabled ? nil : "fluidaudio-diarization"
        if !MeetingsHost.isUITestMode, lastAppliedRefresh != nil, lastAppliedRefresh != data.calendarRefreshMinutes {
            calendar.startPolling(intervalMinutes: data.calendarRefreshMinutes)
        }
        lastAppliedRefresh = data.calendarRefreshMinutes
        updateStatus()
    }

    private func updateStatus() {
        let new: AppStatus
        if isRecording && isPaused {
            new = .paused
        } else if isRecording {
            new = detection.state == .quietPeriod || detection.state == .promptingUser ? .ending : .recording
        } else if detection.isRunning && settings.data.autoDetectionEnabled {
            new = .monitoring
        } else {
            new = .idle
        }
        if status != new { status = new }
    }

    // MARK: - Detection events

    private func handleDetection(_ event: MeetingStateEvent, _ snapshot: DetectionSnapshot) {
        switch event {
        case .meetingStarted:
            guard !isRecording else { break }
            let calendarMeeting = currentCalendarMeeting()
            guard settings.data.autoDetectionEnabled else {
                // Auto-detection off: never start recording on our own, even for calendar
                // events. Recording is manual (Start Recording / Join & Record), but a calendar
                // meeting gets one "Record?" card.
                if let calendarMeeting { offerToRecord(calendarMeeting) }
                detection.resetToIdle()
                break
            }
            let meeting = calendarMeeting ?? Meeting.adHoc(title: snapshot.detectedServiceName.map { "\($0) Meeting" } ?? "Ad-hoc Meeting")
            Task { await startRecording(meeting: meeting, trigger: .auto(snapshot)) }
        case .quietPeriodStarted, .quietPeriodAborted:
            break
        case .promptUser:
            guard isRecording else {
                detection.resetToIdle()
                break
            }
            if isPaused {
                // A paused meeting is expected to look quiet; don't offer to end it.
                detection.keepRecording()
                break
            }
            showEndPrompt(snapshot)
        case .meetingEnded:
            endPrompt.close()
            if isRecording { stopRecording() } else { detection.resetToIdle() }
        }
        if endPrompt.isVisible { endPrompt.updateSignals(snapshot) }
        updateStatus()
    }

    private func currentCalendarMeeting() -> Meeting? {
        calendar.currentMeeting(earlyStartMinutes: settings.data.calendarEarlyStartTolerance, overrunMinutes: settings.data.calendarOverrunTolerance)
    }

    private func showEndPrompt(_ snapshot: DetectionSnapshot) {
        let data = settings.data
        endPrompt.show(
            timeout: data.endPromptTimeout, quietPeriod: data.endDetectionQuietPeriod,
            meetingTitle: currentMeeting?.title ?? "Meeting",
            recordingStartedAt: Date().addingTimeInterval(-detector.activeElapsed), snapshot: snapshot,
            onEnd: { [weak self] in
                log("⏹️ User chose End Recording")
                self?.endMeeting()
            },
            onKeep: { [weak self] in self?.keepRecording() },
            onTimeout: { [weak self] in
                log("🔔 End prompt timed out; ending meeting")
                self?.endMeeting()
            })
    }

    // MARK: - Recording control

    enum Trigger {
        case auto(DetectionSnapshot)
        case manual
    }

    /// Menu: Join & Record.
    func joinAndRecord(_ meeting: Meeting) {
        if let link = meeting.meetingURL, let url = URL(string: link) { NSWorkspace.shared.open(url) }
        guard !isRecording else {
            log("⚠️ Join & Record ignored: already recording")
            return
        }
        Task { await startRecording(meeting: meeting, trigger: .manual) }
    }

    /// Meetings turned off: no detection, polling or new recordings; a recording in progress is stopped.
    func disable() {
        isEnabled = false
        if isRecording { stopRecording() }
        detection.stop()
        detection.resetToIdle()
        calendar.stopPolling()
        cards.dismiss { if case .recordPrompt = $0 { return true } else { return false } }
        updateStatus()
    }

    /// Meetings turned back on after `disable()`.
    func enable() {
        isEnabled = true
        if !MeetingsHost.isUITestMode {
            calendar.startPolling(intervalMinutes: settings.data.calendarRefreshMinutes)
            detection.start()
        }
        updateStatus()
    }

    /// Calendar meetings already offered, so an ignored or dismissed card never comes back.
    private static let offeredKey = "meetingsOfferedToRecord"

    /// True the first time it's asked about a meeting, false ever after (persists across launches).
    static func claimOffer(for meeting: Meeting, defaults: UserDefaults = .standard) -> Bool {
        var offered = defaults.stringArray(forKey: offeredKey) ?? []
        let key = "\(meeting.id)@\(Int(meeting.start.timeIntervalSince1970))"
        guard !offered.contains(key) else { return false }
        offered.append(key)
        defaults.set(Array(offered.suffix(200)), forKey: offeredKey)
        return true
    }

    private func offerToRecord(_ meeting: Meeting) {
        guard Self.claimOffer(for: meeting) else { return }
        log("🔔 Offered to record '\(meeting.title)'")
        cards.show(.recordPrompt(title: meeting.title, attendees: meeting.attendees)) { [weak self] in
            guard let self, !self.isRecording else { return }
            log("🎤 User chose Record from the meeting card")
            Task { await self.startRecording(meeting: meeting, trigger: .manual) }
        }
    }

    /// The calendar meeting happening now (with the early-start/overrun tolerance), if any.
    var calendarMeetingNow: Meeting? { currentCalendarMeeting() }

    /// Glimpse menu: record the calendar meeting happening now, without opening its link.
    func recordCalendarMeetingNow() {
        guard !isRecording, let meeting = currentCalendarMeeting() else { return }
        Task { await startRecording(meeting: meeting, trigger: .manual) }
    }

    /// Menu: Start Recording.
    func startAdHocRecording() {
        guard !isRecording else {
            log("⚠️ Start Recording ignored: already recording")
            return
        }
        let meeting = currentCalendarMeeting() ?? Meeting.adHoc(title: "Ad-hoc Meeting")
        Task { await startRecording(meeting: meeting, trigger: .manual) }
    }

    private func startRecording(meeting: Meeting, trigger: Trigger) async {
        guard isEnabled else { return }
        guard !isRecording else {
            log("⚠️ Recording already in progress; ignoring start for '\(meeting.title)'")
            return
        }
        currentMeeting = meeting
        do {
            try await detector.startRecording(meeting: meeting)
        } catch is CancellationError {
            // Stopped, cancelled or turned off while starting; that path already reset detection.
            // A newer recording may have started meanwhile; keep its meeting.
            if !isRecording { currentMeeting = nil }
            updateStatus()
            return
        } catch {
            currentMeeting = nil
            log("❌ Could not start recording: \(error.localizedDescription)")
            cards.show(.message(title: "Recording Failed", body: error.localizedDescription, isError: true))
            detection.resetToIdle()
            updateStatus()
            return
        }
        detection.markMeetingActive()
        detection.setRecordingFeed(true)

        switch trigger {
        case .auto(let snapshot):
            if meeting.fromCalendar {
                detectionCardId = cards.show(.meetingDetectedCalendar(title: meeting.title, minutes: meeting.durationMinutes, attendees: meeting.attendees))
            } else {
                detectionCardId = cards.show(.meetingDetectedAdHoc(signals: snapshot.activeSignalsDescription))
            }
        case .manual:
            detectionCardId = cards.show(.recordingStarted(title: meeting.title, attendees: meeting.attendees))
        }
        indicator.show(
            startedAt: detector.recordingStartedAt ?? Date(),
            isMuted: mute.isMuted,
            onMuteToggle: { [weak self] in self?.mute.toggle() },
            onPauseToggle: { [weak self] in self?.togglePause() },
            onStop: { [weak self] in self?.stopRecording() })
        updateMuteBadge()
        updateStatus()
    }

    /// Manual stop (menu / pill) or end of meeting.
    func stopRecording() {
        guard isRecording else { return }
        let meeting = currentMeeting ?? Meeting.adHoc(title: "Ad-hoc Meeting")
        indicator.hide()
        updateMuteBadge()
        endPrompt.close()
        if let id = detectionCardId { cards.dismiss(id) }
        detectionCardId = nil
        // Show the processing card immediately so Stop never feels dead.
        let cardId = cards.show(.processing(title: meeting.title, status: "Saving recording…", fraction: 0.02))
        detection.setRecordingFeed(false)
        detection.resetToIdle()
        currentMeeting = nil
        isPaused = false
        updateStatus()

        Task {
            let url = await detector.stopRecording()
            // The capture is only torn down here, so refresh the menu bar icon now.
            updateStatus()
            guard let url else {
                cards.update(cardId, kind: .message(title: "Recording Skipped", body: "No audio was captured, so no transcript was created.", isError: true))
                return
            }
            await process(url: url, meeting: meeting, cardId: cardId)
        }
    }

    /// Cancel Recording: discard audio, no history record, suppress re-detection.
    func cancelRecording() {
        guard isRecording else { return }
        indicator.hide()
        updateMuteBadge()
        endPrompt.close()
        if let id = detectionCardId { cards.dismiss(id) }
        detectionCardId = nil
        detection.setRecordingFeed(false)
        detection.resetToIdle(suppressStart: true)
        currentMeeting = nil
        isPaused = false
        Task {
            await detector.cancelRecording()
            updateStatus()
        }
    }

    // MARK: - Mute

    /// The recording pill shows mute state itself; otherwise a small badge does, so a
    /// system-wide mute is never invisible.
    func updateMuteBadge(muted: Bool? = nil) {
        if muted ?? mute.isMuted, !indicator.isVisible {
            MuteBadge.shared.show { [weak self] in self?.mute.unmute() }
        } else {
            MuteBadge.shared.hide()
        }
    }

    // MARK: - Pause

    /// Pause: audio is dropped (the transcript skips the paused span), the timer freezes, and
    /// end-of-meeting detection is held off until resumed.
    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        detector.pause()
        isPaused = true
        indicator.setPaused(true)
        if endPrompt.isVisible {
            endPrompt.close()
            detection.keepRecording()
        }
        updateStatus()
    }

    func resumeRecording() {
        guard isRecording, isPaused else { return }
        detector.resume()
        isPaused = false
        indicator.setPaused(false)
        updateStatus()
    }

    func togglePause() {
        isPaused ? resumeRecording() : pauseRecording()
    }

    func endMeeting() {
        endPrompt.close()
        detection.endMeeting()
        stopRecording()
    }

    func keepRecording() {
        endPrompt.close()
        detection.keepRecording()
        log("▶️ User chose Keep Recording; end detection disarmed until activity resumes")
        updateStatus()
    }

    // MARK: - Processing

    private func pipelineConfig() -> PipelineConfig {
        let d = settings.data
        return PipelineConfig(
            outputRoot: d.outputURL, speakersDirectory: d.speakersURL,
            language: d.language, primaryUserNames: d.primaryUserNames,
            diarizationEnabled: d.diarizationProvider != .disabled)
    }

    private func process(url: URL, meeting: Meeting, cardId: UUID) async {
        processingCount += 1
        defer { processingCount -= 1 }
        let observer = observeProgress(cardId: cardId)
        defer { NotificationCenter.default.removeObserver(observer) }
        cards.updateProgress(cardId, fraction: 0.04, status: "Recording saved · Preparing…")
        do {
            let result = try await ProviderTranscriptionPipeline.shared.process(wavURL: url, meeting: meeting, config: pipelineConfig())
            showReady(cardId: cardId, title: meeting.title, result: result)
        } catch PipelineError.emptyTranscription {
            cards.update(cardId, kind: .message(title: "Recording Skipped", body: "No speech was detected in the recording, so no transcript was created.", isError: true))
        } catch {
            cards.update(cardId, kind: .message(title: "Processing Failed", body: error.localizedDescription, isError: true))
        }
    }

    private func showReady(cardId: UUID, title: String, result: PipelineResult) {
        let minutes = max(1, Int((result.duration / 60).rounded()))
        if cards.contains(cardId) {
            cards.update(cardId, kind: .ready(title: title, minutes: minutes, transcript: result.markdownURL))
        } else {
            cards.show(.ready(title: title, minutes: minutes, transcript: result.markdownURL))
        }
    }

    private func observeProgress(cardId: UUID) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: .transcriptionProgress, object: nil, queue: .main) { [weak self] note in
            guard let step = note.userInfo?["step"] as? String, let fraction = note.userInfo?["fraction"] as? Double else { return }
            MainActor.assumeIsolated {
                self?.cards.updateProgress(cardId, fraction: fraction, status: "Recording saved · \(step)")
            }
        }
    }

    /// History view: Reprocess Transcription.
    func reprocess(_ record: TranscriptionRecord) async -> TranscriptionRecord? {
        let cardId = cards.show(.processing(title: record.meetingTitle, status: "Reprocessing…", fraction: 0.02))
        processingCount += 1
        defer { processingCount -= 1 }
        let observer = observeProgress(cardId: cardId)
        defer { NotificationCenter.default.removeObserver(observer) }
        do {
            let result = try await ProviderTranscriptionPipeline.shared.reprocess(record: record, config: pipelineConfig())
            showReady(cardId: cardId, title: record.meetingTitle, result: result)
        } catch PipelineError.emptyTranscription {
            cards.update(cardId, kind: .message(title: "Recording Skipped", body: "No speech was detected in the recording, so no transcript was created.", isError: true))
        } catch {
            cards.update(cardId, kind: .message(title: "Processing Failed", body: error.localizedDescription, isError: true))
        }
        return history.record(record.id)
    }

    /// On startup, retry incomplete transcriptions whose WAV still exists. Attempts are
    /// counted before the retry begins so a crash mid-retry still counts.
    private func retryIncompleteTranscriptions() async {
        let incomplete = history.incomplete()
        guard !incomplete.isEmpty else { return }
        processingCount += 1
        defer { processingCount -= 1 }
        var attempts = (UserDefaults.standard.dictionary(forKey: Self.retryAttemptsKey) as? [String: Int]) ?? [:]
        for record in incomplete {
            let key = String(record.id)
            guard let path = record.wavFilePath, FileManager.default.fileExists(atPath: path) else {
                history.fail(record.id, error: "Recording file missing after restart")
                attempts[key] = nil
                continue
            }
            let count = attempts[key] ?? 0
            if count >= Self.maxStartupRetries {
                history.fail(record.id, error: "transcription interrupted \(count) times")
                attempts[key] = nil
                UserDefaults.standard.set(attempts, forKey: Self.retryAttemptsKey)
                cards.show(.message(title: "Transcription Failed", body: "Gave up after repeated interrupted retries: \(record.meetingTitle)", isError: true))
                log("❌ Gave up retrying '\(record.meetingTitle)' after \(count) interrupted attempts")
                continue
            }
            attempts[key] = count + 1
            UserDefaults.standard.set(attempts, forKey: Self.retryAttemptsKey)
            UserDefaults.standard.synchronize()

            log("🔄 Retrying transcript from previous session: '\(record.meetingTitle)' (attempt \(count + 1))")
            let cardId = cards.show(.processing(title: record.meetingTitle, status: "Retrying transcript from previous session…", fraction: 0.02))
            let observer = observeProgress(cardId: cardId)
            do {
                let result = try await ProviderTranscriptionPipeline.shared.reprocess(record: record, config: pipelineConfig())
                    showReady(cardId: cardId, title: record.meetingTitle, result: result)
            } catch {
                cards.update(cardId, kind: .message(title: "Retry Failed", body: error.localizedDescription, isError: true))
            }
            NotificationCenter.default.removeObserver(observer)
            attempts[key] = nil
            UserDefaults.standard.set(attempts, forKey: Self.retryAttemptsKey)
        }
    }
}
