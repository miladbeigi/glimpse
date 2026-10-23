import XCTest
@testable import Meetings

final class VoiceProfileTests: XCTestCase {
    func testCalendarAttendeeMatchesUserByNameParts() {
        XCTAssertTrue(matchesAlias("alice.smith", aliases: ["Alice"]))
        XCTAssertTrue(matchesAlias("Alice Smith", aliases: ["alice smith"]))
        XCTAssertTrue(matchesAlias("alice.smith@example.com", aliases: ["Alice"]))
        XCTAssertFalse(matchesAlias("bob", aliases: ["Alice"]))
        XCTAssertFalse(matchesAlias("alicex", aliases: ["Alice"]))
        XCTAssertFalse(matchesAlias("alice.smith", aliases: []))
    }

    func testRefusesAProfileThatCopiesAnotherVoice() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = VoiceProfileStore(directory: dir)
        let voice: [Float] = (0..<256).map { Float(sin(Double($0))) }
        try store.save(VoiceProfile(name: "Alice", embedding: voice))
        XCTAssertThrowsError(try store.save(VoiceProfile(name: "Bob", embedding: voice)))
        XCTAssertNoThrow(try store.save(VoiceProfile(name: "Alice", embedding: voice)))  // updating the same person is fine
        let other: [Float] = (0..<256).map { Float(cos(Double($0) * 1.7)) }
        XCTAssertNoThrow(try store.save(VoiceProfile(name: "Bob", embedding: other)))
        XCTAssertEqual(store.names(), ["Alice", "Bob"])
    }
}
