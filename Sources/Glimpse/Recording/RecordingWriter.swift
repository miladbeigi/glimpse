import AVFoundation
import CoreMedia

enum RecordingError: LocalizedError {
    case cannotWrite(String)
    case noFrames
    case cameraUnavailable
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .cannotWrite(let why): return "The recording could not be written (\(why))."
        case .noFrames: return "Nothing was recorded."
        case .cameraUnavailable: return "The camera could not be started."
        case .microphoneUnavailable: return "The microphone could not be started."
        }
    }
}

/// Writes screen frames and up to two audio tracks to an MP4.
///
/// Not thread-safe: the owner calls it from one serial queue. Timestamps are on the host clock, which both
/// ScreenCaptureKit and AVCaptureSession use, so tracks line up without any conversion. The file starts at the
/// first video frame; audio from before that is dropped.
final class RecordingWriter: @unchecked Sendable {
    enum AudioTrack: CaseIterable { case system, microphone }

    let url: URL
    let fps: Int
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private var audioInputs: [AudioTrack: AVAssetWriterInput] = [:]
    private(set) var timeline = RecordingTimeline()
    /// Recording time of the first frame (after mapping).
    private(set) var startTime: CMTime?
    private var lastFrame: CMSampleBuffer?
    private var lastFrameTime = CMTime.invalid
    /// Where each audio track's last buffer ends, so buffers never overlap.
    private var audioEnd: [AudioTrack: CMTime] = [:]
    private var finished = false

    /// Tracks that received at least one sample.
    private(set) var audioTracksWritten: Set<AudioTrack> = []

    init(url: URL, width: Int, height: Int, fps: Int, audio: Set<AudioTrack>) throws {
        self.url = url
        self.fps = fps
        try? FileManager.default.removeItem(at: url)
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw RecordingError.cannotWrite(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true

        let video: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: RecordingGeometry.bitRate(width: width, height: height, fps: fps),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: video)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecordingError.cannotWrite("video settings not supported") }
        writer.add(videoInput)

        for track in AudioTrack.allCases where audio.contains(track) {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: track == .system ? 2 : 1,
                AVEncoderBitRateKey: track == .system ? 160_000 : 96_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInputs[track] = input
            }
        }
        guard writer.startWriting() else {
            throw RecordingError.cannotWrite(writer.error?.localizedDescription ?? "could not start")
        }
    }

    var error: Error? { writer.status == .failed ? writer.error : nil }

    func pause(at hostTime: CMTime) { timeline.pause(at: hostTime) }
    func resume(at hostTime: CMTime) { timeline.resume(at: hostTime) }

    /// Seconds recorded so far, not counting pauses.
    func duration(at hostTime: CMTime) -> Double {
        guard let startTime else { return 0 }
        let end = timeline.pausedAt.map { min($0, hostTime) } ?? hostTime
        return max(0, (end - timeline.pausedDuration(before: end) - startTime).seconds)
    }

    // MARK: Appending

    /// A complete screen frame (one with an image).
    func appendVideo(_ sample: CMSampleBuffer) {
        guard !finished, writer.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid, let time = timeline.map(pts) else { return }
        if startTime == nil {
            writer.startSession(atSourceTime: time)
            startTime = time
        }
        // Frames must be strictly increasing.
        guard !lastFrameTime.isValid || time > lastFrameTime else { return }
        guard videoInput.isReadyForMoreMediaData, let retimed = Self.retimed(sample, to: time) else { return }
        if videoInput.append(retimed) {
            lastFrame = retimed
            lastFrameTime = time
        }
    }

    func appendAudio(_ sample: CMSampleBuffer, track: AudioTrack) {
        guard !finished, writer.status == .writing, let startTime, let input = audioInputs[track] else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid, let time = timeline.map(pts) else { return }
        let duration = CMSampleBufferGetDuration(sample)
        if duration.isValid, duration > .zero {
            // Entirely before the first frame: nothing to keep. A buffer straddling it is trimmed by the writer.
            if time + duration <= startTime { return }
            // A buffer that runs into a pause (or spans one) would overlap what's recorded after it: skip it.
            // That leaves a gap of a few milliseconds at the cut instead of shifting the audio out of sync.
            let last = pts + duration - CMTime(value: 1, timescale: pts.timescale)
            guard timeline.map(last) != nil,
                  timeline.pausedDuration(before: last) == timeline.pausedDuration(before: pts) else { return }
            // Real clocks jitter by a few nanoseconds; only a real overlap (a cut) means skipping.
            if let previous = audioEnd[track], previous - time > CMTimeMultiplyByRatio(duration, multiplier: 1, divisor: 4) {
                return
            }
        } else if time < startTime {
            return
        }
        guard input.isReadyForMoreMediaData, let retimed = Self.retimed(sample, to: time) else { return }
        if input.append(retimed) {
            audioTracksWritten.insert(track)
            if duration.isValid { audioEnd[track] = time + duration }
        }
    }

    /// Copy of `sample` shifted so that it starts at `time` (every sample keeps its offset from the first).
    static func retimed(_ sample: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        let original = CMSampleBufferGetPresentationTimeStamp(sample)
        if original == time { return sample }
        let shift = time - original
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(count, 1))
        if count > 0 {
            CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        } else {
            timing[0] = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample), presentationTimeStamp: original,
                                           decodeTimeStamp: .invalid)
        }
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp + shift
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp + shift }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                              sampleTimingEntryCount: timing.count, sampleTimingArray: &timing,
                                              sampleBufferOut: &out)
        return out
    }

    // MARK: Finishing

    /// Ends the file at `hostTime` (or where it was paused), repeating the last frame so a still screen keeps
    /// its full length. Returns the recorded duration in seconds.
    func finish(at hostTime: CMTime, completion: @escaping (Result<Double, Error>) -> Void) {
        guard !finished else { return completion(.failure(RecordingError.cannotWrite("already finished"))) }
        finished = true
        // A writer that failed mid-recording (disk full, encoder reset) throws if asked to finish.
        guard writer.status == .writing else {
            let error = writer.error ?? RecordingError.cannotWrite("the writer stopped")
            if writer.status != .failed { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
            return completion(.failure(error))
        }
        guard let startTime, let lastFrame else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(.failure(writer.error ?? RecordingError.noFrames))
            return
        }
        let end = timeline.pausedAt.map { min($0, hostTime) } ?? hostTime
        var endTime = end - timeline.pausedDuration(before: end)
        let frame = CMTime(value: 1, timescale: CMTimeScale(fps))
        // endSession alone doesn't stretch the last frame, so the file would stop at the last change on screen.
        if endTime > lastFrameTime + frame, let copy = Self.retimed(lastFrame, to: endTime - frame) {
            for _ in 0..<100 where !videoInput.isReadyForMoreMediaData { usleep(5_000) }
            if videoInput.isReadyForMoreMediaData { videoInput.append(copy) }
        }
        endTime = max(endTime, lastFrameTime + frame)
        self.lastFrame = nil
        videoInput.markAsFinished()
        audioInputs.values.forEach { $0.markAsFinished() }
        writer.endSession(atSourceTime: endTime)
        let writer = self.writer
        let duration = (endTime - startTime).seconds
        writer.finishWriting {
            if writer.status == .completed {
                completion(.success(duration))
            } else {
                completion(.failure(writer.error ?? RecordingError.cannotWrite("unknown error")))
            }
        }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        lastFrame = nil
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}
