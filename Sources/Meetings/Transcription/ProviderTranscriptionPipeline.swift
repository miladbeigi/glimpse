import Foundation
import MeetingDetection

enum PipelineError: LocalizedError {
    case noTranscriptionProvider
    case transcriptionFailed(String)
    case diarizationFailed(String)
    case emptyTranscription

    var errorDescription: String? {
        switch self {
        case .noTranscriptionProvider: return "No transcription provider configured"
        case .transcriptionFailed(let m): return "Transcription failed: \(m)"
        case .diarizationFailed(let m): return "Diarization failed: \(m)"
        case .emptyTranscription: return "No speech was detected in the recording, so no transcript was created."
        }
    }
}

struct PipelineConfig: Sendable {
    var outputRoot: URL
    var speakersDirectory: URL
    var language: String?
    var primaryUserNames: [String]
    var diarizationEnabled: Bool

    var primaryDisplayName: String {
        primaryUserNames.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "You"
    }
}

struct PipelineResult: Sendable {
    var recordId: Int64
    var markdownURL: URL
    var duration: TimeInterval
    var segmentCount: Int
    var timings: PipelineTimings
    var createdEmbeddings: [String]
    /// Final speaker-labeled segments.
    var segments: [LabeledSegment] = []
}

/// Progress steps (text + fraction) written to the history record and shown on the card.
enum PipelineStep {
    static let copying = ("Saving recording…", 0.05)
    static let reading = ("Reading audio…", 0.10)
    static let splitting = ("Separating channels…", 0.15)
    static let transcribingLocal = ("Transcribing your audio…", 0.25)
    static let transcribingRemote = ("Transcribing remote audio…", 0.45)
    static let transcribing = ("Transcribing…", 0.35)
    static let diarizing = ("Identifying speakers…", 0.65)
    static let identifying = ("Matching voices to attendees…", 0.78)
    static let saving = ("Saving transcript…", 0.92)
}

/// Transcription pipeline. An actor so only one recording is processed at a time.
actor ProviderTranscriptionPipeline {
    static let shared = ProviderTranscriptionPipeline()

    private let registry = ProviderRegistry.shared
    private let history = TranscriptionHistoryStore.shared

    /// Process a new recording: copies the WAV into the history store first.
    func process(wavURL: URL, meeting: Meeting, config: PipelineConfig) async throws -> PipelineResult {
        let recordId = history.startRecord(meeting: meeting, wavPath: nil)
        progress(recordId, PipelineStep.copying)
        let stored = FileNaming.uniqueFileURL(in: Paths.recordingsStore, name: FileNaming.baseName(date: meeting.start, title: meeting.title, ext: "wav"))
        do {
            try FileManager.default.copyItem(at: wavURL, to: stored)
            history.setWavPath(recordId, path: stored.path)
            try? FileManager.default.removeItem(at: wavURL)
        } catch {
            history.fail(recordId, error: "Could not store recording: \(error.localizedDescription)")
            throw error
        }
        return try await run(recordId: recordId, wavURL: stored, meeting: meeting, config: config)
    }

    /// Re-run an existing history record from its saved WAV.
    func reprocess(record: TranscriptionRecord, config: PipelineConfig) async throws -> PipelineResult {
        guard let path = record.wavFilePath, FileManager.default.fileExists(atPath: path) else {
            throw PipelineError.transcriptionFailed("Recording file is missing")
        }
        history.restart(record.id)
        let meeting = Meeting(
            id: record.meetingId ?? "record-\(record.id)", title: record.meetingTitle,
            start: record.meetingDate, end: record.meetingDate.addingTimeInterval(record.durationSeconds ?? 3600),
            attendees: record.attendees, meetingURL: nil, type: .unknown, fromCalendar: record.meetingId?.hasPrefix("adhoc-") == false)
        return try await run(recordId: record.id, wavURL: URL(fileURLWithPath: path), meeting: meeting, config: config)
    }

    private func run(recordId: Int64, wavURL: URL, meeting: Meeting, config: PipelineConfig) async throws -> PipelineResult {
        let t0 = Date()
        var timings = PipelineTimings()
        defer { Task { await AudioSampleCache.shared.clear() } }

        do {
            guard let transcriber = registry.transcriptionProvider else { throw PipelineError.noTranscriptionProvider }

            progress(recordId, PipelineStep.reading)
            guard let info = WAVInfo.read(wavURL) else { throw PipelineError.transcriptionFailed("Unreadable WAV file") }
            log("📝 Processing '\(meeting.title)': \(info.channels)ch, \(Int(info.sampleRate)) Hz, \(formatDuration(info.duration))")

            let outcome: ([LabeledSegment], [String])
            if info.channels == 2 {
                outcome = try await stereoPath(recordId: recordId, wavURL: wavURL, meeting: meeting, config: config, transcriber: transcriber, timings: &timings)
            } else {
                outcome = try await monoPath(recordId: recordId, wavURL: wavURL, meeting: meeting, config: config, transcriber: transcriber, timings: &timings)
            }
            let (labeled, created) = outcome

            progress(recordId, PipelineStep.saving)
            let saveStart = Date()
            let attendees = displayAttendees(meeting: meeting, segments: labeled, config: config)
            let markdown = MarkdownWriter.render(meeting: meeting, duration: info.duration, attendees: attendees, segments: labeled)
            let mdURL = try MarkdownWriter.write(markdown, meeting: meeting, outputRoot: config.outputRoot)
            timings.fileSaving = Date().timeIntervalSince(saveStart)
            timings.totalEndToEnd = Date().timeIntervalSince(t0)

            history.complete(recordId, markdownPath: mdURL.path, segmentCount: labeled.count, duration: info.duration, timings: timings, createdEmbeddings: created)
            log("✅ Transcript saved: \(mdURL.path) (\(labeled.count) segments, \(String(format: "%.1f", timings.totalEndToEnd ?? 0))s)")
            return PipelineResult(recordId: recordId, markdownURL: mdURL, duration: info.duration, segmentCount: labeled.count, timings: timings, createdEmbeddings: created, segments: labeled)
        } catch {
            let duration = WAVInfo.read(wavURL)?.duration
            history.fail(recordId, error: error.localizedDescription, duration: duration)
            log("❌ Pipeline failed for '\(meeting.title)': \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Stereo (source-separated) path

    private func stereoPath(
        recordId: Int64, wavURL: URL, meeting: Meeting, config: PipelineConfig,
        transcriber: TranscriptionProvider, timings: inout PipelineTimings
    ) async throws -> ([LabeledSegment], [String]) {
        progress(recordId, PipelineStep.splitting)
        let tmp = Paths.tempRecordings.appendingPathComponent("split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let leftURL = tmp.appendingPathComponent("local.wav")
        let rightURL = tmp.appendingPathComponent("remote.wav")
        try WAVInfo.splitStereo(wavURL, left: leftURL, right: rightURL)

        let language = config.language == "auto" ? nil : config.language
        let asrStart = Date()
        progress(recordId, PipelineStep.transcribingLocal)
        let local = try await transcribe(transcriber, leftURL, language)
        progress(recordId, PipelineStep.transcribingRemote)
        let remote = try await transcribe(transcriber, rightURL, language)
        timings.transcription = Date().timeIntervalSince(asrStart)
        log("📝 Local: \(local.segments.count) segments · Remote: \(remote.segments.count) segments")

        guard !local.segments.isEmpty || !remote.segments.isEmpty else { throw PipelineError.emptyTranscription }

        // Local channel: always the primary user.
        let me = config.primaryDisplayName
        let localLabeled = local.segments.map { LabeledSegment(speaker: me, start: $0.start, end: $0.end, text: $0.text) }

        // Remote attendees = attendees minus the primary user's aliases.
        var remoteAttendees = meeting.attendees.filter { !matchesAlias($0, aliases: config.primaryUserNames) }
        if !meeting.attendees.isEmpty && remoteAttendees.count == meeting.attendees.count && remoteAttendees.count > 1 && config.primaryUserNames.isEmpty {
            // Calendar puts "self" first; without configured aliases assume it is the user.
            remoteAttendees.removeFirst()
        }

        var remoteLabeled: [LabeledSegment] = []
        var created: [String] = []
        if remote.segments.isEmpty {
            remoteLabeled = []
        } else if remoteAttendees.count == 1 {
            // 1-on-1: every remote segment is the other attendee; diarization skipped.
            let other = displayName(forAttendee: remoteAttendees[0])
            log("🎯 1-on-1 with \(other): labeling remote channel directly")
            remoteLabeled = remote.segments.map { LabeledSegment(speaker: other, start: $0.start, end: $0.end, text: $0.text) }
            if let learned = await learnProfile(other, from: remote.segments, audio: rightURL, config: config) { created.append(learned) }
        } else if config.diarizationEnabled, let diarizer = registry.diarizationProvider, !remoteAttendees.isEmpty,
                  let embedder = registry.embeddingProvider {
            progress(recordId, PipelineStep.diarizing)
            let dStart = Date()
            let diarization: DiarizationOutput
            do {
                diarization = try await diarizer.diarize(audioPath: rightURL, numSpeakers: nil)
            } catch {
                throw PipelineError.diarizationFailed(error.localizedDescription)
            }
            timings.diarization = Date().timeIntervalSince(dStart)
            progress(recordId, PipelineStep.identifying)
            let identifier = SpeakerIdentifier(embeddingProvider: embedder, profileStore: VoiceProfileStore(directory: config.speakersDirectory))
            let result = await identifier.identify(
                diarization: diarization, audioPath: rightURL, attendees: remoteAttendees,
                primaryAliases: config.primaryUserNames, allowPrimaryUser: false)
            created = result.createdEmbeddings
            let samples = try? await AudioSampleCache.shared.samples16k(for: rightURL)
            remoteLabeled = SpeakerIdentifier.assign(output: remote, turns: diarization.turns, labels: result.labels, fallback: SpeakerIdentifier.unknown, samples16k: samples)
        } else {
            let label = remoteAttendees.first.map { displayName(forAttendee: $0) } ?? "Speaker"
            remoteLabeled = remote.segments.map { LabeledSegment(speaker: label, start: $0.start, end: $0.end, text: $0.text) }
        }

        let merged = (localLabeled + remoteLabeled).sorted { $0.start < $1.start }
        return (merged, created)
    }

    /// In a 1-on-1 the remote channel is only the other person: learn their voice when there is
    /// no usable profile yet (missing, or a copy of someone else's voice), so group meetings can
    /// recognize them later. Uses the longest few segments.
    private func learnProfile(_ name: String, from segments: [TranscriptSegment], audio: URL, config: PipelineConfig) async -> String? {
        guard let embedder = registry.embeddingProvider else { return nil }
        let store = VoiceProfileStore(directory: config.speakersDirectory)
        let existing = store.loadAll().first { normalizeName($0.name) == normalizeName(name) }
        if let existing, store.duplicate(of: existing.embedding, excluding: existing.name) == nil { return nil }
        let longest = segments.filter { $0.end - $0.start >= 3 }.sorted { ($0.end - $0.start) > ($1.end - $1.start) }.prefix(5)
        var embeddings: [[Float]] = []
        for seg in longest {
            if let e = try? await embedder.extractEmbedding(audioPath: audio, start: seg.start, end: seg.end) { embeddings.append(e) }
        }
        guard embeddings.count >= 2 else { return nil }
        let profileName = existing?.name ?? name
        do {
            try store.save(VoiceProfile(name: profileName, embedding: averageEmbedding(embeddings)))
            log("🎯 Learned \(profileName)'s voice from the 1-on-1 (\(embeddings.count) segments)\(existing == nil ? "" : "; replaced a profile that copied another voice")")
            return profileName
        } catch {
            return nil
        }
    }

    // MARK: - Mono (legacy) path

    private func monoPath(
        recordId: Int64, wavURL: URL, meeting: Meeting, config: PipelineConfig,
        transcriber: TranscriptionProvider, timings: inout PipelineTimings
    ) async throws -> ([LabeledSegment], [String]) {
        let language = config.language == "auto" ? nil : config.language
        progress(recordId, PipelineStep.transcribing)
        let asrStart = Date()
        let output = try await transcribe(transcriber, wavURL, language)
        timings.transcription = Date().timeIntervalSince(asrStart)
        guard !output.segments.isEmpty else { throw PipelineError.emptyTranscription }

        guard config.diarizationEnabled, let diarizer = registry.diarizationProvider, let embedder = registry.embeddingProvider else {
            let label = meeting.attendees.count == 1 ? meeting.attendees[0] : SpeakerIdentifier.unknown
            return (output.segments.map { LabeledSegment(speaker: label, start: $0.start, end: $0.end, text: $0.text) }, [])
        }

        progress(recordId, PipelineStep.diarizing)
        let dStart = Date()
        let diarization: DiarizationOutput
        do {
            diarization = try await diarizer.diarize(audioPath: wavURL, numSpeakers: nil)
        } catch {
            throw PipelineError.diarizationFailed(error.localizedDescription)
        }
        timings.diarization = Date().timeIntervalSince(dStart)

        progress(recordId, PipelineStep.identifying)
        let identifier = SpeakerIdentifier(embeddingProvider: embedder, profileStore: VoiceProfileStore(directory: config.speakersDirectory))
        let result = await identifier.identify(
            diarization: diarization, audioPath: wavURL, attendees: meeting.attendees,
            primaryAliases: config.primaryUserNames, allowPrimaryUser: true)
        let samples = try? await AudioSampleCache.shared.samples16k(for: wavURL)
        let labeled = SpeakerIdentifier.assign(output: output, turns: diarization.turns, labels: result.labels, fallback: SpeakerIdentifier.unknown, samples16k: samples)
        return (labeled, result.createdEmbeddings)
    }

    // MARK: - Helpers

    private func transcribe(_ provider: TranscriptionProvider, _ url: URL, _ language: String?) async throws -> TranscriptionOutput {
        do {
            return try await provider.transcribe(audioPath: url, language: language)
        } catch {
            throw PipelineError.transcriptionFailed(error.localizedDescription)
        }
    }

    private func progress(_ id: Int64, _ step: (String, Double)) {
        history.updateProgress(id, step: step.0, fraction: step.1)
        log("📝 [\(id)] \(step.0)")
    }

    /// Attendees line: calendar attendees if known, otherwise the speakers that appeared.
    private func displayAttendees(meeting: Meeting, segments: [LabeledSegment], config: PipelineConfig) -> [String] {
        if !meeting.attendees.isEmpty { return meeting.attendees }
        var seen: [String] = []
        for s in segments where s.speaker != SpeakerIdentifier.unknown && !seen.contains(s.speaker) { seen.append(s.speaker) }
        return seen
    }
}
