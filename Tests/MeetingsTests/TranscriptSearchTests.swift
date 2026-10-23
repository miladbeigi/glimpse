import XCTest
@testable import Meetings

final class TranscriptSearchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("transcripts-\(UUID().uuidString)", isDirectory: true)
        try write("2026-03-02/202603021000-Weekly-Sync.md", """
            # Weekly Sync

            **Date:** 2026-03-02 10:00
            **Duration:** 30 minutes
            **Attendees:** Alice, Bob
            **Meeting URL:** https://example.com/weekly

            ---

            **Alice:** Let's look at the pricing page first.

            **Bob:** The new pricing tiers ship on Friday.

            **Alice:** Then the roadmap.
            """)
        try write("2026-03-05/202603051500-Design-Review.md", """
            # Design Review

            **Date:** 2026-03-05 15:00
            **Duration:** 45 minutes
            **Attendees:** Carol, alice.smith@example.com

            ---

            **Carol:** The onboarding flow needs a café-style welcome screen.
            """)
        try write("Notes/202602201300-Kickoff.md", "# Kickoff\n\nNo header rule in this one, mentions pricing.")
        try write("Old.app/Contents/readme.md", "# Not a transcript\n\n---\n\npricing")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func day(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    func testFindsTranscriptsNewestFirstAndSkipsPackages() {
        let files = TranscriptSearch.all(in: root)
        XCTAssertEqual(files.map(\.title), ["Design Review", "Weekly Sync", "202602201300-Kickoff"])
    }

    func testParsesHeader() throws {
        let sync = try XCTUnwrap(TranscriptSearch.all(in: root).first { $0.title == "Weekly Sync" })
        XCTAssertEqual(sync.durationMinutes, 30)
        XCTAssertEqual(sync.attendees, ["Alice", "Bob"])
        XCTAssertEqual(sync.meetingURL, "https://example.com/weekly")
        XCTAssertTrue(sync.body.hasPrefix("**Alice:**"))
        XCTAssertNotNil(sync.date)
    }

    func testFileNameDateWhenThereIsNoHeader() throws {
        let kickoff = try XCTUnwrap(TranscriptSearch.all(in: root).first { $0.url.lastPathComponent.contains("Kickoff") })
        XCTAssertEqual(Calendar.current.startOfDay(for: try XCTUnwrap(kickoff.date)), day("2026-02-20"))
    }

    func testEveryTermMustMatch() {
        let files = TranscriptSearch.all(in: root)
        XCTAssertEqual(TranscriptSearch.search(files, query: "pricing").map(\.file.title).count, 2)
        XCTAssertEqual(TranscriptSearch.search(files, query: "pricing friday").map(\.file.title), ["Weekly Sync"])
        XCTAssertEqual(TranscriptSearch.search(files, query: "pricing onboarding").count, 0)
    }

    func testPhrasesCaseAndAccents() {
        let files = TranscriptSearch.all(in: root)
        XCTAssertEqual(TranscriptSearch.search(files, query: "\"pricing tiers\"").map(\.file.title), ["Weekly Sync"])
        XCTAssertEqual(TranscriptSearch.search(files, query: "\"tiers pricing\"").count, 0)
        XCTAssertEqual(TranscriptSearch.search(files, query: "CAFE").map(\.file.title), ["Design Review"])
    }

    func testSnippetsAreSpeakerParagraphs() throws {
        let hit = try XCTUnwrap(TranscriptSearch.search(TranscriptSearch.all(in: root), query: "pricing")
            .first { $0.file.title == "Weekly Sync" })
        XCTAssertEqual(hit.matchingParagraphs, 2)
        XCTAssertEqual(hit.snippets.first, "**Alice:** Let's look at the pricing page first.")
        XCTAssertEqual(TranscriptSearch.search([hit.file], query: "pricing", maxSnippets: 1).first?.snippets.count, 1)
    }

    func testAttendeeAndDateFilters() {
        let files = TranscriptSearch.all(in: root)
        XCTAssertEqual(TranscriptSearch.search(files, attendee: "alice").map(\.file.title), ["Design Review", "Weekly Sync"])
        XCTAssertEqual(TranscriptSearch.search(files, attendee: "carol").map(\.file.title), ["Design Review"])
        XCTAssertEqual(TranscriptSearch.search(files, from: day("2026-03-02"), to: day("2026-03-02")).map(\.file.title), ["Weekly Sync"])
        XCTAssertEqual(TranscriptSearch.search(files, from: day("2026-03-03")).map(\.file.title), ["Design Review"])
        XCTAssertEqual(TranscriptSearch.search(files).count, 3, "no filters lists everything")
    }

    func testLongParagraphIsCutAroundTheMatchKeepingTheSpeaker() {
        let paragraph = "**Bob:** " + String(repeating: "filler ", count: 100) + "the budget is final " + String(repeating: "more ", count: 100)
        let snippet = TranscriptSearch.excerpt(paragraph, around: "budget", length: 120)
        XCTAssertTrue(snippet.hasPrefix("**Bob:** …"))
        XCTAssertTrue(snippet.contains("budget"))
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertLessThan(snippet.count, 140)
    }

    func testWindowsLineEndings() {
        let file = TranscriptSearch.parse("# Standup\r\n\r\n**Date:** 2026-03-09 09:00\r\n**Attendees:** Bob\r\n\r\n---\r\n\r\n"
            + "**Bob:** Shipping today.\r\n\r\n**You:** Great.\r\n", url: root.appendingPathComponent("x.md"))
        XCTAssertEqual(file.title, "Standup")
        XCTAssertEqual(file.attendees, ["Bob"])
        XCTAssertNotNil(file.date)
        let hit = TranscriptSearch.search([file], query: "shipping").first
        XCTAssertEqual(hit?.snippets, ["**Bob:** Shipping today."])
    }

    func testNotesWithADividerKeepTheirText() {
        let file = TranscriptSearch.parse("Some notes about pricing\n\n---\n\nrest", url: root.appendingPathComponent("Notes/n.md"))
        XCTAssertEqual(file.title, "n")
        XCTAssertTrue(file.body.contains("pricing"))
        XCTAssertEqual(TranscriptSearch.search([file], query: "pricing").count, 1)
    }

    func testSymlinkedRootIsSearched() throws {
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("transcripts-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: link) }
        XCTAssertEqual(TranscriptSearch.all(in: link).count, 3)
        XCTAssertTrue(TranscriptSearch.isInside(link.appendingPathComponent("2026-03-02/202603021000-Weekly-Sync.md"), root: root))
    }

    func testSymlinkPointingOutsideIsRejected() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).md")
        try "# Secret\n\n---\n\npricing".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("2026-03-02/link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertFalse(TranscriptSearch.isInside(link, root: root))
        XCTAssertFalse(TranscriptSearch.all(in: root).contains { $0.title == "Secret" }, "symlinked files are not walked")
    }

    func testTitleOnlyMatchHasNoSnippets() throws {
        let hit = try XCTUnwrap(TranscriptSearch.search(TranscriptSearch.all(in: root), query: "design").first)
        XCTAssertEqual(hit.file.title, "Design Review")
        XCTAssertEqual(hit.matchingParagraphs, 0)
    }

    func testPathsOutsideTheFolderAreRejected() {
        XCTAssertTrue(TranscriptSearch.isInside(root.appendingPathComponent("2026-03-02/a.md"), root: root))
        XCTAssertFalse(TranscriptSearch.isInside(root.appendingPathComponent("../elsewhere.md"), root: root))
        XCTAssertFalse(TranscriptSearch.isInside(URL(fileURLWithPath: root.path + "-other/a.md"), root: root))
    }
}
