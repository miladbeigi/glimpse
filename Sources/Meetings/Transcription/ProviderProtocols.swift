import Foundation

struct TranscriptSegment: Codable, Sendable, Equatable {
    var start: Double
    var end: Double
    var text: String
}

/// A word with timing; `text` has a leading space when it starts a new word.
struct TimedWord: Sendable, Equatable {
    var start: Double
    var end: Double
    var text: String
}

struct TranscriptionOutput: Sendable {
    var text: String
    var segments: [TranscriptSegment]
    var duration: Double
    /// Word-level timings (empty when the provider has none); used to split segments at
    /// speaker changes.
    var words: [TimedWord] = []
}

struct SpeakerTurn: Sendable, Equatable {
    var speakerId: String
    var start: Double
    var end: Double
    var duration: Double { end - start }
}

struct DiarizationOutput: Sendable {
    var turns: [SpeakerTurn]
    var speakerIds: [String] {
        var seen: [String] = []
        for t in turns where !seen.contains(t.speakerId) { seen.append(t.speakerId) }
        return seen
    }
}

/// A transcript segment with a resolved speaker label.
struct LabeledSegment: Sendable, Equatable {
    var speaker: String
    var start: Double
    var end: Double
    var text: String
}

protocol TranscriptionProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var isAvailable: Bool { get async }
    func transcribe(audioPath: URL, language: String?) async throws -> TranscriptionOutput
}

protocol DiarizationProvider: Sendable {
    var id: String { get }
    func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationOutput
}

protocol SpeakerEmbeddingProvider: Sendable {
    var id: String { get }
    func extractEmbedding(audioPath: URL, start: Double, end: Double) async throws -> [Float]
    func similarity(_ a: [Float], _ b: [Float]) -> Float
}

enum ProviderError: LocalizedError {
    case transcriptionFailed(String)
    case diarizationFailed(String)
    case embeddingFailed(String)
    case providerNotAvailable(String)

    var errorDescription: String? {
        switch self {
        case .transcriptionFailed(let m): return "Transcription failed: \(m)"
        case .diarizationFailed(let m): return "Diarization failed: \(m)"
        case .embeddingFailed(let m): return "Embedding extraction failed: \(m)"
        case .providerNotAvailable(let m): return "Provider not available: \(m)"
        }
    }
}

func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in 0..<a.count {
        dot += a[i] * b[i]
        na += a[i] * a[i]
        nb += b[i] * b[i]
    }
    let denom = na.squareRoot() * nb.squareRoot()
    return denom > 0 ? dot / denom : 0
}

func averageEmbedding(_ embeddings: [[Float]]) -> [Float] {
    guard let first = embeddings.first else { return [] }
    var sum = [Float](repeating: 0, count: first.count)
    for e in embeddings where e.count == sum.count {
        for i in 0..<e.count { sum[i] += e[i] }
    }
    let n = Float(embeddings.count)
    return sum.map { $0 / n }
}
