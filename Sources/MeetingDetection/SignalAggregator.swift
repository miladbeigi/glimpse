import Foundation

/// Combines per-signal readings into "meeting active" / "all quiet" decisions.
public struct SignalAggregator: Sendable {
    public init() {}

    /// A meeting is active when ANY of the start rules match.
    public func isMeetingActive(_ s: DetectionSnapshot) -> Bool {
        if s.camera.isActive && s.webrtc.isActive { return true }
        if s.camera.isActive && s.window.isActive { return true }
        if s.webrtc.isActive && s.window.isActive && s.vad.isActive { return true }
        if s.calendarEvent && (s.camera.isActive || s.webrtc.isActive || s.vad.isActive) { return true }
        return false
    }

    /// The meeting is quiet when ALL end signals are inactive/unknown. An in-use camera
    /// vetoes end detection; camera off says nothing on its own.
    public func allEndSignalsQuiet(_ s: DetectionSnapshot) -> Bool {
        s.camera.isQuiet && s.webrtc.isQuiet && s.window.isQuiet && s.vad.isQuiet
    }

    /// True when any end signal is active (used to re-arm quiet detection after
    /// "keep recording").
    public func anyEndSignalActive(_ s: DetectionSnapshot) -> Bool {
        !allEndSignalsQuiet(s)
    }

    /// Whether the VAD detector should be running for this snapshot (lazy activation).
    public func wantsVAD(_ s: DetectionSnapshot) -> Bool {
        s.webrtc.isActive && s.window.isActive
    }
}
