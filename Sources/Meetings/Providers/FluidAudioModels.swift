import FluidAudio
import Foundation

/// Lazily downloads (first use) and loads FluidAudio models, shared by all providers.
actor FluidAudioModels {
    static let shared = FluidAudioModels()

    private var asr: AsrManager?
    private var diarizer: DiarizerBox?

    /// `DiarizerManager` is a non-Sendable class; it is only touched inside this actor.
    final class DiarizerBox: @unchecked Sendable {
        let manager: DiarizerManager
        init(_ m: DiarizerManager) { manager = m }
    }

    func asrManager() async throws -> AsrManager {
        if let asr { return asr }
        log("📝 Loading Parakeet ASR models (downloaded on first use)…")
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asr = manager
        log("✅ Parakeet ASR ready")
        return manager
    }

    func diarizerManager() async throws -> DiarizerBox {
        if let diarizer { return diarizer }
        log("🔗 Loading diarization models (downloaded on first use)…")
        let models = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager(config: DiarizerConfig())
        manager.initialize(models: models)
        let box = DiarizerBox(manager)
        diarizer = box
        log("✅ Diarizer ready")
        return box
    }

    func diarize(samples: [Float], numSpeakers: Int?) async throws -> DiarizationResult {
        if let numSpeakers, numSpeakers > 0 {
            // Cluster count is a construction-time setting; use a dedicated manager.
            var config = DiarizerConfig()
            config.numClusters = numSpeakers
            let manager = DiarizerManager(config: config)
            manager.initialize(models: try await DiarizerModels.downloadIfNeeded())
            return try manager.performCompleteDiarization(samples, sampleRate: 16_000)
        }
        let box = try await diarizerManager()
        // Speaker ids must not leak between recordings.
        box.manager.speakerManager.reset()
        return try box.manager.performCompleteDiarization(samples, sampleRate: 16_000)
    }

    func embedding(samples: [Float]) async throws -> [Float] {
        let box = try await diarizerManager()
        return try box.manager.extractSpeakerEmbedding(from: samples)
    }
}

/// Reads a whole audio file as 16 kHz mono floats, caching the most recent file (speaker
/// identification extracts many embeddings from the same channel).
actor AudioSampleCache {
    static let shared = AudioSampleCache()
    private var cachedURL: URL?
    private var cachedSamples: [Float] = []

    func samples16k(for url: URL) throws -> [Float] {
        if cachedURL == url { return cachedSamples }
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(url)
        cachedURL = url
        cachedSamples = samples
        return samples
    }

    func clear() {
        cachedURL = nil
        cachedSamples = []
    }
}
