import CoreMedia
import Foundation

/// Maps capture timestamps (host clock) to recording time, cutting out paused stretches.
///
/// Every sample, video or audio, goes through `map`: samples captured while paused are dropped and later ones
/// are shifted back by the total paused time before them, so pausing never leaves a gap and the audio and
/// video tracks stay in step.
struct RecordingTimeline {
    private(set) var pauses: [(start: CMTime, end: CMTime)] = []
    private(set) var pausedAt: CMTime?

    var isPaused: Bool { pausedAt != nil }

    mutating func pause(at time: CMTime) {
        guard pausedAt == nil else { return }
        pausedAt = time
    }

    mutating func resume(at time: CMTime) {
        guard let start = pausedAt else { return }
        pausedAt = nil
        if time > start { pauses.append((start, time)) }
    }

    /// Total paused time before `time`.
    func pausedDuration(before time: CMTime) -> CMTime {
        var total = CMTime.zero
        for p in pauses where p.end <= time { total = total + (p.end - p.start) }
        return total
    }

    /// The recording-time equivalent of `time`, or nil if it was captured while paused.
    func map(_ time: CMTime) -> CMTime? {
        if let pausedAt, time >= pausedAt { return nil }
        for p in pauses where time >= p.start && time < p.end { return nil }
        return time - pausedDuration(before: time)
    }
}

/// Pixel sizes for recordings.
enum RecordingGeometry {
    /// H.264's hardware encoders top out at 4096 × 2304.
    static let maxWidth = 4096
    static let maxHeight = 2304

    /// Output size for a region of `points` at `scale`, shrunk to fit the encoder and rounded to even numbers.
    static func outputSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        var w = max(2, points.width * scale)
        var h = max(2, points.height * scale)
        let fit = min(1, CGFloat(maxWidth) / w, CGFloat(maxHeight) / h)
        w *= fit
        h *= fit
        func even(_ v: CGFloat) -> Int { max(2, Int(v.rounded(.down)) & ~1) }
        return (even(w), even(h))
    }

    /// Average bit rate for screen content: sharp text needs more than camera footage of the same size.
    static func bitRate(width: Int, height: Int, fps: Int) -> Int {
        let bitsPerPixel = fps > 30 ? 0.06 : 0.09
        let rate = Double(width * height * fps) * bitsPerPixel
        return Int(min(max(rate, 2_000_000), 60_000_000))
    }

    /// "1:05", or "1:02:03" past an hour.
    static func formatDuration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
