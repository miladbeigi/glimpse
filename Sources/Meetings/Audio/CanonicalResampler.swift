import AVFoundation

/// Canonical capture rate: every buffer from either source is resampled to 48 kHz mono so
/// the WAV header is always truthful even if the device changes rate mid-recording.
enum CanonicalAudio {
    static let sampleRate: Double = 48_000
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
}

/// A block of canonical (48 kHz mono) samples stamped with the host-clock time of its first
/// sample, in seconds.
struct TimedAudioChunk: Sendable {
    let hostTime: TimeInterval
    let samples: [Float]
}

/// `AVAudioConverter` wrapper that is recreated whenever the input format changes.
final class CanonicalResampler {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    /// Convert a mono Float32 buffer at any rate to 48 kHz mono samples.
    func resample(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let format = buffer.format
        if format.sampleRate == CanonicalAudio.sampleRate && format.channelCount == 1 && format.commonFormat == .pcmFormatFloat32,
           let data = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }

        if inputFormat != format {
            converter = AVAudioConverter(from: format, to: CanonicalAudio.format)
            inputFormat = format
            log("🔄 Resampler recreated for \(Int(format.sampleRate)) Hz × \(format.channelCount)ch")
        }
        guard let converter else { return [] }

        let ratio = CanonicalAudio.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: CanonicalAudio.format, frameCapacity: capacity) else { return [] }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}

/// Average the channels of a non-interleaved float buffer into a new mono buffer.
func downmixToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let channels = Int(buffer.format.channelCount)
    guard channels > 1 else { return buffer }
    guard buffer.format.commonFormat == .pcmFormatFloat32, !buffer.format.isInterleaved,
          let src = buffer.floatChannelData,
          let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
          let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
          let dst = out.floatChannelData else { return nil }
    let frames = Int(buffer.frameLength)
    let scale = 1 / Float(channels)
    for i in 0..<frames {
        var sum: Float = 0
        for c in 0..<channels { sum += src[c][i] }
        dst[0][i] = sum * scale
    }
    out.frameLength = buffer.frameLength
    return out
}

/// RMS of a sample block, normalized to roughly 0…1 for UI metering.
func rmsLevel(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Float = 0
    for s in samples { sum += s * s }
    let rms = (sum / Float(samples.count)).squareRoot()
    // Map -60 dB…0 dB onto 0…1.
    let db = 20 * log10(max(rms, 1e-6))
    return max(0, min(1, (db + 60) / 60))
}
