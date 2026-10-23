import AVFoundation
import Foundation

/// Records a short voice sample from the microphone and creates a voice profile for every
/// configured name variant.
@MainActor
final class VoiceEnrollment: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording(remaining: Int)
        case processing
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Float = 0

    static let duration = 15

    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private let resampler = CanonicalResampler()
    private var timer: Timer?

    static let prompt = "Read aloud: \"The quick brown fox jumps over the lazy dog. I'm recording my voice so Glimpse can recognize me in meetings. This takes about fifteen seconds.\""

    func start(names: [String], speakersDirectory: URL, completion: @escaping () -> Void) {
        guard phase == .idle || isFinished else { return }
        let names = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !names.isEmpty else {
            phase = .failed("Add at least one name first.")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            guard await MicrophoneCapture.requestPermission() else {
                phase = .failed("Microphone permission denied.")
                return
            }
            do {
                try beginCapture()
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
            var remaining = Self.duration
            phase = .recording(remaining: remaining)
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                Task { @MainActor in
                    guard let self else { return }
                    remaining -= 1
                    if remaining > 0 {
                        self.phase = .recording(remaining: remaining)
                    } else {
                        t.invalidate()
                        await self.finish(names: names, directory: speakersDirectory)
                        completion()
                    }
                }
            }
        }
    }

    var isFinished: Bool {
        switch phase {
        case .done, .failed: return true
        default: return false
        }
    }

    func reset() { phase = .idle }

    private func beginCapture() throws {
        samples = []
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let mono = downmixToMono(buffer) else { return }
            let s = self.resampler.resample(mono)
            let level = rmsLevel(s)
            DispatchQueue.main.async {
                self.samples.append(contentsOf: s)
                self.level = level
            }
        }
        try engine.start()
        self.engine = engine
    }

    private func finish(names: [String], directory: URL) async {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        phase = .processing

        // 48 kHz → 16 kHz by averaging groups of three.
        var s16: [Float] = []
        s16.reserveCapacity(samples.count / 3)
        var i = 0
        while i + 2 < samples.count {
            s16.append((samples[i] + samples[i + 1] + samples[i + 2]) / 3)
            i += 3
        }
        guard s16.count > 16_000 * 3 else {
            phase = .failed("Recording too short.")
            return
        }
        do {
            let embedding = try await FluidAudioModels.shared.embedding(samples: s16)
            let store = VoiceProfileStore(directory: directory)
            // One profile under the primary name; the other names match it as aliases. Saving
            // the same voice under several names made those names useless for recognition (and
            // turned other people's names, added here by mistake, into copies of this voice).
            guard let primary = names.first else { throw NSError(domain: "VoiceEnrollment", code: 1, userInfo: [NSLocalizedDescriptionKey: "Add your name first."]) }
            for alias in names.dropFirst() where store.exists(alias) { store.delete(alias) }
            try store.save(VoiceProfile(name: primary, embedding: embedding))
            phase = .done("Voice profile saved for \(primary).")
            log("✅ Voice profile enrolled for \(names)")
        } catch {
            phase = .failed(error.localizedDescription)
            log("❌ Voice enrollment failed: \(error.localizedDescription)")
        }
    }
}
