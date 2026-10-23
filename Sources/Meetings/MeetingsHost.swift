import AppKit
import Carbon.HIToolbox

/// Glimpse's entry point into meeting recording. Glimpse owns the app lifecycle, the status
/// item, settings window and updates; this module owns detection, recording, transcription
/// and the transcript history window.
@MainActor
public enum Meetings {
    /// AppState is set up once; turning meetings off and on again only stops and restarts detection.
    private static var initialized = false
    private static var started = false
    private static var muteHotKey: GlobalHotKey?
    private static let menuController = MeetingsMenu()

    /// Set by Glimpse: opens its settings window on the Meetings tab.
    public static var openSettings: () -> Void = {}

    public static var isRunning: Bool { started }
    public static var isRecording: Bool { initialized && AppState.shared.isRecording }
    public static var isBusy: Bool { initialized && (AppState.shared.isRecording || AppState.shared.isProcessing) }

    /// Title of the calendar meeting happening now, when it isn't being recorded yet.
    public static var unrecordedMeetingNow: String? {
        guard started, !AppState.shared.isRecording else { return nil }
        return AppState.shared.calendarMeetingNow?.title
    }

    public static var recordingTitle: String? {
        guard isRecording else { return nil }
        return AppState.shared.currentMeeting?.title ?? "Meeting"
    }

    public static func recordMeetingNow() { AppState.shared.recordCalendarMeetingNow() }
    public static func stopRecording() { AppState.shared.stopRecording() }

    public static func start() {
        guard !started else { return }
        started = true
        if initialized {
            AppState.shared.enable()
        } else {
            initialized = true
            MicMuteController.shared.restoreLeftoverMute()
            let registry = ProviderRegistry.shared
            registry.register(FluidAudioTranscriptionProvider() as TranscriptionProvider)
            registry.register(FluidAudioDiarizationProvider() as DiarizationProvider)
            registry.register(FluidAudioEmbeddingProvider() as SpeakerEmbeddingProvider)
            registry.activeDiarizationId = AppSettings.shared.data.diarizationProvider == .disabled ? nil : "fluidaudio-diarization"
            AppState.shared.start()
        }
        log("✅ Meetings started")
        muteHotKey = GlobalHotKey(keyCode: kVK_ANSI_M, modifiers: controlKey | optionKey) {
            MainActor.assumeIsolated { MicMuteController.shared.toggle() }
        }
        log(muteHotKey != nil ? "⌨️ Mute shortcut ⌃⌥M registered" : "⚠️ Could not register ⌃⌥M (in use by another app)")
        Task {
            if !MicrophoneCapture.permissionGranted {
                let granted = await MicrophoneCapture.requestPermission()
                log(granted ? "✅ Microphone permission granted" : "⚠️ Microphone permission denied")
            }
        }
    }

    /// Turns meetings off: no more detection, calendar polling or mute shortcut. A recording in
    /// progress is stopped and transcribed as usual.
    public static func stop() {
        guard started else { return }
        started = false
        AppState.shared.disable()
        muteHotKey = nil
        MicMuteController.shared.unmuteForQuit()
        log("⏹️ Meetings turned off")
    }

    /// Call from applicationWillTerminate: never leave the system mic muted.
    public static func prepareForQuit() {
        guard initialized else { return }
        MicMuteController.shared.unmuteForQuit()
        log("👋 Meetings stopping (Glimpse quitting)")
    }

    /// Fills a Glimpse submenu with the meeting controls; call from menuNeedsUpdate.
    public static func populate(_ menu: NSMenu) {
        menuController.populate(menu)
    }

    public static func showHistory() { WindowManager.shared.showHistory() }

    /// Short state for the submenu, e.g. "Recording — Weekly Sync".
    public static var statusText: String {
        guard started else { return "Off" }
        let state = AppState.shared
        let title = state.currentMeeting.map { " — \($0.title)" } ?? ""
        switch state.status {
        case .idle: return "Idle"
        case .monitoring: return "Monitoring"
        case .recording: return "Recording\(title)"
        case .ending: return "Ending"
        case .paused: return "Paused\(title)"
        }
    }
}

enum MeetingsHost {
    /// Dev instance: calendar polling, detection and startup recovery are off.
    static let isUITestMode = ProcessInfo.processInfo.environment["GLIMPSE_MEETINGS_UI_TEST"] == "1"
}

/// Meeting controls, as a submenu of Glimpse's menu.
@MainActor
final class MeetingsMenu: NSObject {
    private var appState: AppState { AppState.shared }

    func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        // The status is the parent item's subtitle in Glimpse's menu.
        if appState.isRecording {
            menu.addItem(item(appState.isPaused ? "Resume Recording" : "Pause Recording", #selector(togglePause),
                              symbol: appState.isPaused ? "play.fill" : "pause.fill"))
            menu.addItem(item("Stop Recording", #selector(stopRecording), symbol: "stop.fill"))
        } else {
            menu.addItem(item("Start Recording", #selector(startRecording), symbol: "record.circle"))
        }
        menu.addItem(.separator())

        let upcoming = NSMenuItem(title: "Upcoming Meetings", action: nil, keyEquivalent: "")
        upcoming.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
        upcoming.isEnabled = false
        menu.addItem(upcoming)
        if !appState.calendar.isAuthenticated {
            menu.addItem(item("    Sign in to Google Calendar", #selector(signIn)))
        } else if appState.calendar.menuMeetings.isEmpty {
            let none = NSMenuItem(title: "    No meetings in the next 24 hours", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            let tf = DateFormatter()
            tf.timeStyle = .short
            tf.dateStyle = .none
            for meeting in appState.calendar.menuMeetings.prefix(10) {
                let m = NSMenuItem(title: "    \(tf.string(from: meeting.start))  \(meeting.title)", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                let join = item("Join & Record", #selector(joinAndRecord(_:)))
                join.representedObject = meeting.id
                join.isEnabled = !appState.isRecording
                sub.addItem(join)
                if meeting.meetingURL != nil {
                    let open = item("Open Meeting Link", #selector(openLink(_:)))
                    open.representedObject = meeting.id
                    sub.addItem(open)
                }
                m.submenu = sub
                menu.addItem(m)
            }
        }
        menu.addItem(.separator())
        menu.addItem(item("Transcription History", #selector(openHistory), symbol: "list.bullet.rectangle"))
        menu.addItem(item("Meetings Settings…", #selector(openSettings), symbol: "gearshape"))

        // Keep the calendar fresh for the next time the menu opens.
        Task { await appState.calendar.refresh() }
    }

    private func item(_ title: String, _ action: Selector, symbol: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return i
    }

    private func meeting(for sender: NSMenuItem) -> Meeting? {
        guard let id = sender.representedObject as? String else { return nil }
        return appState.calendar.upcomingMeetings.first { $0.id == id }
    }

    @objc private func startRecording() { appState.startAdHocRecording() }
    @objc private func stopRecording() { appState.stopRecording() }
    @objc private func togglePause() { appState.togglePause() }
    @objc private func signIn() {
        Task {
            await appState.calendar.signIn()
            if !appState.calendar.isAuthenticated, let error = appState.calendar.lastError {
                appState.cards.show(.message(title: "Google Calendar", body: error, isError: true))
            }
        }
    }
    @objc private func joinAndRecord(_ sender: NSMenuItem) {
        if let m = meeting(for: sender) { appState.joinAndRecord(m) }
    }
    @objc private func openLink(_ sender: NSMenuItem) {
        if let link = meeting(for: sender)?.meetingURL, let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
    @objc private func openHistory() { WindowManager.shared.showHistory() }
    @objc private func openSettings() { Meetings.openSettings() }
}

/// A recorded meeting, as the meeting_transcript tool lists it.
public struct MeetingRecord: Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var attendees: [String]
    public var transcriptPath: String?
    public var status: String
}

extension Meetings {
    /// Meetings that overlap `from...to`, oldest first, from the transcript history.
    public nonisolated static func records(from: Date, to: Date) -> [MeetingRecord] {
        guard FileManager.default.fileExists(atPath: Paths.historyDatabase.path) else { return [] }
        return TranscriptionHistoryStore.shared.all().compactMap { r -> MeetingRecord? in
            // Duration is known once transcribed; while transcribing, the recording ended when that began.
            // Failed records without either are left out rather than shown as running until now.
            guard let end = r.durationSeconds.map({ r.meetingDate.addingTimeInterval($0) }) ?? r.transcriptionStartedAt,
                  r.meetingDate <= to, end >= from else { return nil }
            return MeetingRecord(title: r.meetingTitle, start: r.meetingDate, end: end, attendees: r.attendees,
                                 transcriptPath: r.markdownFilePath, status: r.status.rawValue)
        }
        .sorted { $0.start < $1.start }
    }
}
