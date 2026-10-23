import AVFoundation
import Foundation

/// Assembles mic (L) and system audio (R) onto a shared host-clock timeline and writes a
/// 16-bit 48 kHz WAV. Each channel is spooled to a raw Int16 file while recording so
/// memory stays flat for long meetings; gaps become silence.
final class CombinedAudioCapture: @unchecked Sendable {
    enum Channel: Int { case mic = 0, system = 1 }

    private final class ChannelSpool {
        let url: URL
        let handle: FileHandle
        var frames: Int64 = 0
        var chunkCount = 0
        init(url: URL) throws {
            self.url = url
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
        }
        func append(_ samples: [Int16]) {
            samples.withUnsafeBufferPointer { handle.write(Data(buffer: $0)) }
            frames += Int64(samples.count)
        }
    }

    let outputURL: URL
    let mic = MicrophoneCapture()
    let system = SystemAudioCapture()

    private let queue = DispatchQueue(label: "glimpse.meetings.combined-capture")
    private var spools: [ChannelSpool] = []
    private var origin: TimeInterval = 0
    /// Paused spans in host-clock seconds (end nil while paused). Accessed on `queue`.
    private var pauses: [(start: TimeInterval, end: TimeInterval?)] = []
    private(set) var isRunning = false
    private(set) var startedAt = Date()

    /// Gaps shorter than this are absorbed (clock jitter), longer gaps become silence.
    private let gapToleranceFrames: Int64 = 2_400  // 50 ms

    /// Canonical mic samples as they arrive (feeds VAD during a recording).
    var onMicSamples: (([Float]) -> Void)?

    var onLevel: ((Float) -> Void)? {
        get { mic.onLevel }
        set { mic.onLevel = newValue }
    }

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() async throws {
        let base = outputURL.deletingPathExtension()
        spools = [
            try ChannelSpool(url: base.appendingPathExtension("mic.raw")),
            try ChannelSpool(url: base.appendingPathExtension("system.raw")),
        ]
        origin = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        startedAt = Date()

        mic.onChunk = { [weak self] chunk in
            self?.append(chunk, to: .mic)
            self?.onMicSamples?(chunk.samples)
        }
        system.onChunk = { [weak self] chunk in self?.append(chunk, to: .system) }

        var micStarted = false
        do {
            try mic.start()
            micStarted = true
        } catch {
            log("❌ Microphone capture failed: \(error.localizedDescription)")
        }
        do {
            try await system.start()
        } catch {
            log("⚠️ System audio unavailable: \(error.localizedDescription)")
            if !micStarted { throw error }
        }
        isRunning = true
    }

    /// Pause: sources keep running (no device restart on resume) but audio is dropped, and the
    /// paused span is removed from the timeline so the WAV has no gap.
    func pause() {
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        queue.async { [self] in
            guard pauses.last.map({ $0.end != nil }) ?? true else { return }
            pauses.append((now, nil))
        }
    }

    func resume() {
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        queue.async { [self] in
            guard let last = pauses.last, last.end == nil else { return }
            pauses[pauses.count - 1].end = now
        }
    }

    /// nil when `hostTime` falls inside a pause; otherwise seconds of pause before it.
    private func pausedOffset(at hostTime: TimeInterval) -> TimeInterval? {
        var offset: TimeInterval = 0
        for p in pauses {
            if hostTime < p.start { break }
            guard let end = p.end, hostTime >= end else { return nil }
            offset += end - p.start
        }
        return offset
    }

    private func append(_ chunk: TimedAudioChunk, to channel: Channel) {
        queue.async { [self] in
            guard spools.count == 2, let pausedOffset = pausedOffset(at: chunk.hostTime) else { return }
            let spool = spools[channel.rawValue]
            let target = Int64(((chunk.hostTime - origin - pausedOffset) * CanonicalAudio.sampleRate).rounded())
            var samples = chunk.samples
            if target > spool.frames + gapToleranceFrames {
                let gap = Int(target - spool.frames)
                spool.append([Int16](repeating: 0, count: gap))
            } else if target < 0 {
                // Chunk started before the recording origin: drop the leading part.
                let drop = min(samples.count, Int(-target))
                samples.removeFirst(drop)
            }
            spool.append(samples.map(floatToInt16))
            spool.chunkCount += 1
        }
    }

    /// Stop both sources and write the final WAV. Returns nil when nothing was captured.
    func stop() async -> URL? {
        guard isRunning else { return nil }
        isRunning = false
        mic.stop()
        await system.stop()
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: finalize())
            }
        }
    }

    /// Stop and delete everything (Cancel Recording).
    func cancel() async {
        isRunning = false
        mic.stop()
        await system.stop()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                for s in spools {
                    try? s.handle.close()
                    try? FileManager.default.removeItem(at: s.url)
                }
                spools = []
                try? FileManager.default.removeItem(at: Self.meetingURL(for: outputURL))
                continuation.resume()
            }
        }
    }

    private func finalize() -> URL? {
        var keepSpools = false
        defer {
            // On a write failure the spools stay put so the next launch can recover them.
            if !keepSpools {
                for s in spools { try? FileManager.default.removeItem(at: s.url) }
                try? FileManager.default.removeItem(at: Self.meetingURL(for: outputURL))
            }
            spools = []
        }
        for s in spools { try? s.handle.close() }
        guard spools.count == 2 else { return nil }
        let micSpool = spools[0], sysSpool = spools[1]
        let micHas = micSpool.chunkCount > 0, sysHas = sysSpool.chunkCount > 0
        guard micHas || sysHas else {
            log("⚠️ No audio captured")
            return nil
        }

        do {
            try Self.writeWAV(to: outputURL, mic: micHas ? micSpool.url : nil, system: sysHas ? sysSpool.url : nil)
            return outputURL
        } catch {
            keepSpools = true
            log("❌ Failed to write recording: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Crash recovery

    struct RecoveredRecording {
        let wavURL: URL
        let meeting: Meeting
    }

    static func meetingURL(for outputURL: URL) -> URL {
        outputURL.deletingPathExtension().appendingPathExtension("meeting.json")
    }

    /// The raw Int16 48 kHz mono spools being written for `outputURL`.
    static func spoolURLs(for outputURL: URL) -> (mic: URL, system: URL) {
        let base = outputURL.deletingPathExtension()
        return (base.appendingPathExtension("mic.raw"), base.appendingPathExtension("system.raw"))
    }

    static func saveMeeting(_ meeting: Meeting, for outputURL: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(meeting).write(to: meetingURL(for: outputURL), options: .atomic)
    }

    /// Rebuild WAVs from spools a crash left in `directory`. Call only when no capture is
    /// live. Spools are deleted only after their WAV is written.
    static func recoverOrphans(in directory: URL) -> [RecoveredRecording] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        let bases = Set(names.compactMap { name -> String? in
            for suffix in [".mic.raw", ".system.raw"] where name.hasSuffix(suffix) { return String(name.dropLast(suffix.count)) }
            return nil
        })
        var recovered: [RecoveredRecording] = []
        for base in bases.sorted() {
            let wav = directory.appendingPathComponent(base).appendingPathExtension("wav")
            let mic = directory.appendingPathComponent(base + ".mic.raw")
            let system = directory.appendingPathComponent(base + ".system.raw")
            let sidecar = meetingURL(for: wav)
            func nonEmpty(_ url: URL) -> URL? {
                ((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) > 0 ? url : nil
            }
            let micURL = nonEmpty(mic), systemURL = nonEmpty(system)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let modified = (try? fm.attributesOfItem(atPath: (micURL ?? system).path)[.modificationDate] as? Date) ?? Date()
            var meeting = (try? Data(contentsOf: sidecar)).flatMap { try? decoder.decode(Meeting.self, from: $0) }
                ?? Meeting.adHoc(title: "Meeting", start: modified)
            meeting.title += " (recovered)"
            guard micURL != nil || systemURL != nil else {
                for url in [mic, system, sidecar] { try? fm.removeItem(at: url) }
                continue
            }
            do {
                log("🩹 Recovering recording left by a previous session: \(base) ('\(meeting.title)')")
                try writeWAV(to: wav, mic: micURL, system: systemURL)
                for url in [mic, system, sidecar] { try? fm.removeItem(at: url) }
                recovered.append(RecoveredRecording(wavURL: wav, meeting: meeting))
            } catch {
                log("❌ Could not recover \(base): \(error.localizedDescription); spools kept in \(Paths.display(directory))")
            }
        }
        return recovered
    }

    // MARK: - WAV assembly

    private static func frameCount(_ url: URL) -> Int64 {
        Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 2
    }

    /// Write the WAV from raw Int16 spools: stereo (L=mic, R=system) when both exist, else mono.
    static func writeWAV(to url: URL, mic: URL?, system: URL?) throws {
        switch (mic, system) {
        case let (mic?, system?):
            try writeStereo(to: url, left: mic, right: system)
            log("💾 Recording saved: stereo (L=mic, R=system), \(formatDuration(Double(max(frameCount(mic), frameCount(system))) / CanonicalAudio.sampleRate)) → \(url.lastPathComponent)")
        case let (only?, nil), let (nil, only?):
            try writeMono(to: url, only)
            log("💾 Recording saved: mono (\(mic != nil ? "mic only" : "system only")), \(formatDuration(Double(frameCount(only)) / CanonicalAudio.sampleRate)) → \(url.lastPathComponent)")
        case (nil, nil):
            throw NSError(domain: "CombinedAudioCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio to write"])
        }
    }

    private static let chunkFrames = 1 << 18

    private static func writeStereo(to url: URL, left: URL, right: URL) throws {
        let writer = try PCM16WAVWriter(url: url, channels: 2, sampleRate: Int(CanonicalAudio.sampleRate))
        let l = try FileHandle(forReadingFrom: left)
        let r = try FileHandle(forReadingFrom: right)
        defer { try? l.close(); try? r.close() }
        let total = max(frameCount(left), frameCount(right))
        var done: Int64 = 0
        while done < total {
            let n = Int(min(Int64(Self.chunkFrames), total - done))
            let ls = Self.readInt16(l, count: n)
            let rs = Self.readInt16(r, count: n)
            var interleaved = [Int16](repeating: 0, count: n * 2)
            for i in 0..<n {
                interleaved[2 * i] = i < ls.count ? ls[i] : 0
                interleaved[2 * i + 1] = i < rs.count ? rs[i] : 0
            }
            writer.write(interleaved: interleaved)
            done += Int64(n)
        }
        try writer.finish()
    }

    private static func writeMono(to url: URL, _ spool: URL) throws {
        let writer = try PCM16WAVWriter(url: url, channels: 1, sampleRate: Int(CanonicalAudio.sampleRate))
        let h = try FileHandle(forReadingFrom: spool)
        defer { try? h.close() }
        while true {
            let s = Self.readInt16(h, count: Self.chunkFrames)
            if s.isEmpty { break }
            writer.write(interleaved: s)
        }
        try writer.finish()
    }

    private static func readInt16(_ handle: FileHandle, count: Int) -> [Int16] {
        guard let data = try? handle.read(upToCount: count * 2), !data.isEmpty else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}
