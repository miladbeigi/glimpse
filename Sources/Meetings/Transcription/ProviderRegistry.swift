import Foundation

/// Central registry of providers. The AppDelegate registers the FluidAudio providers at
/// launch; the pipeline picks the active ones from here.
final class ProviderRegistry: @unchecked Sendable {
    static let shared = ProviderRegistry()

    private let lock = NSLock()
    private var transcription: [String: TranscriptionProvider] = [:]
    private var diarization: [String: DiarizationProvider] = [:]
    private var embedding: [String: SpeakerEmbeddingProvider] = [:]

    var activeTranscriptionId = "fluidaudio-parakeet"
    var activeDiarizationId: String? = "fluidaudio-diarization"
    var activeEmbeddingId = "fluidaudio-embedding"

    func register(_ p: TranscriptionProvider) { lock.withLock { transcription[p.id] = p } }
    func register(_ p: DiarizationProvider) { lock.withLock { diarization[p.id] = p } }
    func register(_ p: SpeakerEmbeddingProvider) { lock.withLock { embedding[p.id] = p } }

    var transcriptionProvider: TranscriptionProvider? { lock.withLock { transcription[activeTranscriptionId] } }
    var diarizationProvider: DiarizationProvider? {
        lock.withLock { activeDiarizationId.flatMap { diarization[$0] } }
    }
    var embeddingProvider: SpeakerEmbeddingProvider? { lock.withLock { embedding[activeEmbeddingId] } }
}
