import CoreGraphics
import Foundation

/// Stitches successive frames of a vertically scrolling region into one tall image.
///
/// Each frame is reduced to one hash per row. For a new frame we detect rows that did not move
/// (sticky headers/footers), then find the downward offset `dy` for which the most non-uniform rows of
/// the new frame match the previous frame shifted by `dy`. Only newly revealed rows are appended; the
/// sticky footer is kept once, at the very bottom.
final class Stitcher: @unchecked Sendable {
    enum AddResult: Equatable {
        case first
        case appended(Int)
        case noChange
        case noMatch
    }

    let maxHeight: Int
    private(set) var width = 0
    private var frameHeight = 0
    private var bytesPerRow = 0
    private var colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private var body = Data()
    private var bodyRows = 0
    private var footer = Data()
    private var footerRows: Int?

    private var prevPixels = Data()
    private var prevHashes: [UInt64] = []
    private var prevUniform: [Bool] = []

    init(maxHeight: Int = 40_000) {
        self.maxHeight = maxHeight
    }

    var height: Int { bodyRows + (footer.count / max(bytesPerRow, 1)) }
    var isFull: Bool { height >= maxHeight }

    func add(_ image: CGImage) -> AddResult {
        guard let (pixels, w, h) = Stitcher.rgba(image) else { return .noMatch }
        let (hashes, uniform) = Stitcher.rowHashes(pixels, width: w, height: h)

        if frameHeight == 0 {
            width = w
            frameHeight = h
            bytesPerRow = w * 4
            colorSpace = ImageUtil.bitmapSpace(for: image)
            body = pixels
            bodyRows = h
            store(pixels, hashes, uniform)
            return .first
        }
        guard w == width, h == frameHeight else { return .noMatch }
        if hashes == prevHashes { return .noChange }

        var top = 0
        while top < h && hashes[top] == prevHashes[top] { top += 1 }
        var bottom = 0
        while bottom < h - top && hashes[h - 1 - bottom] == prevHashes[h - 1 - bottom] { bottom += 1 }
        // Sticky bars are small; anything bigger is probably uniform content, so cap it.
        top = min(top, h / 4)
        bottom = min(bottom, h / 4)
        let fixedBottom = footerRows ?? bottom

        guard let dy = Stitcher.bestOffset(prev: prevHashes, next: hashes, uniform: uniform,
                                           top: top, bottom: max(bottom, fixedBottom), height: h) else {
            return .noMatch
        }

        if footerRows == nil {
            footerRows = fixedBottom
            // The first frame's footer rows move from the body into the footer slot.
            body.removeLast(fixedBottom * bytesPerRow)
            bodyRows -= fixedBottom
        }
        let b = footerRows ?? 0
        let startRow = h - b - dy
        let endRow = h - b
        guard startRow >= 0, endRow > startRow else {
            store(pixels, hashes, uniform)
            return .noChange
        }
        let allowed = max(0, maxHeight - bodyRows - b)
        let rowsToAppend = min(endRow - startRow, allowed)
        if rowsToAppend > 0 {
            body.append(pixels.subdata(in: (startRow * bytesPerRow)..<((startRow + rowsToAppend) * bytesPerRow)))
            bodyRows += rowsToAppend
        }
        footer = pixels.subdata(in: (endRow * bytesPerRow)..<(h * bytesPerRow))
        store(pixels, hashes, uniform)
        return .appended(rowsToAppend)
    }

    private func store(_ pixels: Data, _ hashes: [UInt64], _ uniform: [Bool]) {
        prevPixels = pixels
        prevHashes = hashes
        prevUniform = uniform
    }

    func makeImage() -> CGImage? {
        guard width > 0 else { return nil }
        var data = body
        data.append(footer)
        let rows = data.count / bytesPerRow
        guard rows > 0, let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Internals (static for testability)

    /// Offset dy (> 0) such that next[r] == prev[r + dy] for most non-uniform rows in [top, h - bottom - dy).
    static func bestOffset(prev: [UInt64], next: [UInt64], uniform: [Bool], top: Int, bottom: Int, height h: Int) -> Int? {
        let minRows = max(8, h / 20)
        var best: (dy: Int, matches: Int)?
        let maxDy = h - top - bottom - minRows
        guard maxDy >= 1 else { return nil }
        for dy in 1...maxDy {
            var matches = 0
            var total = 0
            var r = top
            let end = h - bottom - dy
            while r < end {
                if !uniform[r] {
                    total += 1
                    if next[r] == prev[r + dy] { matches += 1 }
                }
                r += 1
            }
            guard total >= minRows, Double(matches) >= Double(total) * 0.9 else { continue }
            if best == nil || matches > best!.matches { best = (dy, matches) }
        }
        return best?.dy
    }

    static func rgba(_ image: CGImage) -> (Data, Int, Int)? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var data = Data(count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: ImageUtil.bitmapSpace(for: image),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (data, w, h) : nil
    }

    /// FNV-1a over each row, plus whether the row is a single flat colour.
    static func rowHashes(_ data: Data, width w: Int, height h: Int) -> ([UInt64], [Bool]) {
        var hashes = [UInt64](repeating: 0, count: h)
        var uniform = [Bool](repeating: false, count: h)
        data.withUnsafeBytes { raw in
            let px = raw.bindMemory(to: UInt32.self)
            for y in 0..<h {
                var hash: UInt64 = 0xcbf29ce484222325
                let rowStart = y * w
                let first = px[rowStart]
                var flat = true
                for x in 0..<w {
                    let v = px[rowStart + x]
                    if v != first { flat = false }
                    hash = (hash ^ UInt64(v)) &* 0x100000001b3
                }
                hashes[y] = hash
                uniform[y] = flat
            }
        }
        return (hashes, uniform)
    }
}
