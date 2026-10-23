import Foundation

/// Events emitted by the state machine as it transitions.
public enum MeetingStateEvent: Equatable, Sendable {
    case meetingStarted
    case quietPeriodStarted
    case quietPeriodAborted
    case promptUser
    case meetingEnded
}

/// Meeting lifecycle state machine. Pure logic: the caller feeds it one snapshot per
/// poll along with the current time, and acts on the returned events.
public final class MeetingStateMachine: @unchecked Sendable {
    public private(set) var state: MeetingState = .idle
    public var config: DetectionConfig

    private let aggregator = SignalAggregator()
    private let lock = NSLock()

    /// When the current quiet period began (countdown keeps running through single blips).
    public private(set) var quietStartedAt: Date?
    /// When the prompt was shown.
    public private(set) var promptStartedAt: Date?
    /// Consecutive not-quiet snapshots observed while in `quietPeriod`.
    public private(set) var consecutiveNotQuiet = 0
    /// After "keep recording", quiet detection stays disarmed until an end signal goes active.
    public private(set) var quietDetectionArmed = true
    /// After a cancelled recording, start detection is held until the meeting signals clear.
    public private(set) var startSuppressed = false

    /// Number of consecutive not-quiet polls required to leave the quiet period.
    public static let abortDebounceCount = 2

    public init(config: DetectionConfig = .default) {
        self.config = config
    }

    /// Advance the machine with one snapshot. Returns the events produced by this step.
    @discardableResult
    public func process(_ snapshot: DetectionSnapshot, now: Date = Date()) -> [MeetingStateEvent] {
        lock.lock()
        defer { lock.unlock() }

        let meetingActive = aggregator.isMeetingActive(snapshot)
        let quiet = aggregator.allEndSignalsQuiet(snapshot)
        var events: [MeetingStateEvent] = []

        switch state {
        case .idle:
            if startSuppressed {
                if !meetingActive { startSuppressed = false }
                return []
            }
            if meetingActive {
                state = .meetingActive
                quietDetectionArmed = true
                events.append(.meetingStarted)
            }

        case .meetingActive:
            if !quietDetectionArmed {
                if !quiet { quietDetectionArmed = true }
                return []
            }
            if quiet {
                state = .quietPeriod
                quietStartedAt = now
                consecutiveNotQuiet = 0
                events.append(.quietPeriodStarted)
                // A zero-length quiet period can prompt immediately.
                events.append(contentsOf: checkQuietTimeout(now: now))
            }

        case .quietPeriod:
            if quiet {
                consecutiveNotQuiet = 0
            } else {
                consecutiveNotQuiet += 1
                if consecutiveNotQuiet >= Self.abortDebounceCount {
                    state = .meetingActive
                    quietStartedAt = nil
                    consecutiveNotQuiet = 0
                    events.append(.quietPeriodAborted)
                    return events
                }
            }
            events.append(contentsOf: checkQuietTimeout(now: now))

        case .promptingUser:
            if let started = promptStartedAt, now.timeIntervalSince(started) >= config.endPromptTimeout {
                state = .ending
                events.append(.meetingEnded)
            }

        case .ending:
            break
        }
        return events
    }

    private func checkQuietTimeout(now: Date) -> [MeetingStateEvent] {
        guard let started = quietStartedAt else { return [] }
        if now.timeIntervalSince(started) >= config.endDetectionQuietPeriod {
            state = .promptingUser
            promptStartedAt = now
            return [.promptUser]
        }
        return []
    }

    /// Check only the prompt timeout (the prompt counts down independently of polls).
    @discardableResult
    public func tick(now: Date = Date()) -> [MeetingStateEvent] {
        lock.lock()
        defer { lock.unlock() }
        if state == .promptingUser, let started = promptStartedAt,
           now.timeIntervalSince(started) >= config.endPromptTimeout {
            state = .ending
            return [.meetingEnded]
        }
        return []
    }

    /// Seconds left before the prompt auto-ends the meeting.
    public func promptRemaining(now: Date = Date()) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard state == .promptingUser, let started = promptStartedAt else { return nil }
        return max(0, config.endPromptTimeout - now.timeIntervalSince(started))
    }

    /// User answered "keep recording": back to active, quiet detection disarmed until some
    /// end signal goes active again.
    public func keepRecording() {
        lock.lock()
        defer { lock.unlock() }
        guard state == .promptingUser || state == .quietPeriod else { return }
        state = .meetingActive
        quietStartedAt = nil
        promptStartedAt = nil
        consecutiveNotQuiet = 0
        quietDetectionArmed = false
    }

    /// User answered "end meeting".
    @discardableResult
    public func endMeeting() -> [MeetingStateEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard state != .idle && state != .ending else { return [] }
        state = .ending
        return [.meetingEnded]
    }

    /// Force the machine into `meetingActive` (manual start while idle).
    public func markMeetingActive() {
        lock.lock()
        defer { lock.unlock() }
        state = .meetingActive
        quietStartedAt = nil
        promptStartedAt = nil
        consecutiveNotQuiet = 0
        quietDetectionArmed = true
        startSuppressed = false
    }

    /// Manual stop / processing finished.
    public func resetToIdle(suppressStartUntilClear: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        state = .idle
        quietStartedAt = nil
        promptStartedAt = nil
        consecutiveNotQuiet = 0
        quietDetectionArmed = true
        startSuppressed = suppressStartUntilClear
    }
}
