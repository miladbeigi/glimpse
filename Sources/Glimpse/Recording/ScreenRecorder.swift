@preconcurrency import AVFoundation
import ScreenCaptureKit

/// Streams a display (or part of it) plus system audio and a microphone into a `RecordingWriter`.
///
/// Every sample arrives on one serial queue, which also owns the writer. System audio comes from ScreenCaptureKit;
/// the microphone from AVCaptureSession, since ScreenCaptureKit only records microphones from macOS 15.
/// Control (start, stop, …) happens on the main actor; the sample callbacks only touch queue-owned state.
final class ScreenRecorder: NSObject, @unchecked Sendable {
    struct Options {
        var filter: SCContentFilter
        /// Display-local, top-left points; nil records the whole display.
        var sourceRect: CGRect?
        var width: Int
        var height: Int
        var fps: Int
        var showsCursor: Bool
        var showsClicks: Bool
        var systemAudio: Bool
        var microphone: AVCaptureDevice?
    }

    private let queue = DispatchQueue(label: "glimpse.recording", qos: .userInteractive)
    // Main actor.
    private var stream: SCStream?
    private var micSession: AVCaptureSession?
    // Queue.
    private var writer: RecordingWriter?
    private var micClock: CMClock?
    private var lastLevelReport = CFAbsoluteTimeGetCurrent()

    /// Called on the main queue if capture stops on its own (display gone, sharing stopped from the menu bar…).
    var onInterrupted: ((Error) -> Void)?
    /// Microphone level, 0…1, about ten times a second, on the main queue.
    var onMicLevel: ((Float) -> Void)?

    static var hostTime: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    @MainActor
    func start(_ options: Options, to url: URL) async throws {
        var tracks: Set<RecordingWriter.AudioTrack> = []
        if options.systemAudio { tracks.insert(.system) }
        if options.microphone != nil { tracks.insert(.microphone) }
        let writer = try RecordingWriter(url: url, width: options.width, height: options.height, fps: options.fps, audio: tracks)
        queue.sync { self.writer = writer }

        if let mic = options.microphone {
            do {
                try await startMicrophone(mic)
            } catch {
                queue.sync { writer.cancel() }
                throw error
            }
        }

        let config = SCStreamConfiguration()
        config.width = options.width
        config.height = options.height
        if let rect = options.sourceRect { config.sourceRect = rect }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = options.showsCursor
        if #available(macOS 15.0, *) { config.showMouseClicks = options.showsClicks }
        config.queueDepth = 8
        config.capturesAudio = options.systemAudio
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: options.filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if options.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
            try await stream.startCapture()
        } catch {
            await stopMicrophone()
            queue.sync { writer.cancel() }
            throw error
        }
        self.stream = stream
    }

    /// Keeps the region current if the camera bubble or other included windows change (e.g. camera toggled).
    @MainActor
    func update(filter: SCContentFilter) {
        stream?.updateContentFilter(filter) { error in
            if let error { NSLog("Glimpse: could not update the recording filter: \(error)") }
        }
    }

    func pause() {
        let now = Self.hostTime
        queue.async { self.writer?.pause(at: now) }
    }

    func resume() {
        let now = Self.hostTime
        queue.async { self.writer?.resume(at: now) }
    }

    /// Seconds recorded so far, not counting pauses.
    var elapsed: Double {
        let now = Self.hostTime
        return queue.sync { writer?.duration(at: now) ?? 0 }
    }

    /// Stops capturing and finishes the file. Returns its duration in seconds.
    @MainActor
    func stop() async throws -> Double {
        let end = Self.hostTime
        // Keep writing until capture has stopped: audio arrives a few hundred milliseconds late, and the writer
        // trims whatever lands after `end`.
        await stopCapture()
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard let writer = self.writer else { return cont.resume(throwing: RecordingError.noFrames) }
                self.writer = nil
                writer.finish(at: end) { cont.resume(with: $0) }
            }
        }
    }

    /// Stops capturing and deletes the file.
    @MainActor
    func cancel() async {
        let writer = queue.sync { () -> RecordingWriter? in
            defer { self.writer = nil }
            return self.writer
        }
        await stopCapture()
        queue.sync { writer?.cancel() }
    }

    @MainActor
    private func stopCapture() async {
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        await stopMicrophone()
    }

    // MARK: Microphone

    @MainActor
    private func startMicrophone(_ device: AVCaptureDevice) async throws {
        let session = AVCaptureSession()
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            throw RecordingError.microphoneUnavailable
        }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        // Float PCM at the writer's rate; AAC encoding happens in the writer.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw RecordingError.microphoneUnavailable }
        session.addOutput(output)
        // startRunning blocks until the device is up.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
                cont.resume()
            }
        }
        guard session.isRunning else { throw RecordingError.microphoneUnavailable }
        micSession = session
        let clock = session.synchronizationClock
        queue.sync { micClock = clock }
    }

    @MainActor
    private func stopMicrophone() async {
        guard let session = micSession else { return }
        micSession = nil
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                session.stopRunning()
                cont.resume()
            }
        }
    }

    private func reportLevel(_ sample: CMSampleBuffer) {
        guard let onMicLevel else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLevelReport > 0.1, let block = CMSampleBufferGetDataBuffer(sample) else { return }
        lastLevelReport = now
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr, let pointer, length >= 4 else { return }
        let count = length / 4
        var peak: Float = 0
        pointer.withMemoryRebound(to: Float.self, capacity: count) { samples in
            for i in 0..<count { peak = max(peak, abs(samples[i])) }
        }
        // Rough dB scale: -50 dB → 0, 0 dB → 1.
        let db = 20 * log10(max(peak, 0.000_01))
        let level = min(max((db + 50) / 50, 0), 1)
        DispatchQueue.main.async { onMicLevel(level) }
    }
}

extension ScreenRecorder: SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid, let writer else { return }
        switch type {
        case .screen:
            // Idle frames (nothing changed) carry no image.
            guard let info = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                  CMSampleBufferGetImageBuffer(sample) != nil else { return }
            writer.appendVideo(sample)
        case .audio:
            writer.appendAudio(sample, track: .system)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Glimpse: recording stream stopped: \(error)")
        DispatchQueue.main.async { self.onInterrupted?(error) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let writer else { return }
        // Capture sessions may run on the audio device's clock; move the sample onto the host clock.
        var sample = sample
        if let clock = micClock {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let host = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
            if host.isValid, host != pts, let moved = RecordingWriter.retimed(sample, to: host) { sample = moved }
        }
        writer.appendAudio(sample, track: .microphone)
        reportLevel(sample)
    }
}
