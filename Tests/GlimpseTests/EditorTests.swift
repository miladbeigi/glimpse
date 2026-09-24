import AppKit
import XCTest
@testable import Glimpse

@MainActor
final class EditorTests: XCTestCase {
    private func solidImage(width: Int, height: Int, gray: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A checker pattern so pixelation visibly changes pixels.
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: (y / 2) % 2 * 2, to: width, by: 4) {
                ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
            }
        }
        return ctx.makeImage()!
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> UInt32 {
        let (data, w, _) = Stitcher.rgba(image)!
        return data.withUnsafeBytes { $0.bindMemory(to: UInt32.self)[y * w + x] }
    }

    func testExportSizeHonoursCropAndResize() {
        let base = solidImage(width: 400, height: 300, gray: 1)
        let model = EditorModel(image: base, scale: 2, state: nil)
        XCTAssertEqual(model.imageSize, CGSize(width: 200, height: 150))
        model.tool = .crop
        model.cropDraft = CGRect(x: 10, y: 20, width: 100, height: 50)
        model.applyCrop()
        XCTAssertEqual(model.cropRect, CGRect(x: 10, y: 20, width: 100, height: 50))
        XCTAssertEqual(model.render()?.width, 200)
        XCTAssertEqual(model.render()?.height, 100)
        model.setOutputScale(0.5)
        XCTAssertEqual(model.render()?.width, 100)
        XCTAssertEqual(model.render()?.height, 50)
        model.undo()
        XCTAssertEqual(model.outputScale, 1)
        model.undo()
        XCTAssertEqual(model.cropRect, model.fullRect)
        XCTAssertTrue(model.canRedo)
    }

    func testRectangleIsDrawnWithFlippedCoordinates() {
        let base = solidImage(width: 200, height: 200, gray: 1)
        let model = EditorModel(image: base, scale: 1, state: nil)
        // Filled rectangle in the top-left quadrant (top-left origin).
        model.add(Annotation(kind: .filledRectangle, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100),
                             color: RGBA(r: 0, g: 0, b: 1), lineWidth: 4))
        let out = model.render()!
        // Memory row 0 is the top of the image.
        let topLeft = pixel(out, x: 50, y: 50)
        let bottomRight = pixel(out, x: 150, y: 150)
        XCTAssertEqual(topLeft & 0x00FF_FFFF, 0x00FF_0000, "expected pure blue (RGBA little-endian) at top-left")
        XCTAssertNotEqual(bottomRight & 0x00FF_FFFF, 0x00FF_0000)
    }

    func testPixelateChangesOnlyTheRegion() {
        let base = solidImage(width: 200, height: 200, gray: 1)
        let model = EditorModel(image: base, scale: 1, state: nil)
        model.add(Annotation(kind: .pixelate, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100),
                             color: .defaultRed, lineWidth: 4))
        let out = model.render()!
        var changedInside = 0
        var changedOutside = 0
        for y in stride(from: 1, to: 200, by: 7) {
            for x in stride(from: 1, to: 200, by: 7) {
                let differs = pixel(out, x: x, y: y) != pixel(base, x: x, y: y)
                if x < 98 && y < 98 { changedInside += differs ? 1 : 0 }
                if x > 102 || y > 102 { changedOutside += differs ? 1 : 0 }
            }
        }
        XCTAssertGreaterThan(changedInside, 20)
        XCTAssertEqual(changedOutside, 0)
    }

    func testAllAnnotationKindsRender() {
        let base = solidImage(width: 300, height: 200, gray: 0.9)
        let model = EditorModel(image: base, scale: 1, state: nil)
        let kinds: [AnnotationKind] = [.arrow, .line, .rectangle, .filledRectangle, .ellipse, .pen, .highlighter,
                                       .text, .counter, .pixelate, .blur, .spotlight]
        for (i, k) in kinds.enumerated() {
            var a = Annotation(kind: k, start: CGPoint(x: 10 + i * 20, y: 10), end: CGPoint(x: 60 + i * 20, y: 80),
                               color: .defaultRed, lineWidth: 4)
            if k.isFreehand { a.points = [CGPoint(x: 10, y: 150), CGPoint(x: 80, y: 160), CGPoint(x: 150, y: 150)] }
            if k == .text { a.text = "Hello" }
            model.add(a)
        }
        let out = model.render()
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.width, 300)
    }

    func testHitTesting() {
        let arrow = Annotation(kind: .arrow, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0), color: .defaultRed, lineWidth: 4)
        XCTAssertTrue(arrow.hitTest(CGPoint(x: 50, y: 3), strict: true))
        XCTAssertFalse(arrow.hitTest(CGPoint(x: 50, y: 40), strict: true))

        let rect = Annotation(kind: .rectangle, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100), color: .defaultRed, lineWidth: 4)
        XCTAssertTrue(rect.hitTest(CGPoint(x: 1, y: 50), strict: true))
        XCTAssertFalse(rect.hitTest(CGPoint(x: 50, y: 50), strict: true), "interior isn't ink")
        XCTAssertTrue(rect.hitTest(CGPoint(x: 50, y: 50), strict: false))
    }

    func testCountersRenumberAfterDelete() {
        let base = solidImage(width: 100, height: 100, gray: 1)
        let model = EditorModel(image: base, scale: 1, state: nil)
        let c1 = Annotation(kind: .counter, start: CGPoint(x: 20, y: 20), end: .zero, color: .defaultRed, lineWidth: 4)
        let c2 = Annotation(kind: .counter, start: CGPoint(x: 60, y: 60), end: .zero, color: .defaultRed, lineWidth: 4)
        model.add(c1)
        model.add(c2)
        model.selectedID = c1.id
        model.deleteSelected()
        XCTAssertEqual(model.annotations.map(\.id), [c2.id])
        model.undo()
        XCTAssertEqual(model.annotations.count, 2)
    }

    func testKeyComboDisplay() {
        let combo = HotkeyAction.captureArea.defaultCombo!
        XCTAssertEqual(combo.modifierSymbols, "⌥⇧⌘")
        XCTAssertEqual(combo.keyName, "4")
        XCTAssertEqual(combo.menuKeyEquivalent, "4")
    }
}
