import AVFoundation
import CoreMedia
import XCTest
@testable import Glimpse

final class RecordingTimelineTests: XCTestCase {
    private func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }

    private func assertMaps(_ timeline: RecordingTimeline, _ input: Double, to expected: Double?,
                            file: StaticString = #filePath, line: UInt = #line) {
        let mapped = timeline.map(t(input))
        if let expected {
            guard let mapped else { return XCTFail("\(input) was dropped, expected \(expected)", file: file, line: line) }
            XCTAssertEqual(mapped.seconds, expected, accuracy: 1e-6, "map(\(input))", file: file, line: line)
        } else {
            XCTAssertNil(mapped, "map(\(input)) should be dropped", file: file, line: line)
        }
    }

    func testNoPausesIsIdentity() {
        let timeline = RecordingTimeline()
        XCTAssertFalse(timeline.isPaused)
        for s in [0.0, 0.5, 1, 1000, 12_345.678] { assertMaps(timeline, s, to: s) }
        XCTAssertEqual(timeline.pausedDuration(before: t(1000)).seconds, 0, accuracy: 1e-9)
    }

    func testSamplesInsidePauseAreDropped() {
        var timeline = RecordingTimeline()
        timeline.pause(at: t(10))
        XCTAssertTrue(timeline.isPaused)
        timeline.resume(at: t(12))
        XCTAssertFalse(timeline.isPaused)
        assertMaps(timeline, 10, to: nil)     // pause start is excluded
        assertMaps(timeline, 11, to: nil)
        assertMaps(timeline, 11.999, to: nil)
        assertMaps(timeline, 9.999, to: 9.999)
    }

    func testShiftsAfterOnePause() {
        var timeline = RecordingTimeline()
        timeline.pause(at: t(10))
        timeline.resume(at: t(12))
        assertMaps(timeline, 12, to: 10)      // resume instant lines up with the pause instant
        assertMaps(timeline, 15, to: 13)
        XCTAssertEqual(timeline.pausedDuration(before: t(11)).seconds, 0, accuracy: 1e-9)
        XCTAssertEqual(timeline.pausedDuration(before: t(20)).seconds, 2, accuracy: 1e-9)
    }

    func testShiftsAfterSeveralPauses() {
        var timeline = RecordingTimeline()
        timeline.pause(at: t(1)); timeline.resume(at: t(2))
        timeline.pause(at: t(4)); timeline.resume(at: t(6.5))
        timeline.pause(at: t(8)); timeline.resume(at: t(8.25))
        XCTAssertEqual(timeline.pauses.count, 3)
        assertMaps(timeline, 0.5, to: 0.5)
        assertMaps(timeline, 1.5, to: nil)
        assertMaps(timeline, 3, to: 2)
        assertMaps(timeline, 5, to: nil)
        assertMaps(timeline, 7, to: 3.5)
        assertMaps(timeline, 8.1, to: nil)
        assertMaps(timeline, 10, to: 6.25)
        XCTAssertEqual(timeline.pausedDuration(before: t(100)).seconds, 3.75, accuracy: 1e-9)
    }

    func testOpenPauseDropsEverythingAfter() {
        var timeline = RecordingTimeline()
        timeline.pause(at: t(1)); timeline.resume(at: t(2))
        timeline.pause(at: t(5))
        XCTAssertTrue(timeline.isPaused)
        assertMaps(timeline, 4.9, to: 3.9)
        assertMaps(timeline, 5, to: nil)
        assertMaps(timeline, 50, to: nil)
        assertMaps(timeline, 1e6, to: nil)
    }

    func testResumeWithoutPauseIsNoOp() {
        var timeline = RecordingTimeline()
        timeline.resume(at: t(3))
        XCTAssertTrue(timeline.pauses.isEmpty)
        XCTAssertFalse(timeline.isPaused)
        assertMaps(timeline, 5, to: 5)
    }

    func testSecondPauseWhilePausedKeepsFirstStart() {
        var timeline = RecordingTimeline()
        timeline.pause(at: t(2))
        timeline.pause(at: t(3))
        timeline.resume(at: t(4))
        XCTAssertEqual(timeline.pauses.count, 1)
        assertMaps(timeline, 2.5, to: nil)
        assertMaps(timeline, 5, to: 3)
    }
}

final class RecordingGeometryTests: XCTestCase {
    func testRetinaDoublesPoints() {
        let size = RecordingGeometry.outputSize(points: CGSize(width: 800, height: 600), scale: 2)
        XCTAssertEqual(size.width, 1600)
        XCTAssertEqual(size.height, 1200)
        let oneX = RecordingGeometry.outputSize(points: CGSize(width: 800, height: 600), scale: 1)
        XCTAssertEqual(oneX.width, 800)
        XCTAssertEqual(oneX.height, 600)
    }

    func testFiveKIsCappedKeepingAspect() {
        let size = RecordingGeometry.outputSize(points: CGSize(width: 2560, height: 1440), scale: 2)
        XCTAssertEqual(size.width, 4096)
        XCTAssertEqual(size.height, 2304)
    }

    func testUltrawideIsCappedByWidth() {
        let size = RecordingGeometry.outputSize(points: CGSize(width: 3440, height: 1440), scale: 2)
        XCTAssertEqual(size.width, 4096)
        XCTAssertLessThanOrEqual(size.height, RecordingGeometry.maxHeight)
        XCTAssertEqual(Double(size.width) / Double(size.height), 3440.0 / 1440.0, accuracy: 0.01)
        XCTAssertEqual(size.height % 2, 0)
    }

    func testTallRegionIsCappedByHeight() {
        let size = RecordingGeometry.outputSize(points: CGSize(width: 1000, height: 2000), scale: 2)
        XCTAssertLessThanOrEqual(size.height, RecordingGeometry.maxHeight)
        XCTAssertEqual(size.height, 2304)
        XCTAssertEqual(size.width, 1152)
    }

    func testOddSizesRoundToEven() {
        let a = RecordingGeometry.outputSize(points: CGSize(width: 101, height: 51), scale: 1)
        XCTAssertEqual(a.width, 100)
        XCTAssertEqual(a.height, 50)
        let b = RecordingGeometry.outputSize(points: CGSize(width: 333.7, height: 201.3), scale: 2)
        XCTAssertEqual(b.width, 666)
        XCTAssertEqual(b.height, 402)
        let tiny = RecordingGeometry.outputSize(points: CGSize(width: 0.4, height: 1), scale: 1)
        XCTAssertEqual(tiny.width, 2)
        XCTAssertEqual(tiny.height, 2)
    }

    func testBitRateIsClamped() {
        XCTAssertEqual(RecordingGeometry.bitRate(width: 100, height: 100, fps: 30), 2_000_000)
        XCTAssertEqual(RecordingGeometry.bitRate(width: 4096, height: 2304, fps: 240), 60_000_000)
        let hd = RecordingGeometry.bitRate(width: 1920, height: 1080, fps: 30)
        XCTAssertGreaterThan(hd, 2_000_000)
        XCTAssertLessThan(hd, 60_000_000)
    }

    func testFormatDuration() {
        XCTAssertEqual(RecordingGeometry.formatDuration(0), "0:00")
        XCTAssertEqual(RecordingGeometry.formatDuration(-3), "0:00")
        XCTAssertEqual(RecordingGeometry.formatDuration(9.99), "0:09")
        XCTAssertEqual(RecordingGeometry.formatDuration(65), "1:05")
        XCTAssertEqual(RecordingGeometry.formatDuration(600), "10:00")
        XCTAssertEqual(RecordingGeometry.formatDuration(3599.9), "59:59")
        XCTAssertEqual(RecordingGeometry.formatDuration(3600), "1:00:00")
        XCTAssertEqual(RecordingGeometry.formatDuration(3723), "1:02:03")
    }
}

final class RecordingWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlimpseRecordingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Host-clock-like base so the test doesn't rely on timestamps starting at zero.
    private let base = 1000.0
    private func host(_ s: Double) -> CMTime { CMTime(seconds: base + s, preferredTimescale: 48_000) }

    private func videoSample(at time: CMTime, width: Int, height: Int, shade: UInt8) -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
        let pb = pixelBuffer!
        CVPixelBufferLockBaseAddress(pb, [])
        memset(CVPixelBufferGetBaseAddress(pb), Int32(shade), CVPixelBufferGetDataSize(pb))
        CVPixelBufferUnlockBaseAddress(pb, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format!,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return sample!
    }

    /// Interleaved 32-bit float LPCM at 48 kHz: a sine tone on every channel.
    private func audioSample(at time: CMTime, frames: Int, channels: Int, frequency: Double) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let bytes = frames * channels * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                           blockBufferOut: &block)
        var samples = [Float](repeating: 0, count: frames * channels)
        let start = time.seconds
        for i in 0..<frames {
            let v = Float(sin(2 * .pi * frequency * (start + Double(i) / 48_000)) * 0.3)
            for c in 0..<channels { samples[i * channels + c] = v }
        }
        samples.withUnsafeBytes {
            _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0,
                                              dataLength: bytes)
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!,
                                                             sampleCount: frames, presentationTimeStamp: time,
                                                             packetDescriptions: nil, sampleBufferOut: &sample)
        return sample!
    }

    private final class ResultBox: @unchecked Sendable { var result: Result<Double, Error>? }

    private func finish(_ writer: RecordingWriter, at time: CMTime) async -> Result<Double, Error>? {
        let box = ResultBox()
        let done = expectation(description: "finish")
        // The completion runs on an arbitrary queue.
        writer.finish(at: time) { result in
            box.result = result
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 30)
        return box.result
    }

    private func audioTrackLength(_ track: AVAssetTrack) async throws -> Double {
        try await track.load(.timeRange).duration.seconds
    }

    func testRetimedShiftsPresentationTime() throws {
        let sample = videoSample(at: host(1), width: 16, height: 16, shade: 0)
        let target = CMTime(seconds: 0.25, preferredTimescale: 600)
        let moved = try XCTUnwrap(RecordingWriter.retimed(sample, to: target))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(moved).seconds, 0.25, accuracy: 1e-6)
        // Same time: returned as is.
        let same = try XCTUnwrap(RecordingWriter.retimed(sample, to: host(1)))
        XCTAssertTrue(same === sample)
    }

    func testFinishWithoutFramesFailsAndRemovesFile() async throws {
        let url = directory.appendingPathComponent("empty.mp4")
        let writer = try RecordingWriter(url: url, width: 320, height: 180, fps: 30, audio: [.microphone])
        // Audio before the first frame is dropped, so this alone doesn't start the file.
        writer.appendAudio(audioSample(at: host(0), frames: 1024, channels: 1, frequency: 440), track: .microphone)
        XCTAssertEqual(writer.duration(at: host(5)), 0)
        let result = await finish(writer, at: host(5))
        guard case .failure = result else { return XCTFail("expected failure, got \(String(describing: result))") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Frames from 0.1 s, audio on both tracks from 0 s (the part before the first frame is dropped), a pause from
    /// 1.5 to 2.5, the last change on screen at ~4.1 s and stop at 6.0: the file lasts 6.0 - 0.1 - 1 = 4.9 s.
    func testWritesPausedRecordingAndMixesAudio() async throws {
        let raw = directory.appendingPathComponent("raw.mp4")
        let writer = try RecordingWriter(url: raw, width: 640, height: 360, fps: 30, audio: [.system, .microphone])

        var paused = false, resumed = false
        var i = 0
        while true {
            let a = Double(i) * 1024 / 48_000
            if a >= 4.0 { break }
            if a >= 1.5 && !paused { writer.pause(at: host(1.5)); paused = true }
            if a >= 2.5 && !resumed { writer.resume(at: host(2.5)); resumed = true }
            writer.appendAudio(audioSample(at: host(a), frames: 1024, channels: 2, frequency: 440), track: .system)
            writer.appendAudio(audioSample(at: host(a), frames: 1024, channels: 1, frequency: 660), track: .microphone)
            // Appending in a tight loop outruns the encoder (isReadyForMoreMediaData goes false and frames drop).
            usleep(2_000)
            writer.appendVideo(videoSample(at: host(a + 0.1), width: 640, height: 360, shade: UInt8(i % 255)))
            i += 1
        }
        XCTAssertNil(writer.error)
        XCTAssertEqual(writer.audioTracksWritten, [.system, .microphone])
        XCTAssertEqual(writer.duration(at: host(6.0)), 4.9, accuracy: 0.05)

        let result = await finish(writer, at: host(6.0))
        let reported = try XCTUnwrap(result).get()
        XCTAssertEqual(reported, 4.9, accuracy: 0.05)

        let rawAsset = AVURLAsset(url: raw)
        let rawDuration = try await rawAsset.load(.duration).seconds
        XCTAssertEqual(rawDuration, 4.9, accuracy: 0.15)
        let rawVideo = try await rawAsset.loadTracks(withMediaType: .video)
        XCTAssertEqual(rawVideo.count, 1)
        let rawAudio = try await rawAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(rawAudio.count, 2)
        for track in rawAudio {
            // Fed 0…4.0 minus what came before the first frame (0.1) and the 1 s pause.
            let length = try await audioTrackLength(track)
            XCTAssertEqual(length, 2.9, accuracy: 0.2)
        }

        let mixed = directory.appendingPathComponent("mixed.mp4")
        try await AudioTrackMixer.mixAudioTracks(of: raw, into: mixed)
        let mixedAsset = AVURLAsset(url: mixed)
        let mixedDuration = try await mixedAsset.load(.duration).seconds
        XCTAssertEqual(mixedDuration, 4.9, accuracy: 0.15)
        let mixedVideo = try await mixedAsset.loadTracks(withMediaType: .video)
        XCTAssertEqual(mixedVideo.count, 1)
        let mixedAudio = try await mixedAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(mixedAudio.count, 1)
        let mixedTrack = try XCTUnwrap(mixedAudio.first)
        let mixedLength = try await audioTrackLength(mixedTrack)
        XCTAssertEqual(mixedLength, 2.9, accuracy: 0.2)
        let formats = try await mixedTrack.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
        XCTAssertEqual(asbd.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(asbd.mChannelsPerFrame, 2)
    }

    /// A pause that starts and ends mid-buffer: the buffers running into it are skipped rather than overlapping
    /// what's recorded after it, and the tracks still line up with the video.
    func testPauseMidBufferKeepsAudioInStep() async throws {
        let raw = directory.appendingPathComponent("midbuffer.mp4")
        let writer = try RecordingWriter(url: raw, width: 320, height: 180, fps: 30, audio: [.microphone])
        let pauseStart = 1.51, pauseEnd = 2.537
        var paused = false, resumed = false
        var i = 0
        while true {
            let a = Double(i) * 1024 / 48_000
            if a >= 3.0 { break }
            if a >= pauseStart && !paused { writer.pause(at: host(pauseStart)); paused = true }
            if a >= pauseEnd && !resumed { writer.resume(at: host(pauseEnd)); resumed = true }
            writer.appendAudio(audioSample(at: host(a), frames: 1024, channels: 1, frequency: 440), track: .microphone)
            usleep(2_000)
            writer.appendVideo(videoSample(at: host(a), width: 320, height: 180, shade: UInt8(i % 255)))
            i += 1
        }
        XCTAssertNil(writer.error)
        let result = await finish(writer, at: host(3.0))
        let duration = try XCTUnwrap(result).get()
        XCTAssertEqual(duration, 3.0 - (pauseEnd - pauseStart), accuracy: 0.05)
        let audio = try await AVURLAsset(url: raw).loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(audio.first)
        // At most a buffer (21 ms) on each side of the cut is skipped.
        let length = try await audioTrackLength(track)
        XCTAssertEqual(length, duration, accuracy: 0.07)
    }

    func testMixerRefusesSingleAudioTrack() async throws {
        let raw = directory.appendingPathComponent("single.mp4")
        let writer = try RecordingWriter(url: raw, width: 320, height: 180, fps: 30, audio: [.microphone])
        for i in 0..<30 {
            let a = Double(i) / 30
            writer.appendAudio(audioSample(at: host(a), frames: 1600, channels: 1, frequency: 440), track: .microphone)
            usleep(2_000)
            writer.appendVideo(videoSample(at: host(a), width: 320, height: 180, shade: UInt8(i)))
        }
        let result = await finish(writer, at: host(1.0))
        _ = try XCTUnwrap(result).get()
        do {
            try await AudioTrackMixer.mixAudioTracks(of: raw, into: directory.appendingPathComponent("out.mp4"))
            XCTFail("expected an error for a file with one audio track")
        } catch {}
    }
}
