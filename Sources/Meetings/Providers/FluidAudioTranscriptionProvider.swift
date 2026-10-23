import FluidAudio
import Foundation

/// `fluidaudio-parakeet`: on-device Parakeet ASR.
struct FluidAudioTranscriptionProvider: TranscriptionProvider {
    let id = "fluidaudio-parakeet"
    let name = "FluidAudio Parakeet"

    var isAvailable: Bool {
        get async { (try? await FluidAudioModels.shared.asrManager()) != nil }
    }

    func transcribe(audioPath: URL, language: String?) async throws -> TranscriptionOutput {
        do {
            // One transcription at a time: callers share the ASR manager and its decoder state.
            return try await ASRGate.shared.run {
                let asr = try await FluidAudioModels.shared.asrManager()
                // Parakeet v3 detects the language itself; the setting is advisory.
                let result = try await asr.transcribe(audioPath, source: .system)
                let segments = Self.segments(from: result.tokenTimings ?? [], fallbackText: result.text, duration: result.duration)
                return TranscriptionOutput(text: result.text, segments: segments, duration: result.duration, words: Self.words(from: result.tokenTimings ?? []))
            }
        } catch {
            throw ProviderError.transcriptionFailed(error.localizedDescription)
        }
    }

    /// Merge subword tokens into words (a token starting with a space begins a new word).
    static func words(from tokens: [TokenTiming]) -> [TimedWord] {
        var words: [TimedWord] = []
        for token in tokens {
            if token.token.hasPrefix(" ") || words.isEmpty {
                words.append(TimedWord(start: token.startTime, end: token.endTime, text: token.token))
            } else {
                words[words.count - 1].text += token.token
                words[words.count - 1].end = token.endTime
            }
        }
        return words
    }

    /// Group token timings into sentence-like segments: split on sentence punctuation or a
    /// pause longer than 0.8 s, and cap segment length at ~15 s.
    static func segments(from tokens: [TokenTiming], fallbackText: String, duration: Double) -> [TranscriptSegment] {
        let trimmedFallback = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tokens.isEmpty else {
            return trimmedFallback.isEmpty ? [] : [TranscriptSegment(start: 0, end: duration, text: trimmedFallback)]
        }
        var result: [TranscriptSegment] = []
        var text = ""
        var start = tokens[0].startTime
        var lastEnd = tokens[0].endTime

        func flush() {
            let t = text.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { result.append(TranscriptSegment(start: start, end: lastEnd, text: t)) }
            text = ""
        }

        for token in tokens {
            let startsWord = token.token.hasPrefix(" ")
            if !text.isEmpty && startsWord && (token.startTime - lastEnd > 0.8 || token.startTime - start > 15) {
                flush()
            }
            if text.isEmpty { start = token.startTime }
            text += token.token
            lastEnd = token.endTime
            if let last = token.token.last, ".?!".contains(last), token.endTime - start > 1.5 {
                flush()
            }
        }
        flush()
        return result
    }
}

/// Runs async operations strictly one after another, in call order.
actor ASRGate {
    static let shared = ASRGate()
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { () async throws -> T in
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
