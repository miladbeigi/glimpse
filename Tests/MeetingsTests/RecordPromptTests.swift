import XCTest
@testable import Meetings

@MainActor
final class RecordPromptTests: XCTestCase {
    func testOfferedOncePerMeeting() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RecordPromptTests-\(UUID())"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let sync = Meeting(id: "evt1", title: "Weekly Sync", start: start, end: start.addingTimeInterval(3600),
                           attendees: [], meetingURL: nil, type: .unknown, fromCalendar: true)
        XCTAssertTrue(AppState.claimOffer(for: sync, defaults: defaults))
        XCTAssertFalse(AppState.claimOffer(for: sync, defaults: defaults), "ignored or dismissed: never again")
        var tomorrow = sync
        tomorrow.start = start.addingTimeInterval(86_400)
        XCTAssertTrue(AppState.claimOffer(for: tomorrow, defaults: defaults), "the next occurrence is a new meeting")
    }
}
