import XCTest
@testable import MeetingDetection

final class EndDetectionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func config() -> DetectionConfig {
        DetectionConfig(endDetectionQuietPeriod: 10, endPromptTimeout: 20, signalPollInterval: 2)
    }

    /// A clearly active meeting: WebRTC + window + voice.
    private func activeSnapshot(camera: SignalState = .inactive) -> DetectionSnapshot {
        DetectionSnapshot(camera: camera, webrtc: .active, window: .active, vad: .active)
    }

    private func quietSnapshot(camera: SignalState = .inactive) -> DetectionSnapshot {
        DetectionSnapshot(camera: camera, webrtc: .inactive, window: .inactive, vad: .inactive)
    }

    private func startedMachine() -> MeetingStateMachine {
        let m = MeetingStateMachine(config: config())
        XCTAssertEqual(m.process(activeSnapshot(), now: t0), [.meetingStarted])
        XCTAssertEqual(m.state, .meetingActive)
        return m
    }

    // MARK: - Aggregator

    func testStartRules() {
        let a = SignalAggregator()
        XCTAssertTrue(a.isMeetingActive(DetectionSnapshot(camera: .active, webrtc: .active)))
        XCTAssertTrue(a.isMeetingActive(DetectionSnapshot(camera: .active, window: .active)))
        XCTAssertTrue(a.isMeetingActive(DetectionSnapshot(webrtc: .active, window: .active, vad: .active)))
        XCTAssertTrue(a.isMeetingActive(DetectionSnapshot(vad: .active, calendarEvent: true)))
        XCTAssertFalse(a.isMeetingActive(DetectionSnapshot(webrtc: .active, window: .active)))
        XCTAssertFalse(a.isMeetingActive(DetectionSnapshot(camera: .active)))
        XCTAssertFalse(a.isMeetingActive(DetectionSnapshot(window: .active, calendarEvent: true)))
    }

    func testUnknownCountsAsQuiet() {
        let a = SignalAggregator()
        XCTAssertTrue(a.allEndSignalsQuiet(DetectionSnapshot()))
    }

    // MARK: - Camera veto

    func testCameraOnVetoesEndDetection() {
        let m = startedMachine()
        for i in 1...20 {
            let events = m.process(quietSnapshot(camera: .active), now: t0.addingTimeInterval(Double(i) * 2))
            XCTAssertTrue(events.isEmpty)
        }
        XCTAssertEqual(m.state, .meetingActive)
    }

    func testCameraOffSaysNothing() {
        let m = startedMachine()
        XCTAssertEqual(m.process(quietSnapshot(camera: .inactive), now: t0.addingTimeInterval(2)), [.quietPeriodStarted])
    }

    // MARK: - Quiet period

    func testQuietPeriodEntryAndPrompt() {
        let m = startedMachine()
        XCTAssertEqual(m.process(quietSnapshot(), now: t0.addingTimeInterval(2)), [.quietPeriodStarted])
        XCTAssertEqual(m.state, .quietPeriod)
        XCTAssertEqual(m.process(quietSnapshot(), now: t0.addingTimeInterval(8)), [])
        XCTAssertEqual(m.process(quietSnapshot(), now: t0.addingTimeInterval(12)), [.promptUser])
        XCTAssertEqual(m.state, .promptingUser)
    }

    func testSingleBlipDoesNotAbortOrResetCountdown() {
        let m = startedMachine()
        m.process(quietSnapshot(), now: t0.addingTimeInterval(2))
        // One not-quiet blip.
        XCTAssertEqual(m.process(activeSnapshot(), now: t0.addingTimeInterval(4)), [])
        XCTAssertEqual(m.state, .quietPeriod)
        m.process(quietSnapshot(), now: t0.addingTimeInterval(6))
        // Countdown kept running from t0+2: prompt fires at t0+12, not t0+16.
        XCTAssertEqual(m.process(quietSnapshot(), now: t0.addingTimeInterval(12)), [.promptUser])
    }

    func testBlipAtDeadlineStillPrompts() {
        let m = startedMachine()
        m.process(quietSnapshot(), now: t0.addingTimeInterval(2))
        XCTAssertEqual(m.process(activeSnapshot(), now: t0.addingTimeInterval(12)), [.promptUser])
    }

    func testSustainedActivityAbortsQuietPeriod() {
        let m = startedMachine()
        m.process(quietSnapshot(), now: t0.addingTimeInterval(2))
        XCTAssertEqual(m.process(activeSnapshot(), now: t0.addingTimeInterval(4)), [])
        XCTAssertEqual(m.process(activeSnapshot(), now: t0.addingTimeInterval(6)), [.quietPeriodAborted])
        XCTAssertEqual(m.state, .meetingActive)
        // A fresh quiet period starts from scratch.
        XCTAssertEqual(m.process(quietSnapshot(), now: t0.addingTimeInterval(8)), [.quietPeriodStarted])
        XCTAssertEqual(m.process(quietSnapshot(), now: t0.addingTimeInterval(14)), [])
        XCTAssertEqual(m.process(quietSnapshot(), now: t0.addingTimeInterval(18)), [.promptUser])
    }

    // MARK: - Keep recording

    private func promptingMachine() -> MeetingStateMachine {
        let m = startedMachine()
        m.process(quietSnapshot(), now: t0.addingTimeInterval(2))
        m.process(quietSnapshot(), now: t0.addingTimeInterval(12))
        XCTAssertEqual(m.state, .promptingUser)
        return m
    }

    func testKeepRecordingDisarmsReprompt() {
        let m = promptingMachine()
        m.keepRecording()
        XCTAssertEqual(m.state, .meetingActive)
        // Same quiet signals re-observed for a long time: no re-prompt.
        for i in 0..<60 {
            XCTAssertTrue(m.process(quietSnapshot(), now: t0.addingTimeInterval(14 + Double(i) * 2)).isEmpty)
        }
        XCTAssertEqual(m.state, .meetingActive)
    }

    func testKeepRecordingRearmsAfterFreshActivity() {
        let m = promptingMachine()
        m.keepRecording()
        m.process(quietSnapshot(), now: t0.addingTimeInterval(14))
        // Fresh evidence of activity re-arms detection…
        XCTAssertTrue(m.process(DetectionSnapshot(webrtc: .active), now: t0.addingTimeInterval(16)).isEmpty)
        XCTAssertTrue(m.quietDetectionArmed)
        // …so the next quiet run can prompt again.
        XCTAssertEqual(m.process(quietSnapshot(), now: t0.addingTimeInterval(18)), [.quietPeriodStarted])
        XCTAssertEqual(m.process(quietSnapshot(), now: t0.addingTimeInterval(28)), [.promptUser])
    }

    // MARK: - End from prompt

    func testPromptTimeoutEndsMeeting() {
        let m = promptingMachine()
        XCTAssertEqual(m.tick(now: t0.addingTimeInterval(20)), [])
        XCTAssertEqual(m.tick(now: t0.addingTimeInterval(32)), [.meetingEnded])
        XCTAssertEqual(m.state, .ending)
    }

    func testPromptTimeoutViaPoll() {
        let m = promptingMachine()
        XCTAssertEqual(m.process(quietSnapshot(), now: t0.addingTimeInterval(32)), [.meetingEnded])
    }

    func testUserEndsMeetingFromPrompt() {
        let m = promptingMachine()
        XCTAssertEqual(m.endMeeting(), [.meetingEnded])
        XCTAssertEqual(m.state, .ending)
        m.resetToIdle()
        XCTAssertEqual(m.state, .idle)
    }

    func testPromptRemaining() {
        let m = promptingMachine()
        XCTAssertEqual(m.promptRemaining(now: t0.addingTimeInterval(17)) ?? -1, 15, accuracy: 0.001)
    }

    // MARK: - Cancel suppression

    func testCancelSuppressesStartUntilSignalsClear() {
        let m = startedMachine()
        m.resetToIdle(suppressStartUntilClear: true)
        XCTAssertTrue(m.process(activeSnapshot(), now: t0.addingTimeInterval(2)).isEmpty)
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(m.process(quietSnapshot(), now: t0.addingTimeInterval(4)).isEmpty)
        XCTAssertEqual(m.process(activeSnapshot(), now: t0.addingTimeInterval(6)), [.meetingStarted])
    }
}
