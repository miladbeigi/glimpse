import AVFoundation

/// Microphone capture with voice-processing echo cancellation.
final class MicrophoneCapture: @unchecked Sendable {
    var onChunk: ((TimedAudioChunk) -> Void)?
    /// RMS level (0…1), delivered on the main queue.
    var onLevel: ((Float) -> Void)?

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private let resampler = CanonicalResampler()
    private var configObserver: NSObjectProtocol?
    private var usingVoiceProcessing = false
    private let queue = DispatchQueue(label: "glimpse.meetings.mic")

    static var permissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// True between `start()` and `stop()`, including while a device-change restart is pending.
    private var isCapturing = false

    func start() throws {
        try startPreferredEngine()
        queue.sync { isCapturing = true }
    }

    private func startPreferredEngine() throws {
        do {
            try startEngine(voiceProcessing: true)
        } catch {
            log("🎚️ Voice processing failed (\(error.localizedDescription)); falling back to plain mic capture")
            stopEngine()
            try startEngine(voiceProcessing: false)
        }
    }

    func stop() {
        // On `queue` so an in-flight device-change restart finishes before we tear down.
        queue.sync { isCapturing = false }
        stopEngine()
        log("🎤 Microphone capture stopped")
    }

    private func startEngine(voiceProcessing: Bool) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            // The VPIO unit's input only flows while its render side is pulling frames, so drive
            // the output with a silent, muted source node.
            let silent = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
                let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for buffer in abl {
                    memset(buffer.mData, 0, Int(buffer.mDataByteSize))
                }
                _ = frameCount
                return noErr
            }
            engine.attach(silent)
            engine.connect(silent, to: engine.mainMixerNode, format: nil)
            engine.mainMixerNode.outputVolume = 0
            sourceNode = silent
        }

        try installTap(on: engine)
        engine.prepare()
        try engine.start()
        self.engine = engine
        usingVoiceProcessing = voiceProcessing
        log(voiceProcessing ? "🎚️ Echo cancellation enabled (voice processing)" : "🎤 Plain microphone capture started")

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    /// `installTap` raises an Objective-C exception (which Swift can't catch, so the app
    /// aborts) when the format doesn't match the current hardware. Mid device switch the input
    /// can briefly report 0 Hz / 0 ch, so refuse those instead of crashing.
    private func installTap(on engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        log("🎤 Mic format: \(Int(format.sampleRate)) Hz × \(format.channelCount)ch")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "MicrophoneCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Input device not ready (\(Int(format.sampleRate)) Hz × \(format.channelCount)ch)"])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            self?.handle(buffer, time: time)
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        // Voice processing yields N replicated channels; average them to mono.
        guard let mono = downmixToMono(buffer) else { return }
        let samples = resampler.resample(mono)
        guard !samples.isEmpty else { return }
        let hostSeconds = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : AVAudioTime.seconds(forHostTime: mach_absolute_time())
        onChunk?(TimedAudioChunk(hostTime: hostSeconds, samples: samples))
        let level = rmsLevel(samples)
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    /// Device change (headphones unplugged, AirPods switching profile, …). Reusing the old
    /// engine crashed here on 2026-09-29: its input node still reported the previous device's
    /// format and `installTap` threw. Build a fresh engine instead, retrying while the new
    /// device settles; the recording keeps going (gaps become silence) and never aborts.
    private func handleConfigurationChange(attempt: Int = 0) {
        let delay: TimeInterval = attempt == 0 ? 0.25 : min(5, 0.5 * Double(attempt))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isCapturing else { return }
            if attempt == 0 { log("🔄 Audio engine configuration changed; rebuilding microphone engine") }
            self.stopEngine()
            do {
                try self.startPreferredEngine()
                if attempt > 0 { log("🎤 Microphone recovered after \(attempt + 1) attempts") }
            } catch {
                self.stopEngine()
                guard attempt < Self.maxRestartAttempts else {
                    log("❌ Microphone could not be restarted after device change: \(error.localizedDescription); continuing with system audio only")
                    return
                }
                log("⚠️ Microphone restart attempt \(attempt + 1) failed: \(error.localizedDescription); retrying")
                self.handleConfigurationChange(attempt: attempt + 1)
            }
        }
    }

    private static let maxRestartAttempts = 20

    private func stopEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if usingVoiceProcessing {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
        if let sourceNode { engine.detach(sourceNode) }
        sourceNode = nil
        self.engine = nil
    }
}
