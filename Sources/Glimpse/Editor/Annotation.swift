import AppKit

struct RGBA: Codable, Equatable, Hashable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat

    init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? NSColor.red
        r = c.redComponent; g = c.greenComponent; b = c.blueComponent; a = c.alphaComponent
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    func withAlpha(_ alpha: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }

    /// Relative luminance, for choosing readable text on a coloured background.
    var luminance: CGFloat { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    var contrastingText: NSColor { luminance > 0.6 ? NSColor(white: 0.08, alpha: 1) : .white }

    static let defaultRed = RGBA(r: 0.96, g: 0.23, b: 0.25)
    static let presets: [RGBA] = [
        RGBA(r: 0.96, g: 0.23, b: 0.25), // red
        RGBA(r: 1.00, g: 0.58, b: 0.00), // orange
        RGBA(r: 1.00, g: 0.84, b: 0.04), // yellow
        RGBA(r: 0.20, g: 0.78, b: 0.35), // green
        RGBA(r: 0.00, g: 0.48, b: 1.00), // blue
        RGBA(r: 0.69, g: 0.32, b: 0.87), // purple
        RGBA(r: 0.08, g: 0.08, b: 0.08), // black
        RGBA(r: 1.00, g: 1.00, b: 1.00), // white
    ]
}

enum TextStyle: String, CaseIterable, Codable, Identifiable {
    case plain, outline, background
    var id: String { rawValue }
    var title: String {
        switch self {
        case .plain: return "Plain"
        case .outline: return "Outline"
        case .background: return "Background"
        }
    }
}

enum AnnotationKind: String, Codable {
    case arrow, line, rectangle, filledRectangle, ellipse, pen, highlighter, text, counter, pixelate, blur, spotlight

    var isRedaction: Bool { self == .pixelate || self == .blur }
    /// Kinds that are defined by a start/end box and can be resized with corner handles.
    var isBoxed: Bool { [.rectangle, .filledRectangle, .ellipse, .pixelate, .blur, .spotlight].contains(self) }
    var isLinear: Bool { self == .arrow || self == .line }
    var isFreehand: Bool { self == .pen || self == .highlighter }
    /// Area kinds cover content; they're only grabbed with a drawing tool when already selected.
    var isArea: Bool { [.filledRectangle, .pixelate, .blur, .spotlight].contains(self) }
}

struct Annotation: Identifiable, Equatable {
    var id = UUID()
    var kind: AnnotationKind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: RGBA
    var lineWidth: CGFloat
    var text: String = ""
    var fontSize: CGFloat = 24
    var textStyle: TextStyle = .outline

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    mutating func offset(dx: CGFloat, dy: CGFloat) {
        start.x += dx; start.y += dy
        end.x += dx; end.y += dy
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    var counterDiameter: CGFloat { max(22, 14 + lineWidth * 4) }

    var font: NSFont { NSFont.systemFont(ofSize: fontSize, weight: .bold) }

    static let textPadding = CGSize(width: 8, height: 4)

    /// Size of the text body (without style padding).
    var textSize: CGSize {
        let s = text.isEmpty ? " " : text
        let size = (s as NSString).boundingRect(with: CGSize(width: 10_000, height: 10_000),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                attributes: [.font: font]).size
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// Bounds used for drawing, hit-testing and selection.
    var bounds: CGRect {
        switch kind {
        case .text:
            let s = textSize
            let p = Annotation.textPadding
            return CGRect(x: start.x, y: start.y, width: s.width + p.width * 2, height: s.height + p.height * 2)
        case .counter:
            let d = counterDiameter
            return CGRect(x: start.x - d / 2, y: start.y - d / 2, width: d, height: d)
        case .pen, .highlighter:
            guard let first = points.first else { return .zero }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for p in points {
                minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            }
            let pad = strokeWidth / 2
            return CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
        case .arrow, .line:
            return rect.insetBy(dx: -lineWidth * 2, dy: -lineWidth * 2)
        default:
            return rect
        }
    }

    /// Stroke width actually drawn (highlighter is much wider than the chosen size).
    var strokeWidth: CGFloat {
        kind == .highlighter ? max(14, lineWidth * 4) : lineWidth
    }

    /// `strict`: only hit the visible ink (used while a drawing tool is active).
    func hitTest(_ p: CGPoint, strict: Bool, tolerance: CGFloat = 6) -> Bool {
        switch kind {
        case .arrow, .line:
            return distance(from: p, toSegment: start, end) <= lineWidth / 2 + tolerance + (kind == .arrow ? lineWidth : 0)
        case .pen, .highlighter:
            let limit = strokeWidth / 2 + tolerance
            if points.count == 1 { return hypot(p.x - points[0].x, p.y - points[0].y) <= limit }
            for i in 1..<max(points.count, 1) where distance(from: p, toSegment: points[i - 1], points[i]) <= limit {
                return true
            }
            return false
        case .rectangle, .ellipse:
            if !strict { return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(p) }
            let outer = rect.insetBy(dx: -lineWidth / 2 - tolerance, dy: -lineWidth / 2 - tolerance)
            let inner = rect.insetBy(dx: lineWidth / 2 + tolerance, dy: lineWidth / 2 + tolerance)
            if kind == .ellipse {
                return ellipseContains(outer, p) && !(inner.width > 0 && inner.height > 0 && ellipseContains(inner, p))
            }
            return outer.contains(p) && !(inner.width > 0 && inner.height > 0 && inner.contains(p))
        case .text, .counter:
            return bounds.insetBy(dx: -2, dy: -2).contains(p)
        case .filledRectangle, .pixelate, .blur, .spotlight:
            return rect.contains(p)
        }
    }

    private func ellipseContains(_ r: CGRect, _ p: CGPoint) -> Bool {
        guard r.width > 0, r.height > 0 else { return false }
        let dx = (p.x - r.midX) / (r.width / 2)
        let dy = (p.y - r.midY) / (r.height / 2)
        return dx * dx + dy * dy <= 1
    }
}

func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

/// Snapshot of everything the editor can change; used for undo and to reopen a capture's edits.
struct EditorDocumentState: Equatable {
    var annotations: [Annotation]
    var cropRect: CGRect
    var outputScale: CGFloat
}
