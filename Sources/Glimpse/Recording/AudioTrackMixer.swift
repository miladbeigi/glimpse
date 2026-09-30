import AVFoundation

/// Merges a movie's audio tracks (system audio + microphone) into one.
///
/// They're recorded as separate tracks because they come from different sources at different times, but most
/// players (browsers, Slack, …) only play a file's first audio track. The video is copied as is; only the audio
/// is decoded, mixed and re-encoded, so this takes seconds even for long recordings.
enum AudioTrackMixer {
    static func mixAudioTracks(of source: URL, into destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let videoTrack = videoTracks.first, audioTracks.count > 1 else {
            throw RecordingError.cannotWrite("nothing to mix")
        }
        let duration = try await asset.load(.duration)
        let videoFormat = try await videoTrack.load(.formatDescriptions).first
        let transform = try await videoTrack.load(.preferredTransform)

        try? FileManager.default.removeItem(at: destination)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: duration)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoIn.transform = transform
        writer.add(videoIn)

        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let audioOut = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcm)
        reader.add(audioOut)
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
        writer.add(audioIn)

        guard reader.startReading() else { throw reader.error ?? RecordingError.cannotWrite("could not read") }
        guard writer.startWriting() else { throw writer.error ?? RecordingError.cannotWrite("could not write") }
        writer.startSession(atSourceTime: .zero)

        let pumps = [(videoOut as AVAssetReaderOutput, videoIn), (audioOut, audioIn)]
        await withTaskGroup(of: Void.self) { group in
            for (index, (output, input)) in pumps.enumerated() {
                let pump = SamplePump(output: output, input: input)
                group.addTask { await pump.run(label: "glimpse.mix.\(index)") }
            }
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? RecordingError.cannotWrite("read failed")
        }
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? RecordingError.cannotWrite("mixing failed")
        }
    }
}

/// Copies samples from a reader output to a writer input whenever the input can take more.
private final class SamplePump: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput) {
        self.output = output
        self.input = input
    }

    func run(label: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var done = false
            input.requestMediaDataWhenReady(on: DispatchQueue(label: label)) { [self] in
                while !done && input.isReadyForMoreMediaData {
                    if let sample = output.copyNextSampleBuffer(), input.append(sample) { continue }
                    done = true
                    input.markAsFinished()
                    cont.resume()
                }
            }
        }
    }
}
