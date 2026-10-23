import FluidAudio
import Foundation

/// `fluidaudio-embedding`: 256-dim WeSpeaker embeddings.
struct FluidAudioEmbeddingProvider: SpeakerEmbeddingProvider {
    let id = "fluidaudio-embedding"

    func extractEmbedding(audioPath: URL, start: Double, end: Double) async throws -> [Float] {
        do {
            let samples = try await AudioSampleCache.shared.samples16k(for: audioPath)
            let rate = 16_000.0
            let lo = max(0, min(samples.count, Int(start * rate)))
            let hi = max(lo, min(samples.count, Int(end * rate)))
            guard hi - lo >= Int(rate * 0.5) else {
                throw ProviderError.embeddingFailed("segment too short (\(String(format: "%.2f", end - start))s)")
            }
            let slice = Array(samples[lo..<hi])
            let embedding = try await FluidAudioModels.shared.embedding(samples: slice)
            guard !embedding.isEmpty else { throw ProviderError.embeddingFailed("empty embedding") }
            return embedding
        } catch let e as ProviderError {
            throw e
        } catch {
            throw ProviderError.embeddingFailed(error.localizedDescription)
        }
    }

    func similarity(_ a: [Float], _ b: [Float]) -> Float {
        cosineSimilarity(a, b)
    }
}
