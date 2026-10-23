import AVFoundation
import CoreGraphics
import ScreenCaptureKit

/// System audio via ScreenCaptureKit. Excludes this process's audio and captures a
/// minimal 2×2 @ 1 fps video stream, which SCK requires.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onChunk: ((TimedAudioChunk) -> Void)?

    private var stream: SCStream?
    private let resampler = CanonicalResampler()
    private let sampleQueue = DispatchQueue(label: "glimpse.meetings.system-audio")
    private var loggedFormat = false

    private static var cachedPermission: Bool?

    /// Screen Recording permission, checked once per session.
    static var permissionGranted: Bool {
        if let cached = cachedPermission { return cached }
        let granted = CGPreflightScreenCaptureAccess()
        cachedPermission = granted
        return granted
    }

    static func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
    }

    func start() async throws {
        guard Self.permissionGranted else {
            throw NSError(domain: "SystemAudioCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Screen Recording permission not granted"])
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudioCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "No display available"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Int(CanonicalAudio.sampleRate)
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
        log("🔊 System audio capture started")
    }

    func stop() async {
        guard let stream else { return }
        do { try await stream.stopCapture() } catch { log("⚠️ SCStream stop: \(error.localizedDescription)") }
        self.stream = nil
        log("🔊 System audio capture stopped")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        if !loggedFormat {
            loggedFormat = true
            log("🔊 System audio format: \(Int(buffer.format.sampleRate)) Hz × \(buffer.format.channelCount)ch")
        }
        guard let mono = downmixToMono(buffer) else { return }
        let samples = resampler.resample(mono)
        guard !samples.isEmpty else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostSeconds = pts.isValid ? pts.seconds : AVAudioTime.seconds(forHostTime: mach_absolute_time())
        onChunk?(TimedAudioChunk(hostTime: hostSeconds, samples: samples))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("❌ System audio stream stopped: \(error.localizedDescription)")
        self.stream = nil
    }

    /// Read the actual format from the sample buffer and copy it into a PCM buffer.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return nil }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
