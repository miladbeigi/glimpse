import AppKit
import XCTest
@testable import Glimpse

/// Writes a sample render to $GLIMPSE_RENDER_OUT for eyeballing. Skipped otherwise.
@MainActor
final class VisualRenderTests: XCTestCase {
    func testWriteSampleRender() throws {
        guard let out = ProcessInfo.processInfo.environment["GLIMPSE_RENDER_OUT"] else { throw XCTSkip("no output path") }
        let w = 1200, h = 700
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.97, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for i in 0..<14 {
            ("The quick brown fox jumps over the lazy dog — line \(i) secret@example.com" as NSString)
                .draw(at: CGPoint(x: 40, y: 660 - i * 46), withAttributes: [.font: NSFont.systemFont(ofSize: 26)])
        }
        NSGraphicsContext.restoreGraphicsState()
        let base = ctx.makeImage()!
        let model = EditorModel(image: base, scale: 2, state: nil) // 600x350 pt
        func add(_ k: AnnotationKind, _ s: CGPoint, _ e: CGPoint, color: RGBA = .defaultRed, text: String = "", style: TextStyle = .outline, pts: [CGPoint] = []) {
            var a = Annotation(kind: k, start: s, end: e, color: color, lineWidth: 4)
            a.text = text; a.textStyle = style; a.points = pts; a.fontSize = 22
            model.add(a)
        }
        add(.pixelate, CGPoint(x: 300, y: 10), CGPoint(x: 590, y: 40))
        add(.blur, CGPoint(x: 300, y: 55), CGPoint(x: 590, y: 85))
        add(.spotlight, CGPoint(x: 15, y: 100), CGPoint(x: 330, y: 135))
        add(.arrow, CGPoint(x: 420, y: 250), CGPoint(x: 330, y: 125))
        add(.line, CGPoint(x: 20, y: 330), CGPoint(x: 200, y: 330), color: RGBA.presets[4])
        add(.rectangle, CGPoint(x: 20, y: 150), CGPoint(x: 150, y: 200), color: RGBA.presets[3])
        add(.ellipse, CGPoint(x: 170, y: 150), CGPoint(x: 280, y: 210), color: RGBA.presets[5])
        add(.filledRectangle, CGPoint(x: 460, y: 150), CGPoint(x: 580, y: 180), color: RGBA.presets[6])
        add(.highlighter, .zero, .zero, color: RGBA.presets[2], pts: [CGPoint(x: 20, y: 236), CGPoint(x: 250, y: 236)])
        add(.pen, .zero, .zero, color: RGBA.presets[1], pts: (0..<40).map { CGPoint(x: 300 + Double($0) * 6, y: 300 + sin(Double($0) / 3) * 15) })
        add(.counter, CGPoint(x: 440, y: 270), .zero)
        add(.counter, CGPoint(x: 480, y: 270), .zero, color: RGBA.presets[4])
        add(.text, CGPoint(x: 20, y: 260), .zero, text: "Outline text", style: .outline)
        add(.text, CGPoint(x: 180, y: 260), .zero, color: RGBA.presets[4], text: "Background", style: .background)
        add(.text, CGPoint(x: 330, y: 190), .zero, color: RGBA.presets[6], text: "Plain", style: .plain)
        let img = model.render()!
        try ImageExporter.write(img, scale: 2, to: URL(fileURLWithPath: out))
    }
}
