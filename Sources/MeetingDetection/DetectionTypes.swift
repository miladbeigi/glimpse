import Foundation

/// Tri-state reading of a single detection signal.
public enum SignalState: String, Sendable, Codable, CustomStringConvertible {
    case active
    case inactive
    case unknown

    public var isActive: Bool { self == .active }

    /// Inactive or unknown both count as "quiet" for end detection.
    public var isQuiet: Bool { self != .active }

    public var description: String { rawValue }
}

/// Identifies one of the signal detectors.
public enum SignalKind: String, Sendable, CaseIterable, Codable {
    case camera
    case webrtc
    case window
    case vad
    case calendar
}

/// One poll cycle's worth of signal readings. The detection service takes exactly one
/// snapshot per cycle and reuses it for the VAD decision and the state machine.
public struct DetectionSnapshot: Sendable, Codable, Equatable {
    public var timestamp: Date
    public var camera: SignalState
    public var webrtc: SignalState
    public var window: SignalState
    public var vad: SignalState
    public var calendarEvent: Bool

    /// Averaged UDP packet rate (packets/sec) that fed the WebRTC decision.
    public var webrtcPacketRate: Double
    /// Service names reported by the WebRTC detector (e.g. "Google Meet").
    public var webrtcServices: [String]
    /// Meeting app/service names matched by the window detector.
    public var windowMatches: [String]

    public init(
        timestamp: Date = Date(),
        camera: SignalState = .unknown,
        webrtc: SignalState = .unknown,
        window: SignalState = .unknown,
        vad: SignalState = .unknown,
        calendarEvent: Bool = false,
        webrtcPacketRate: Double = 0,
        webrtcServices: [String] = [],
        windowMatches: [String] = []
    ) {
        self.timestamp = timestamp
        self.camera = camera
        self.webrtc = webrtc
        self.window = window
        self.vad = vad
        self.calendarEvent = calendarEvent
        self.webrtcPacketRate = webrtcPacketRate
        self.webrtcServices = webrtcServices
        self.windowMatches = windowMatches
    }

    /// Human readable list of the active signals, used by the ad-hoc Meeting Detected card.
    public var activeSignalsDescription: String {
        var parts: [String] = []
        if camera.isActive { parts.append("Camera") }
        if webrtc.isActive {
            parts.append(webrtcServices.first.map { "WebRTC (\($0))" } ?? "WebRTC")
        }
        if window.isActive {
            parts.append(windowMatches.first.map { "Window (\($0))" } ?? "Window")
        }
        if vad.isActive { parts.append("Voice") }
        if calendarEvent { parts.append("Calendar") }
        return parts.isEmpty ? "No signals" : parts.joined(separator: " · ")
    }

    /// Best guess at the service in use (for titling ad-hoc meetings).
    public var detectedServiceName: String? {
        webrtcServices.first ?? windowMatches.first
    }

    public var logDescription: String {
        String(
            format: "camera=%@ webrtc=%@ (%.1f pps) window=%@ vad=%@ calendar=%@",
            camera.rawValue, webrtc.rawValue, webrtcPacketRate, window.rawValue, vad.rawValue,
            calendarEvent ? "yes" : "no")
    }
}

/// Detection tuning. These are the *library* defaults, used by the CLI; the app overrides
/// them from its own settings.
public struct DetectionConfig: Sendable, Codable, Equatable {
    public var endDetectionQuietPeriod: TimeInterval
    public var endPromptTimeout: TimeInterval
    public var signalPollInterval: TimeInterval
    public var vadSensitivity: Double
    public var webrtcPacketRateThreshold: Double
    public var webrtcHighPacketRateThreshold: Double

    public static let quietPeriodRange: ClosedRange<TimeInterval> = 5...300
    public static let promptTimeoutRange: ClosedRange<TimeInterval> = 5...300
    public static let pollIntervalRange: ClosedRange<TimeInterval> = 1...30

    public init(
        endDetectionQuietPeriod: TimeInterval = 60,
        endPromptTimeout: TimeInterval = 120,
        signalPollInterval: TimeInterval = 5,
        vadSensitivity: Double = 0.5,
        webrtcPacketRateThreshold: Double = 20,
        webrtcHighPacketRateThreshold: Double = 50
    ) {
        self.endDetectionQuietPeriod = endDetectionQuietPeriod
        self.endPromptTimeout = endPromptTimeout
        self.signalPollInterval = signalPollInterval
        self.vadSensitivity = vadSensitivity
        self.webrtcPacketRateThreshold = webrtcPacketRateThreshold
        self.webrtcHighPacketRateThreshold = webrtcHighPacketRateThreshold
    }

    public static let `default` = DetectionConfig()

    /// Clamp every value into its documented range.
    public func validated() -> DetectionConfig {
        var c = self
        c.endDetectionQuietPeriod = min(max(c.endDetectionQuietPeriod, Self.quietPeriodRange.lowerBound), Self.quietPeriodRange.upperBound)
        c.endPromptTimeout = min(max(c.endPromptTimeout, Self.promptTimeoutRange.lowerBound), Self.promptTimeoutRange.upperBound)
        c.signalPollInterval = min(max(c.signalPollInterval, Self.pollIntervalRange.lowerBound), Self.pollIntervalRange.upperBound)
        c.vadSensitivity = min(max(c.vadSensitivity, 0), 1)
        c.webrtcPacketRateThreshold = max(c.webrtcPacketRateThreshold, 1)
        if c.webrtcHighPacketRateThreshold <= c.webrtcPacketRateThreshold {
            c.webrtcHighPacketRateThreshold = c.webrtcPacketRateThreshold + 1
        }
        return c
    }
}

/// Meeting lifecycle states.
public enum MeetingState: String, Sendable, Codable {
    case idle
    case meetingActive
    case quietPeriod
    case promptingUser
    case ending
}
