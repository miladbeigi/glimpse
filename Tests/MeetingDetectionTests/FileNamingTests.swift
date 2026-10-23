import XCTest
@testable import MeetingDetection

final class FileNamingTests: XCTestCase {
    private let dir = URL(fileURLWithPath: "/tmp/meeting-detection-tests")

    func testFreeNameIsUsedAsIs() {
        let url = FileNaming.uniqueFileURL(in: dir, name: "202604091400-Weekly-Standup.md", exists: { _ in false })
        XCTAssertEqual(url.lastPathComponent, "202604091400-Weekly-Standup.md")
    }

    func testTakenNameGetsSuffix() {
        let taken: Set<String> = ["202604091400-Weekly-Standup.md"]
        let url = FileNaming.uniqueFileURL(in: dir, name: "202604091400-Weekly-Standup.md", exists: { taken.contains($0.lastPathComponent) })
        XCTAssertEqual(url.lastPathComponent, "202604091400-Weekly-Standup-2.md")
    }

    func testSuffixIncrementsPastTakenNumbers() {
        let taken: Set<String> = ["a.wav", "a-2.wav", "a-3.wav"]
        let url = FileNaming.uniqueFileURL(in: dir, name: "a.wav", exists: { taken.contains($0.lastPathComponent) })
        XCTAssertEqual(url.lastPathComponent, "a-4.wav")
    }

    func testNameWithoutExtension() {
        let url = FileNaming.uniqueFileURL(in: dir, name: "notes", exists: { $0.lastPathComponent == "notes" })
        XCTAssertEqual(url.lastPathComponent, "notes-2")
    }

    func testUniquingOnRealFilesystem() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let first = FileNaming.uniqueFileURL(in: tmp, name: "x.md")
        try Data().write(to: first)
        let second = FileNaming.uniqueFileURL(in: tmp, name: "x.md")
        XCTAssertEqual(second.lastPathComponent, "x-2.md")
    }

    func testSlug() {
        XCTAssertEqual(FileNaming.slug("1:1 with Bob"), "1-1-with-Bob")
        XCTAssertEqual(FileNaming.slug("Alex / Sam - Weekly 1:1"), "Alex-Sam-Weekly-1-1")
        XCTAssertEqual(FileNaming.slug("  ///  "), "Meeting")
    }

    func testBaseName() {
        let utc = TimeZone(identifier: "UTC")!
        var c = DateComponents()
        c.year = 2026; c.month = 4; c.day = 9; c.hour = 14; c.minute = 0
        c.timeZone = utc
        let date = Calendar(identifier: .gregorian).date(from: c)!
        XCTAssertEqual(FileNaming.baseName(date: date, title: "Weekly Standup", ext: "md", timeZone: utc), "202604091400-Weekly-Standup.md")
        XCTAssertEqual(FileNaming.dayFolder(for: date, timeZone: utc), "2026-04-09")
    }
}
