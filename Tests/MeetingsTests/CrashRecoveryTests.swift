import XCTest
@testable import Meetings

final class CrashRecoveryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("meetings-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeSpool(_ name: String, frames: Int) throws {
        let samples = (0..<frames).map { Int16(truncatingIfNeeded: $0) }
        try samples.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: dir.appendingPathComponent(name))
    }

    func testRecoversStereoWithMeetingTitle() throws {
        try writeSpool("recording_a.mic.raw", frames: 48_000)
        try writeSpool("recording_a.system.raw", frames: 24_000)
        let meeting = Meeting.adHoc(title: "Pairing", start: Date(timeIntervalSince1970: 1_790_000_000))
        CombinedAudioCapture.saveMeeting(meeting, for: dir.appendingPathComponent("recording_a.wav"))

        let recovered = CombinedAudioCapture.recoverOrphans(in: dir)

        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].meeting.title, "Pairing (recovered)")
        XCTAssertEqual(recovered[0].meeting.start, meeting.start)
        let info = try XCTUnwrap(WAVInfo.read(recovered[0].wavURL))
        XCTAssertEqual(info.channels, 2)
        XCTAssertEqual(info.frames, 48_000)  // the longer channel; the shorter is padded with silence
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(leftovers, ["recording_a.wav"])
    }

    func testRecoversMonoWithoutSidecar() throws {
        try writeSpool("recording_b.system.raw", frames: 4_800)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("recording_b.mic.raw").path, contents: Data())

        let recovered = CombinedAudioCapture.recoverOrphans(in: dir)

        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].meeting.title, "Meeting (recovered)")
        XCTAssertEqual(WAVInfo.read(recovered[0].wavURL)?.channels, 1)
    }

    func testDiscardsEmptySpools() throws {
        for name in ["recording_c.mic.raw", "recording_c.system.raw"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        XCTAssertTrue(CombinedAudioCapture.recoverOrphans(in: dir).isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }
}
