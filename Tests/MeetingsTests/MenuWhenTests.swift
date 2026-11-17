import XCTest
@testable import Meetings

final class MenuWhenTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Toronto")!
        return c
    }

    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: s)!
    }

    private func meeting(_ start: String, minutes: Double = 90) -> Meeting {
        let s = date(start)
        return Meeting(id: start, title: "Pairing", start: s, end: s.addingTimeInterval(minutes * 60),
                       attendees: [], meetingURL: nil, type: .unknown, fromCalendar: true)
    }

    func testSameTimeTodayAndTomorrowAreToldApart() {
        let now = date("2026-11-17T19:05:00Z") // 2:05 PM Toronto
        let today = meeting("2026-11-17T19:00:00Z")
        let tomorrow = meeting("2026-11-18T19:00:00Z")
        XCTAssertEqual(today.menuWhen(now: now, calendar: calendar, locale: locale), "Now")
        XCTAssertEqual(tomorrow.menuWhen(now: now, calendar: calendar, locale: locale), "Tomorrow 2:00\u{202F}PM")
    }

    func testLaterTodayShowsOnlyTheTime() {
        let now = date("2026-11-17T15:00:00Z")
        XCTAssertEqual(meeting("2026-11-17T19:00:00Z").menuWhen(now: now, calendar: calendar, locale: locale), "2:00\u{202F}PM")
    }

    func testFurtherOutShowsTheWeekday() {
        let now = date("2026-11-20T20:00:00Z") // Friday
        XCTAssertEqual(meeting("2026-11-23T19:00:00Z").menuWhen(now: now, calendar: calendar, locale: locale), "Mon 2:00\u{202F}PM")
    }
}
