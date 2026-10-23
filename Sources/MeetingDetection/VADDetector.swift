import AVFoundation
import FluidAudio
import Foundation

/// Voice activity from the microphone using FluidAudio's Silero VAD. The microphone
/// is opened lazily by the detection service and released after inactivity.
public final class VADDetector: @unchecked Sendable {
    /// Sensitivity 0…1 maps onto the model probability threshold.
    public var sensitivity: Double {
        didSet { threshold = Self.threshold(for: sensitivity) }
    }

    private var threshold: Float
    private var engine: AVAudioEngine?
    private var vad: VadManager?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var pending: [Float] = []
    private var recent: [Bool] = []
    private let lock = NSLock()
    private let processingQueue = DispatchQueue(label: "glimpse.meetings.vad")

    /// Fraction of the last `window` results that must be active.
    public static let smoothingWindow = 10
    public static let smoothingFraction = 0.3

    public private(set) var isRunning = false
    /// True when samples are pushed in by the caller (e.g. the recording microphone) instead of
    /// the detector opening its own input engine.
    public private(set) var isExternallyFed = false

    public init(sensitivity: Double = 0.5) {
        self.sensitivity = sensitivity
        self.threshold = Self.threshold(for: sensitivity)
    }

    /// Higher sensitivity → requires stronger voice signals (matches the Settings copy).
    static func threshold(for sensitivity: Double) -> Float {
        Float(0.2 + 0.7 * min(max(sensitivity, 0), 1))
    }

    public func start() async throws {
        if isRunning { return }
        if vad == nil {
            vad = try await VadManager(config: VadConfig(defaultThreshold: threshold))
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw NSError(domain: "VADDetector", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input"]) }
        converter = AVAudioConverter(from: format, to: targetFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        try engine.start()
        self.engine = engine
        isRunning = true
    }

    /// Switch to caller-fed samples (see `ingest`). Stops the detector's own engine so two
    /// capture engines never fight over the microphone.
    public func startExternalFeed() async throws {
        if isExternallyFed { return }
        if engine != nil { stop() }
        if vad == nil {
            vad = try await VadManager(config: VadConfig(defaultThreshold: threshold))
        }
        isExternallyFed = true
        isRunning = true
    }

    /// Leave external-feed mode (the detector is then stopped).
    public func stopExternalFeed() {
        guard isExternallyFed else { return }
        isExternallyFed = false
        stop()
    }

    /// Push 48 kHz mono samples (decimated to 16 kHz here).
    public func ingest48k(_ samples: [Float]) {
        guard isExternallyFed else { return }
        var out = [Float]()
        out.reserveCapacity(samples.count / 3)
        var i = 0
        while i + 2 < samples.count {
            out.append((samples[i] + samples[i + 1] + samples[i + 2]) / 3)
            i += 3
        }
        enqueue16k(out)
    }

    public func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        lock.lock()
        pending.removeAll()
        recent.removeAll()
        lock.unlock()
    }

    public func check() -> SignalState {
        guard isRunning else { return .unknown }
        lock.lock()
        defer { lock.unlock() }
        guard !recent.isEmpty else { return .unknown }
        let active = recent.filter { $0 }.count
        return Double(active) / Double(max(recent.count, 1)) >= Self.smoothingFraction ? .active : .inactive
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData else { return }
        enqueue16k(Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))))
    }

    private func enqueue16k(_ samples: [Float]) {
        lock.lock()
        pending.append(contentsOf: samples)
        var chunks: [[Float]] = []
        while pending.count >= VadManager.chunkSize {
            chunks.append(Array(pending.prefix(VadManager.chunkSize)))
            pending.removeFirst(VadManager.chunkSize)
        }
        lock.unlock()

        guard !chunks.isEmpty, let vad else { return }
        let threshold = self.threshold
        let batch = chunks
        processingQueue.async { [weak self] in
            Task {
                for chunk in batch {
                    guard let results = try? await vad.process(chunk) else { continue }
                    let active = results.contains { $0.probability >= threshold }
                    self?.record(active)
                }
            }
        }
    }

    private func record(_ active: Bool) {
        lock.lock()
        recent.append(active)
        if recent.count > Self.smoothingWindow { recent.removeFirst(recent.count - Self.smoothingWindow) }
        lock.unlock()
    }
}
