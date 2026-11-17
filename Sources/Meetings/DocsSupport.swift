#if DEBUG
import AppKit

/// DEBUG-only hooks for Glimpse's DocsScenario (the README screenshots). Call `debugUseScratchFolder` first: history,
/// settings and voice profiles then live in that folder, so the user's meetings are never read or written.
extension Meetings {
    public static func debugUseScratchFolder(_ url: URL) {
        Paths.debugApplicationSupport = url
    }

    /// Shows the meeting recording pill as if `elapsed` seconds had been recorded, with a moving level meter.
    /// Returns its window.
    public static func debugShowRecordingPill(elapsed: TimeInterval, muted: Bool = false) -> NSWindow? {
        let indicator = RecordingIndicator.shared
        indicator.show(startedAt: Date().addingTimeInterval(-elapsed), synthetic: true, isMuted: muted,
                       onMuteToggle: {}, onPauseToggle: {}, onStop: {})
        return indicator.debugWindow
    }

    public static func debugHideRecordingPill() { RecordingIndicator.shared.hide() }

    /// Shows the "Microphone muted" badge (without muting anything). Returns its window.
    public static func debugShowMuteBadge() -> NSWindow? {
        MuteBadge.shared.show {}
        return MuteBadge.shared.debugWindow
    }

    public static func debugHideMuteBadge() { MuteBadge.shared.hide() }

    /// Fills the scratch folder with sample meetings (fictional people), sample settings and voice profiles.
    public static func debugAddSampleMeetings() {
        guard let root = Paths.debugApplicationSupport else { return }
        let files = root.appendingPathComponent("samples", isDirectory: true)
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)

        var data = AppSettings.shared.data
        data.primaryUserNames = ["Alex Morgan"]
        data.primaryUserHasProfile = true
        data.autoDetectionEnabled = true
        data.calendars = ["primary"]
        AppSettings.shared.data = data

        let voices = VoiceProfileStore(directory: Paths.voiceProfiles)
        try? FileManager.default.createDirectory(at: Paths.voiceProfiles, withIntermediateDirectories: true)
        for name in ["Alex Morgan", "Ava Thompson", "Liam Carter", "Sofia Nguyen"] {
            let profile = VoiceProfile(name: name, embedding: (0..<16).map { _ in Float.random(in: -1...1) })
            try? JSONEncoder().encode(profile).write(to: voices.fileURL(for: name))
        }

        let cal = Calendar.current
        func at(daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
            let day = cal.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        struct Sample {
            var title: String, start: Date, minutes: Double, attendees: [String], segments: Int, learned: [String] = []
        }
        // Oldest first, so the newest (selected) one has the highest id.
        let samples = [
            Sample(title: "Sprint Planning", start: at(daysAgo: 6, 9, 30), minutes: 52,
                   attendees: ["Ava Thompson", "Liam Carter", "Sofia Nguyen", "Noah Patel", "Mia Rossi"], segments: 341),
            Sample(title: "Northwind Customer Call", start: at(daysAgo: 3, 16, 0), minutes: 28,
                   attendees: ["Noah Patel", "Liam Carter"], segments: 164),
            Sample(title: "Design Review: Onboarding", start: at(daysAgo: 2, 14, 0), minutes: 35,
                   attendees: ["Mia Rossi", "Ava Thompson"], segments: 198),
            Sample(title: "1:1 Ava / Alex", start: at(daysAgo: 1, 11, 0), minutes: 24,
                   attendees: ["Ava Thompson"], segments: 121),
            Sample(title: "Product Weekly Sync", start: at(daysAgo: 0, 10, 0), minutes: 41.3,
                   attendees: ["Ava Thompson", "Liam Carter", "Sofia Nguyen"], segments: 286, learned: ["Sofia Nguyen"]),
        ]
        let store = TranscriptionHistoryStore.shared
        for (i, s) in samples.enumerated() {
            let meeting = Meeting(id: "docs-\(i)", title: s.title, start: s.start, end: s.start.addingTimeInterval(s.minutes * 60),
                                  attendees: s.attendees, meetingURL: nil, type: .unknown, fromCalendar: true)
            let wav = files.appendingPathComponent("meeting-\(i).wav")
            let md = files.appendingPathComponent("meeting-\(i).md")
            try? Data().write(to: wav)
            try? "# \(s.title)\n".write(to: md, atomically: true, encoding: .utf8)
            let id = store.startRecord(meeting: meeting, wavPath: wav.path)
            let transcription = s.minutes * 0.93, diarization = s.minutes * 0.27
            store.complete(id, markdownPath: md.path, segmentCount: s.segments, duration: s.minutes * 60,
                           timings: PipelineTimings(transcription: transcription, diarization: diarization, fileSaving: 0.2,
                                                    totalEndToEnd: transcription + diarization + 0.2 + 1.1),
                           createdEmbeddings: s.learned)
        }
    }

    /// Opens the Transcription History window and returns it.
    public static func debugShowHistory() -> NSWindow? {
        WindowManager.shared.showHistory()
        return WindowManager.shared.debugHistoryWindow
    }
}

extension Paths {
    nonisolated(unsafe) static var debugApplicationSupport: URL?
}
#endif
