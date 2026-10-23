import Foundation

/// Owns the live capture session. Refuses to replace a live capture.
@MainActor
final class MeetingDetector {
    private(set) var capture: CombinedAudioCapture?
    /// The capture whose `start()` is still running. Stopping it then only lets go of it;
    /// `startRecording` cleans it up once `start()` returns, so stop and start never overlap.
    private var starting: CombinedAudioCapture?
    var onLevel: ((Float) -> Void)?
    /// Called off the main thread with 48 kHz mic samples.
    var onMicSamples: (([Float]) -> Void)?

    var isRecording: Bool { capture != nil }
    var recordingStartedAt: Date? { capture?.startedAt }

    private(set) var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0
    var isPaused: Bool { pausedAt != nil }

    /// Recorded time so far, excluding pauses.
    var activeElapsed: TimeInterval {
        guard let start = recordingStartedAt else { return 0 }
        let now = pausedAt ?? Date()
        return max(0, now.timeIntervalSince(start) - pausedTotal)
    }

    func pause() {
        guard let capture, pausedAt == nil else { return }
        capture.pause()
        pausedAt = Date()
        log("⏸️ Recording paused at \(formatDuration(activeElapsed))")
    }

    func resume() {
        guard let capture, let pausedAt else { return }
        capture.resume()
        pausedTotal += Date().timeIntervalSince(pausedAt)
        self.pausedAt = nil
        log("▶️ Recording resumed")
    }

    /// `meeting` is saved next to the spools so a crash-recovered recording keeps its title.
    func startRecording(meeting: Meeting) async throws {
        guard capture == nil else {
            log("⚠️ startRecording ignored: a capture is already live")
            return
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        // Suffix: a stop and a new start within the same second must not share spool files.
        let stamp = f.string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(4).lowercased()
        let url = Paths.inProgressRecordings.appendingPathComponent("recording_\(stamp).wav")
        CombinedAudioCapture.saveMeeting(meeting, for: url)
        pausedAt = nil
        pausedTotal = 0
        let capture = CombinedAudioCapture(outputURL: url)
        capture.onLevel = { [weak self] level in self?.onLevel?(level) }
        let micSink = onMicSamples
        capture.onMicSamples = { samples in micSink?(samples) }
        self.capture = capture
        starting = capture
        defer { if starting === capture { starting = nil } }
        do {
            try await capture.start()
        } catch {
            guard self.capture === capture else {
                // Already stopped by the user; a failed start is no news to them.
                await capture.cancel()
                throw CancellationError()
            }
            self.capture = nil
            throw error
        }
        // Stopped or cancelled while starting: that call found nothing running yet, so finish the job here.
        guard self.capture === capture else {
            await capture.cancel()
            log("🗑️ Recording stopped while starting; audio discarded")
            throw CancellationError()
        }
        log("🎤 Recording started → \(url.lastPathComponent)")
    }

    /// Stop and return the WAV (nil if nothing was captured).
    func stopRecording() async -> URL? {
        guard let capture else { return nil }
        self.capture = nil
        pausedAt = nil
        if starting === capture { return nil }
        return await capture.stop()
    }

    func cancelRecording() async {
        guard let capture else { return }
        self.capture = nil
        pausedAt = nil
        if starting === capture { return }
        await capture.cancel()
        log("🗑️ Recording cancelled; audio discarded")
    }
}
