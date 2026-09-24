import CoreGraphics
import XCTest
@testable import Glimpse

final class StitcherTests: XCTestCase {
    private let width = 64

    /// Deterministic noisy rows so every row is unique and non-uniform.
    private func noiseRow(_ seed: Int) -> [UInt32] {
        var state = UInt64(seed &* 2654435761 &+ 1)
        return (0..<width).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt32(truncatingIfNeeded: state >> 33) | 0xFF00_0000
        }
    }

    private func image(rows: [[UInt32]]) -> CGImage {
        var data = Data()
        for row in rows { row.withUnsafeBytes { data.append(contentsOf: $0) } }
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(width: width, height: rows.count, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func rows(of image: CGImage) -> [[UInt32]] {
        let (data, w, h) = Stitcher.rgba(image)!
        return data.withUnsafeBytes { raw in
            let px = raw.bindMemory(to: UInt32.self)
            return (0..<h).map { y in Array(px[(y * w)..<((y + 1) * w)]) }
        }
    }

    func testStitchesScrollingPageWithStickyHeaderAndFooter() {
        let header = (0..<40).map { noiseRow(100_000 + $0) }
        let footer = (0..<30).map { noiseRow(200_000 + $0) }
        let page = (0..<1500).map { noiseRow($0) }
        let viewport = 400
        let content = viewport - header.count - footer.count // 330
        let offsets = [0, 100, 100, 250, 400, 555, 800, 1000, 1170]

        let stitcher = Stitcher()
        var results: [Stitcher.AddResult] = []
        for offset in offsets {
            let frame = header + Array(page[offset..<(offset + content)]) + footer
            results.append(stitcher.add(image(rows: frame)))
        }
        XCTAssertEqual(results[0], .first)
        XCTAssertEqual(results[2], .noChange)
        XCTAssertEqual(results[1], .appended(100))
        XCTAssertEqual(results.last, .appended(170))

        let out = stitcher.makeImage()!
        let expected = header + page + footer
        XCTAssertEqual(out.height, expected.count)
        XCTAssertEqual(rows(of: out), expected)
    }

    func testPlainScrollWithoutStickyBars() {
        let page = (0..<900).map { noiseRow($0) }
        let stitcher = Stitcher()
        for offset in [0, 60, 200, 333, 500] {
            _ = stitcher.add(image(rows: Array(page[offset..<(offset + 400)])))
        }
        let out = stitcher.makeImage()!
        XCTAssertEqual(rows(of: out), Array(page[0..<900]))
    }

    func testUnrelatedFrameIsRejected() {
        let stitcher = Stitcher()
        _ = stitcher.add(image(rows: (0..<300).map { noiseRow($0) }))
        let result = stitcher.add(image(rows: (0..<300).map { noiseRow(50_000 + $0) }))
        XCTAssertEqual(result, .noMatch)
        XCTAssertEqual(stitcher.makeImage()!.height, 300)
    }

    func testMaxHeightIsRespected() {
        let page = (0..<2000).map { noiseRow($0) }
        let stitcher = Stitcher(maxHeight: 700)
        for offset in stride(from: 0, through: 1600, by: 200) {
            _ = stitcher.add(image(rows: Array(page[offset..<(offset + 400)])))
        }
        XCTAssertTrue(stitcher.isFull)
        XCTAssertEqual(stitcher.makeImage()!.height, 700)
    }
}
