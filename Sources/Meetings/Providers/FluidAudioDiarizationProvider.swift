import FluidAudio
import Foundation

/// `fluidaudio-diarization`: FluidAudio speaker segmentation + clustering.
struct FluidAudioDiarizationProvider: DiarizationProvider {
    let id = "fluidaudio-diarization"

    func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationOutput {
        do {
            let samples = try await AudioSampleCache.shared.samples16k(for: audioPath)
            let result = try await FluidAudioModels.shared.diarize(samples: samples, numSpeakers: numSpeakers)
            let turns = result.segments
                .map { SpeakerTurn(speakerId: Self.normalizedId($0.speakerId), start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
                .sorted { $0.start < $1.start }
            return DiarizationOutput(turns: turns)
        } catch {
            throw ProviderError.diarizationFailed(error.localizedDescription)
        }
    }

    /// FluidAudio uses "Speaker 1" style ids; normalize to "SPEAKER_0".
    static func normalizedId(_ raw: String) -> String {
        if raw.hasPrefix("SPEAKER_") { return raw }
        let digits = raw.filter(\.isNumber)
        if let n = Int(digits) { return "SPEAKER_\(max(0, n - 1))" }
        return raw
    }
}
