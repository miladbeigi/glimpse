import XCTest
@testable import Glimpse

final class UpdaterTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(Updater.isNewer("1.0.1", than: "1.0.0"))
        XCTAssertTrue(Updater.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertTrue(Updater.isNewer("2", than: "1.9"))
        XCTAssertFalse(Updater.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(Updater.isNewer("0.9.0", than: "1.0.0"))
    }

    func testParsesRelease() throws {
        let json = """
        {"tag_name": "v1.2.0", "html_url": "https://github.com/o/r/releases/tag/v1.2.0", "assets": [
          {"name": "Glimpse-1.2.0.zip.sha256", "browser_download_url": "https://example.com/Glimpse-1.2.0.zip.sha256"},
          {"name": "Glimpse-1.2.0.zip", "browser_download_url": "https://example.com/Glimpse-1.2.0.zip"}
        ]}
        """
        let release = try XCTUnwrap(Updater.parseRelease(Data(json.utf8)))
        XCTAssertEqual(release.version, "1.2.0")
        XCTAssertEqual(release.zipURL.lastPathComponent, "Glimpse-1.2.0.zip")
        XCTAssertEqual(release.checksumURL?.lastPathComponent, "Glimpse-1.2.0.zip.sha256")
    }

    func testIgnoresPrereleaseAndRequiresAsset() {
        XCTAssertNil(try Updater.parseRelease(Data(#"{"tag_name": "v2.0.0", "prerelease": true}"#.utf8)))
        XCTAssertThrowsError(try Updater.parseRelease(Data(#"{"tag_name": "v2.0.0", "assets": []}"#.utf8)))
    }
}
