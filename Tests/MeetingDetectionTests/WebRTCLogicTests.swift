import XCTest
@testable import MeetingDetection

final class WebRTCLogicTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)

    func testRateAveragesOverWindow() {
        var w = PacketRateWindow(windowSeconds: 8)
        w.add(count: 0, at: t0)
        w.add(count: 100, at: t0.addingTimeInterval(2))
        XCTAssertEqual(w.rate, 50, accuracy: 0.01)
        // A 2s gap with no packets only halves the average, it doesn't zero it.
        w.add(count: 100, at: t0.addingTimeInterval(4))
        XCTAssertEqual(w.rate, 25, accuracy: 0.01)
    }

    func testCounterResetClearsHistory() {
        var w = PacketRateWindow()
        w.add(count: 1000, at: t0)
        w.add(count: 10, at: t0.addingTimeInterval(1))
        XCTAssertEqual(w.rate, 0)
    }

    func testFlapGuardBlocksProbableReactivation() {
        var g = WebRTCFlapGuard()
        XCTAssertTrue(g.evaluate(confirmed: false, probable: true, rate: 30, highThreshold: 50, now: t0))
        XCTAssertFalse(g.evaluate(confirmed: false, probable: false, rate: 5, highThreshold: 50, now: t0.addingTimeInterval(2)))
        // Residual tab traffic within the guard window: blocked.
        XCTAssertFalse(g.evaluate(confirmed: false, probable: true, rate: 30, highThreshold: 50, now: t0.addingTimeInterval(4)))
        // Confirmed ports are never gated.
        XCTAssertTrue(g.evaluate(confirmed: true, probable: false, rate: 30, highThreshold: 50, now: t0.addingTimeInterval(6)))
    }

    func testFlapGuardAllowsSustainedHighRate() {
        var g = WebRTCFlapGuard()
        _ = g.evaluate(confirmed: false, probable: true, rate: 30, highThreshold: 50, now: t0)
        _ = g.evaluate(confirmed: false, probable: false, rate: 0, highThreshold: 50, now: t0.addingTimeInterval(2))
        XCTAssertFalse(g.evaluate(confirmed: false, probable: true, rate: 60, highThreshold: 50, now: t0.addingTimeInterval(4)))
        XCTAssertFalse(g.evaluate(confirmed: false, probable: true, rate: 60, highThreshold: 50, now: t0.addingTimeInterval(10)))
        XCTAssertTrue(g.evaluate(confirmed: false, probable: true, rate: 60, highThreshold: 50, now: t0.addingTimeInterval(14)))
    }

    func testFlapGuardExpires() {
        var g = WebRTCFlapGuard()
        _ = g.evaluate(confirmed: false, probable: true, rate: 30, highThreshold: 50, now: t0)
        _ = g.evaluate(confirmed: false, probable: false, rate: 0, highThreshold: 50, now: t0.addingTimeInterval(2))
        XCTAssertTrue(g.evaluate(confirmed: false, probable: true, rate: 30, highThreshold: 50, now: t0.addingTimeInterval(93)))
    }

    func testServicePorts() {
        XCTAssertEqual(WebRTCDetector.serviceName(forRemotePort: 19305), "Google Meet")
        XCTAssertEqual(WebRTCDetector.serviceName(forRemotePort: 8805), "Zoom")
        XCTAssertEqual(WebRTCDetector.serviceName(forRemotePort: 22466), "Slack Huddles")
        XCTAssertEqual(WebRTCDetector.serviceName(forRemotePort: 3478), "Generic WebRTC")
        XCTAssertNil(WebRTCDetector.serviceName(forRemotePort: 443))
    }

    func testLsofParsing() {
        let out = "p123\ncGoogle Chrome He\nn192.168.1.2:55000->142.250.82.127:19305\nn*:5353\np456\ncSlack\nn10.0.0.2:6000->1.2.3.4:22466\n"
        let conns = WebRTCDetector.parseLsofFieldOutput(out)
        XCTAssertEqual(conns.count, 2)
        XCTAssertEqual(conns[0].remotePort, 19305)
        XCTAssertEqual(conns[0].remoteHost, "142.250.82.127")
        XCTAssertEqual(conns[1].process, "Slack")
    }

    func testNetstatParsing() {
        let out = "udp:\n\t1000 datagrams received\n\t0 with incomplete header\n\t500 datagrams output\n"
        XCTAssertEqual(WebRTCDetector.parseNetstatUDP(out), 1500)
    }

    func testMeetWindowTitleAcceptsEnDash() {
        let d = WindowDetector()
        let w = [WindowDetector.WindowInfo(owner: "Google Chrome", title: "Meet \u{2013} abc-defg-hij")]
        XCTAssertEqual(d.matches(in: w), ["Google Meet"])
        let w2 = [WindowDetector.WindowInfo(owner: "Google Chrome", title: "Meet - abc-defg-hij")]
        XCTAssertEqual(d.matches(in: w2), ["Google Meet"])
    }
}
