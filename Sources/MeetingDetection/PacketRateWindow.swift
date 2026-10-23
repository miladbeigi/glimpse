import Foundation

/// Averages a monotonically increasing packet counter over a sliding time window so that
/// gaps between packets don't flap the WebRTC signal.
public struct PacketRateWindow: Sendable {
    public let windowSeconds: TimeInterval
    private var samples: [(time: Date, count: UInt64)] = []

    public init(windowSeconds: TimeInterval = 8) {
        self.windowSeconds = windowSeconds
    }

    /// Record a counter sample and return the average rate (packets/sec) across the window.
    @discardableResult
    public mutating func add(count: UInt64, at time: Date) -> Double {
        // A counter reset (e.g. interface restart) invalidates history.
        if let last = samples.last, count < last.count {
            samples.removeAll()
        }
        samples.append((time, count))
        let cutoff = time.addingTimeInterval(-windowSeconds)
        // Keep one sample at or before the cutoff so the window spans its full width.
        while samples.count > 2, samples[1].time <= cutoff {
            samples.removeFirst()
        }
        return rate
    }

    public var rate: Double {
        guard let first = samples.first, let last = samples.last, samples.count >= 2 else { return 0 }
        let dt = last.time.timeIntervalSince(first.time)
        guard dt > 0 else { return 0 }
        return Double(last.count - first.count) / dt
    }

    public mutating func reset() { samples.removeAll() }
}

/// Reactivation flap guard: for `guardDuration` after the WebRTC signal goes inactive,
/// probable-only evidence may reactivate it only if the packet rate has stayed above the high
/// threshold for `sustainDuration` continuously. Confirmed port matches are never gated.
public struct WebRTCFlapGuard: Sendable {
    public var guardDuration: TimeInterval = 90
    public var sustainDuration: TimeInterval = 10

    private var lastActive = false
    private var wentInactiveAt: Date?
    private var highRateSince: Date?

    public init(guardDuration: TimeInterval = 90, sustainDuration: TimeInterval = 10) {
        self.guardDuration = guardDuration
        self.sustainDuration = sustainDuration
    }

    /// Decide the final WebRTC state.
    /// - Parameters:
    ///   - confirmed: a known STUN/TURN port matched
    ///   - probable: probable-only evidence (browser UDP:443 to Google + rate above low)
    ///   - rate: averaged packet rate
    ///   - highThreshold: sustained rate needed to reactivate on probable-only evidence
    public mutating func evaluate(
        confirmed: Bool, probable: Bool, rate: Double, highThreshold: Double, now: Date
    ) -> Bool {
        if rate >= highThreshold {
            if highRateSince == nil { highRateSince = now }
        } else {
            highRateSince = nil
        }

        var active: Bool
        if confirmed {
            active = true
        } else if probable {
            if let inactiveAt = wentInactiveAt, now.timeIntervalSince(inactiveAt) < guardDuration {
                let sustained = highRateSince.map { now.timeIntervalSince($0) >= sustainDuration } ?? false
                active = sustained
            } else {
                active = true
            }
        } else {
            active = false
        }

        if lastActive && !active {
            wentInactiveAt = now
        } else if active {
            wentInactiveAt = nil
        }
        lastActive = active
        return active
    }
}
