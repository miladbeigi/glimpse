import Foundation

/// Owns the signal detectors and produces one `DetectionSnapshot` per poll cycle. Handles
/// the lazy VAD lifecycle: the microphone is opened only when WebRTC + Window are both active
/// and released after `vadReleaseDelay` seconds of those signals being quiet while idle.
public final class SignalCollector: @unchecked Sendable {
    public struct EnabledSignals: Sendable {
        public var camera = true
        public var webrtc = true
        public var window = true
        public var vad = true
        public init(camera: Bool = true, webrtc: Bool = true, window: Bool = true, vad: Bool = true) {
            self.camera = camera
            self.webrtc = webrtc
            self.window = window
            self.vad = vad
        }
    }

    public let camera = CameraDetector()
    public let webrtc: WebRTCDetector
    public let window = WindowDetector()
    public let vad: VADDetector
    public var enabled: EnabledSignals
    public var vadReleaseDelay: TimeInterval = 30

    private let aggregator = SignalAggregator()
    private var vadQuietSince: Date?
    private var vadStarting = false

    /// Optional log sink.
    public var log: (@Sendable (String) -> Void)?

    public init(config: DetectionConfig, enabled: EnabledSignals = EnabledSignals()) {
        self.webrtc = WebRTCDetector(lowThreshold: config.webrtcPacketRateThreshold, highThreshold: config.webrtcHighPacketRateThreshold)
        self.vad = VADDetector(sensitivity: config.vadSensitivity)
        self.enabled = enabled
    }

    public func apply(config: DetectionConfig) {
        webrtc.lowThreshold = config.webrtcPacketRateThreshold
        webrtc.highThreshold = config.webrtcHighPacketRateThreshold
        vad.sensitivity = config.vadSensitivity
    }

    /// Take exactly one snapshot. `calendarEvent` is provided by the caller.
    /// - Parameter keepVADAlive: true while a meeting is in progress (VAD is not released).
    public func snapshot(calendarEvent: Bool = false, keepVADAlive: Bool = false, now: Date = Date()) -> DetectionSnapshot {
        var s = DetectionSnapshot(timestamp: now, calendarEvent: calendarEvent)
        if enabled.camera { s.camera = camera.check() }
        if enabled.webrtc {
            let r = webrtc.check(now: now)
            s.webrtc = r.state
            s.webrtcPacketRate = r.packetRate
            s.webrtcServices = r.services
        }
        if enabled.window {
            let r = window.check()
            s.window = r.state
            s.windowMatches = r.matches
        }
        if enabled.vad {
            manageVAD(for: s, keepAlive: keepVADAlive, now: now)
            s.vad = vad.check()
        }
        return s
    }

    private func manageVAD(for s: DetectionSnapshot, keepAlive: Bool, now: Date) {
        // While fed by the recording microphone the lifecycle belongs to the caller.
        if vad.isExternallyFed { return }
        if aggregator.wantsVAD(s) {
            vadQuietSince = nil
            if !vad.isRunning && !vadStarting {
                vadStarting = true
                log?("🔍 Starting VAD (WebRTC + Window active)")
                Task { [weak self] in
                    guard let self else { return }
                    do { try await self.vad.start() } catch { self.log?("❌ VAD start failed: \(error.localizedDescription)") }
                    self.vadStarting = false
                }
            }
        } else if vad.isRunning && !keepAlive {
            if vadQuietSince == nil { vadQuietSince = now }
            if let since = vadQuietSince, now.timeIntervalSince(since) >= vadReleaseDelay {
                log?("🔍 Releasing microphone (VAD idle for \(Int(vadReleaseDelay))s)")
                vad.stop()
                vadQuietSince = nil
            }
        } else {
            vadQuietSince = nil
        }
    }

    /// Feed VAD from an existing capture (the recording mic) instead of its own engine.
    public func useExternalVADFeed(_ enabled: Bool) {
        if enabled {
            Task { [weak self] in
                do { try await self?.vad.startExternalFeed() } catch { self?.log?("❌ VAD external feed failed: \(error.localizedDescription)") }
            }
        } else {
            vad.stopExternalFeed()
        }
    }

    public func shutdown() {
        vad.stop()
    }
}
