import AVFoundation
import Foundation

/// Minimal 16-bit PCM WAV writer that streams to disk.
final class PCM16WAVWriter {
    let url: URL
    let channels: Int
    let sampleRate: Int
    private let handle: FileHandle
    private(set) var framesWritten: Int64 = 0

    init(url: URL, channels: Int, sampleRate: Int) throws {
        self.url = url
        self.channels = channels
        self.sampleRate = sampleRate
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        handle.write(Self.header(channels: channels, sampleRate: sampleRate, dataBytes: 0))
    }

    /// Append interleaved Int16 frames.
    func write(interleaved samples: [Int16]) {
        guard !samples.isEmpty else { return }
        samples.withUnsafeBufferPointer { handle.write(Data(buffer: $0)) }
        framesWritten += Int64(samples.count / channels)
    }

    func finish() throws {
        let dataBytes = framesWritten * Int64(channels) * 2
        try handle.seek(toOffset: 0)
        handle.write(Self.header(channels: channels, sampleRate: sampleRate, dataBytes: UInt32(clamping: dataBytes)))
        try handle.close()
    }

    static func header(channels: Int, sampleRate: Int, dataBytes: UInt32) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 &+ dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }
}

@inline(__always) func floatToInt16(_ f: Float) -> Int16 {
    Int16(max(-1, min(1, f)) * Float(Int16.max))
}

/// Streaming mono WAV writer used when splitting stereo recordings.
final class MonoWAVWriter {
    private let writer: PCM16WAVWriter
    init(url: URL, sampleRate: Int) throws {
        writer = try PCM16WAVWriter(url: url, channels: 1, sampleRate: sampleRate)
    }
    func write(_ samples: UnsafeBufferPointer<Float>) {
        writer.write(interleaved: samples.map(floatToInt16))
    }
    func finish() throws { try writer.finish() }
    var framesWritten: Int64 { writer.framesWritten }
}

enum WAVInfo {
    struct Info {
        let channels: Int
        let sampleRate: Double
        let frames: Int64
        var duration: TimeInterval { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
    }

    /// True audio duration from the header (frames ÷ sample rate).
    static func read(_ url: URL) -> Info? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Info(channels: Int(file.fileFormat.channelCount), sampleRate: file.fileFormat.sampleRate, frames: file.length)
    }

    /// Split a stereo WAV into two mono WAVs (left = local, right = remote), streaming in
    /// 2²⁰-frame chunks. A whole-file buffer is never allocated: a ~3 h stereo recording would
    /// overflow the UInt32 byte size and CoreAudio would abort the process.
    static func splitStereo(_ url: URL, left: URL, right: URL) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.channelCount == 2 else {
            throw NSError(domain: "WAVInfo", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected 2 channels, got \(format.channelCount)"])
        }
        let rate = Int(format.sampleRate)
        let leftWriter = try MonoWAVWriter(url: left, sampleRate: rate)
        let rightWriter = try MonoWAVWriter(url: right, sampleRate: rate)
        let chunkFrames: AVAudioFrameCount = 1 << 20
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw NSError(domain: "WAVInfo", code: 2, userInfo: [NSLocalizedDescriptionKey: "Buffer allocation failed"])
        }
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunkFrames)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            let n = Int(buffer.frameLength)
            leftWriter.write(UnsafeBufferPointer(start: data[0], count: n))
            rightWriter.write(UnsafeBufferPointer(start: data[1], count: n))
        }
        try leftWriter.finish()
        try rightWriter.finish()
    }
}
