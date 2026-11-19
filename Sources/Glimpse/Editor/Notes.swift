import AppKit

/// Where a note goes beside a box or an arrow: right of a box (or left, below, above when there's no room), and past
/// the tail of an arrow, so the arrow points from the note at the thing.
enum NotePlacement {
    enum Horizontal: Equatable { case leading, trailing, centered }
    enum Vertical: Equatable { case top, center, bottom }

    struct Placement: Equatable {
        var anchor: CGPoint
        var horizontal: Horizontal
        var vertical: Vertical
    }

    /// `estimate` is a typical note size, used to decide whether there's room on a side.
    static func placement(for a: Annotation, imageSize: CGSize, estimate: CGSize = CGSize(width: 140, height: 40)) -> Placement {
        let gap: CGFloat = 8
        if a.kind == .arrow {
            let tail = a.start
            // Direction the tail points away from the head (for a curved arrow, along its first stretch).
            let towards = a.points.count >= 3 ? a.points[min(6, a.points.count - 1)] : a.end
            let dx = tail.x - towards.x, dy = tail.y - towards.y
            if abs(dx) >= abs(dy) {
                return dx >= 0
                    ? Placement(anchor: CGPoint(x: tail.x + gap, y: tail.y), horizontal: .leading, vertical: .center)
                    : Placement(anchor: CGPoint(x: tail.x - gap, y: tail.y), horizontal: .trailing, vertical: .center)
            }
            return dy >= 0
                ? Placement(anchor: CGPoint(x: tail.x, y: tail.y + gap / 2), horizontal: .centered, vertical: .top)
                : Placement(anchor: CGPoint(x: tail.x, y: tail.y - gap / 2), horizontal: .centered, vertical: .bottom)
        }
        let r = a.rect
        if r.maxX + gap + estimate.width <= imageSize.width {
            return Placement(anchor: CGPoint(x: r.maxX + gap, y: r.minY), horizontal: .leading, vertical: .top)
        }
        if r.minX - gap - estimate.width >= 0 {
            return Placement(anchor: CGPoint(x: r.minX - gap, y: r.minY), horizontal: .trailing, vertical: .top)
        }
        if r.maxY + gap + estimate.height <= imageSize.height {
            return Placement(anchor: CGPoint(x: r.minX, y: r.maxY + gap / 2), horizontal: .leading, vertical: .top)
        }
        return Placement(anchor: CGPoint(x: r.minX, y: r.minY - gap / 2), horizontal: .leading, vertical: .bottom)
    }

    /// Top-left of a note of `size`, kept inside the image.
    static func origin(_ p: Placement, size: CGSize, imageSize: CGSize) -> CGPoint {
        var x: CGFloat
        switch p.horizontal {
        case .leading: x = p.anchor.x
        case .trailing: x = p.anchor.x - size.width
        case .centered: x = p.anchor.x - size.width / 2
        }
        var y: CGFloat
        switch p.vertical {
        case .top: y = p.anchor.y
        case .center: y = p.anchor.y - size.height / 2
        case .bottom: y = p.anchor.y - size.height
        }
        x = min(max(0, x), max(0, imageSize.width - size.width))
        y = min(max(0, y), max(0, imageSize.height - size.height))
        return CGPoint(x: x, y: y)
    }

    /// A text annotation for `text`, placed beside `anchor`.
    static func note(_ text: String, beside anchor: Annotation, imageSize: CGSize, color: RGBA, fontSize: CGFloat,
                     style: TextStyle) -> (Annotation, Placement) {
        var note = Annotation(kind: .text, start: .zero, end: .zero, color: color, lineWidth: anchor.lineWidth,
                              text: text, fontSize: fontSize, textStyle: style)
        let place = placement(for: anchor, imageSize: imageSize)
        note.start = origin(place, size: note.bounds.size, imageSize: imageSize)
        note.end = note.start
        return (note, place)
    }
}

/// Freehand ("pencil") arrows: the arrow tool records the stroke, and keeps it curved unless it's nearly straight.
enum FreehandArrow {
    /// True when every point is within a few points of the straight line from first to last.
    static func isNearlyStraight(_ points: [CGPoint]) -> Bool {
        guard let first = points.first, let last = points.last, points.count >= 3 else { return true }
        let length = hypot(last.x - first.x, last.y - first.y)
        guard length > 1 else { return false }
        let tolerance = max(4, length * 0.06)
        return points.allSatisfy { distance(from: $0, toSegment: first, last) <= tolerance }
    }

    static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// Drops points closer than `spacing` to the previous one (keeps the last), for a cleaner curve.
    static func simplified(_ points: [CGPoint], spacing: CGFloat = 3) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var out = [points[0]]
        for p in points.dropFirst().dropLast() where hypot(p.x - out.last!.x, p.y - out.last!.y) >= spacing {
            out.append(p)
        }
        out.append(points[points.count - 1])
        return out
    }

    /// Moves one end of a curved arrow and bends the rest along (rotate + scale about the other end).
    static func moving(_ points: [CGPoint], end movingEnd: Bool, to target: CGPoint) -> [CGPoint] {
        guard let first = points.first, let last = points.last else { return points }
        let fixed = movingEnd ? first : last
        let old = movingEnd ? last : first
        let ov = CGPoint(x: old.x - fixed.x, y: old.y - fixed.y)
        let nv = CGPoint(x: target.x - fixed.x, y: target.y - fixed.y)
        let oldLen = hypot(ov.x, ov.y), newLen = hypot(nv.x, nv.y)
        guard oldLen > 0.5 else { return points }
        let s = newLen / oldLen
        let angle = atan2(nv.y, nv.x) - atan2(ov.y, ov.x)
        let c = cos(angle) * s, si = sin(angle) * s
        return points.map { p in
            let x = p.x - fixed.x, y = p.y - fixed.y
            return CGPoint(x: fixed.x + x * c - y * si, y: fixed.y + x * si + y * c)
        }
    }

    /// The shaft (to stroke) and the head (to fill) of a curved arrow.
    static func paths(_ points: [CGPoint], width w: CGFloat) -> (shaft: CGPath, head: CGPath)? {
        guard points.count >= 2, let tip = points.last else { return nil }
        let total = pathLength(points)
        guard total > 1 else { return nil }
        let headLength = min(total * 0.6, max(12, w * 4.2))
        let headHalf = max(6, w * 2.1)
        // The head points along the last stretch of the stroke.
        var back = tip
        var walked: CGFloat = 0
        var shaftPoints = points
        for i in stride(from: points.count - 1, to: 0, by: -1) {
            let a = points[i - 1], b = points[i]
            let seg = hypot(b.x - a.x, b.y - a.y)
            if walked + seg >= headLength {
                let t = (headLength - walked) / max(seg, 0.0001)
                back = CGPoint(x: b.x + (a.x - b.x) * t, y: b.y + (a.y - b.y) * t)
                shaftPoints = Array(points[0..<i]) + [back]
                break
            }
            walked += seg
            back = a
            shaftPoints = [points[0], a]
        }
        let dx = tip.x - back.x, dy = tip.y - back.y
        let len = max(hypot(dx, dy), 0.0001)
        let ux = dx / len, uy = dy / len
        let nx = -uy, ny = ux
        let base = CGPoint(x: tip.x - ux * headLength, y: tip.y - uy * headLength)
        let head = CGMutablePath()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: base.x + nx * headHalf, y: base.y + ny * headHalf))
        head.addQuadCurve(to: CGPoint(x: base.x - nx * headHalf, y: base.y - ny * headHalf),
                          control: CGPoint(x: base.x + ux * headLength * 0.25, y: base.y + uy * headLength * 0.25))
        head.closeSubpath()
        // Run the shaft a little into the head so there's no gap.
        let into = CGPoint(x: base.x + ux * headLength * 0.3, y: base.y + uy * headLength * 0.3)
        return (Renderer.smoothPath(shaftPoints + [into]), head)
    }
}
