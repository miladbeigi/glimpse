import AppKit

/// Stitch: joins several screenshots into one numbered image.
///
/// Claude (and most vision models) shrink a large image before reading it: Claude to at most 1568 px on the long
/// edge and about 1.15 megapixels. So among the ways to arrange the pieces in rows (keeping their order), Stitch picks
/// the one that is shrunk the least, which keeps the most detail of every piece. Pieces stay at their own resolution.
enum Collage {
    struct Limits {
        var maxLongEdge: CGFloat = 1568
        var maxPixels: CGFloat = 1_150_000
    }

    struct Layout: Equatable {
        /// Where each piece goes, in pixels, top-left origin, in input order.
        var frames: [CGRect]
        var size: CGSize
        /// How much a model will shrink the whole image (1 = not at all).
        var downscale: CGFloat
        /// Pieces per row, top to bottom.
        var rows: [Int]
    }

    /// Every way to split `n` pieces into consecutive rows (2^(n-1) of them); beyond 10 pieces only even splits.
    static func rowSplits(_ n: Int) -> [[Int]] {
        guard n > 0 else { return [] }
        if n > 10 {
            return (1...n).map { rowCount in
                (0..<rowCount).map { r in (n * (r + 1)) / rowCount - (n * r) / rowCount }
            }
        }
        var result: [[Int]] = []
        for mask in 0..<(1 << (n - 1)) {
            var rows: [Int] = []
            var count = 1
            for i in 0..<(n - 1) {
                if mask & (1 << i) != 0 { rows.append(count); count = 1 } else { count += 1 }
            }
            rows.append(count)
            result.append(rows)
        }
        return result
    }

    static func layout(sizes: [CGSize], gap: CGFloat, limits: Limits = Limits()) -> Layout? {
        guard !sizes.isEmpty, sizes.allSatisfy({ $0.width > 0 && $0.height > 0 }) else { return nil }
        var best: Layout?
        var bestWaste = CGFloat.infinity
        for rows in rowSplits(sizes.count) {
            var frames: [CGRect] = []
            var rowRects: [(start: Int, count: Int, width: CGFloat, height: CGFloat)] = []
            var index = 0
            for count in rows {
                let items = sizes[index..<(index + count)]
                let width = items.reduce(0) { $0 + $1.width } + gap * CGFloat(count - 1)
                let height = items.map(\.height).max() ?? 0
                rowRects.append((index, count, width, height))
                index += count
            }
            let contentWidth = rowRects.map(\.width).max() ?? 0
            let totalWidth = contentWidth + gap * 2
            let totalHeight = rowRects.reduce(0) { $0 + $1.height } + gap * CGFloat(rowRects.count + 1)
            var y = gap
            for row in rowRects {
                var x = gap + (contentWidth - row.width) / 2
                for i in row.start..<(row.start + row.count) {
                    let s = sizes[i]
                    frames.append(CGRect(x: x, y: y + (row.height - s.height) / 2, width: s.width, height: s.height))
                    x += s.width + gap
                }
                y += row.height + gap
            }
            let downscale = min(1, limits.maxLongEdge / max(totalWidth, totalHeight),
                                (limits.maxPixels / (totalWidth * totalHeight)).squareRoot())
            let waste = totalWidth * totalHeight - sizes.reduce(0) { $0 + $1.width * $1.height }
            let candidate = Layout(frames: frames, size: CGSize(width: totalWidth, height: totalHeight),
                                   downscale: downscale, rows: rows)
            // Keep the most detail; between equals, waste the least space.
            if let current = best {
                if downscale > current.downscale * 1.001 || (abs(downscale - current.downscale) <= current.downscale * 0.001 && waste < bestWaste) {
                    best = candidate
                    bestWaste = waste
                }
            } else {
                best = candidate
                bestWaste = waste
            }
        }
        return best
    }

    /// Renders the pieces with a number badge on each, sized to stay readable after the model shrinks the image.
    static func render(_ images: [CGImage], limits: Limits = Limits()) -> (image: CGImage, layout: Layout)? {
        let sizes = images.map { CGSize(width: $0.width, height: $0.height) }
        let longest = sizes.map { max($0.width, $0.height) }.max() ?? 0
        let gap = max(16, (longest / 60).rounded())
        guard let layout = layout(sizes: sizes, gap: gap, limits: limits) else { return nil }
        let w = Int(layout.size.width.rounded(.up)), h = Int(layout.size.height.rounded(.up))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageUtil.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Top-left origin.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // About 30 px across once shrunk, but never more than a third of a small piece.
        let badgeTarget = 30 / layout.downscale
        for (i, image) in images.enumerated() {
            let frame = layout.frames[i]
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: gap / 6), blur: gap / 2, color: CGColor(gray: 0, alpha: 0.18))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(frame)
            ctx.restoreGState()
            drawImageFlipped(image, in: frame, context: ctx)

            let d = min(badgeTarget, min(frame.width, frame.height) / 3)
            let inset = min(d * 0.35, gap)
            let circle = CGRect(x: frame.minX + inset, y: frame.minY + inset, width: d, height: d)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: d / 14), blur: d / 6, color: CGColor(gray: 0, alpha: 0.4))
            ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1))
            ctx.fillEllipse(in: circle)
            ctx.restoreGState()
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(max(1.5, d / 14))
            ctx.strokeEllipse(in: circle.insetBy(dx: d / 20, dy: d / 20))
            let text = "\(i + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: d * (i + 1 >= 10 ? 0.44 : 0.54), weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let size = text.size(withAttributes: attrs)
            Renderer.withNSContext(ctx) {
                text.draw(at: CGPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2), withAttributes: attrs)
            }
        }
        guard let image = ctx.makeImage() else { return nil }
        return (image, layout)
    }

    /// Stitches captures (with their marks) into a new capture, adds it to the stack and copies it.
    @MainActor
    @discardableResult
    static func stitch(_ captures: [Capture]) -> Capture? {
        guard captures.count >= 2 else {
            HUD.show("Select two or more screenshots to stitch", symbol: "square.grid.2x2")
            return nil
        }
        guard let (image, _) = render(captures.map(\.image)) else {
            HUD.show("Couldn't stitch these", symbol: "exclamationmark.triangle")
            return nil
        }
        let capture = Capture(image: image, scale: captures.map(\.scale).max() ?? 1)
        capture.label = "Stitched \(captures.count)"
        RecentStore.shared.add(capture)
        Clipboard.copy(image, scale: capture.scale)
        HUD.show("Stitched \(captures.count) and copied", symbol: "square.grid.2x2.fill")
        return capture
    }
}
