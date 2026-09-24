import AppKit
import CoreImage

/// Draws a base image plus annotations into a *flipped* (top-left origin) context in image points.
/// Shared by the canvas and export so the result always matches what the user saw.
enum Renderer {
    struct Input {
        var base: CGImage
        var imageSize: CGSize // points
        var annotations: [Annotation]
        var pixelated: CGImage?
        var blurred: CGImage?
        var hiddenID: UUID? = nil
    }

    static func draw(_ input: Input, in ctx: CGContext) {
        let full = CGRect(origin: .zero, size: input.imageSize)
        ctx.saveGState()
        ctx.interpolationQuality = .high
        drawImageFlipped(input.base, in: full, context: ctx)

        let visible = input.annotations.filter { $0.id != input.hiddenID }

        // 1. Redactions sit directly on the pixels.
        for a in visible where a.kind.isRedaction {
            guard let source = a.kind == .pixelate ? input.pixelated : input.blurred else { continue }
            let r = a.rect.intersection(full)
            guard !r.isNull, r.width > 0, r.height > 0 else { continue }
            ctx.saveGState()
            ctx.clip(to: r)
            drawImageFlipped(source, in: full, context: ctx)
            ctx.restoreGState()
        }

        // 2. Spotlight dims everything except the chosen areas.
        let spots = visible.filter { $0.kind == .spotlight && $0.rect.width > 0 && $0.rect.height > 0 }
        if !spots.isEmpty {
            ctx.saveGState()
            ctx.beginTransparencyLayer(in: full, auxiliaryInfo: nil)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
            ctx.fill(full)
            ctx.setBlendMode(.clear)
            for s in spots {
                ctx.addPath(CGPath(roundedRect: s.rect, cornerWidth: min(8, s.rect.width / 2, s.rect.height / 2),
                                   cornerHeight: min(8, s.rect.width / 2, s.rect.height / 2), transform: nil))
                ctx.fillPath()
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }

        // 3. Everything else in z-order.
        // Counters are numbered by their order in the list, including the hidden one.
        var counter = 0
        for a in input.annotations {
            if a.kind == .counter { counter += 1 }
            guard a.id != input.hiddenID, !a.kind.isRedaction, a.kind != .spotlight else { continue }
            draw(a, number: counter, in: ctx)
        }
        ctx.restoreGState()
    }

    private static func applyShadow(_ ctx: CGContext, strength: CGFloat = 0.3) {
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: CGColor(gray: 0, alpha: strength))
    }

    static func draw(_ a: Annotation, number: Int, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let color = a.color.cgColor

        switch a.kind {
        case .rectangle:
            guard a.rect.width > 0 || a.rect.height > 0 else { return }
            applyShadow(ctx)
            let r = a.rect
            let radius = min(a.lineWidth, r.width / 2, r.height / 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setStrokeColor(color)
            ctx.setLineWidth(a.lineWidth)
            ctx.strokePath()

        case .filledRectangle:
            let r = a.rect
            guard r.width > 0, r.height > 0 else { return }
            let radius = min(4, r.width / 2, r.height / 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(color)
            ctx.fillPath()

        case .ellipse:
            guard a.rect.width > 0 || a.rect.height > 0 else { return }
            applyShadow(ctx)
            ctx.addEllipse(in: a.rect)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(a.lineWidth)
            ctx.strokePath()

        case .line:
            applyShadow(ctx)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(a.lineWidth)
            ctx.strokeLineSegments(between: [a.start, a.end])

        case .arrow:
            guard let path = arrowPath(from: a.start, to: a.end, width: a.lineWidth) else { return }
            applyShadow(ctx, strength: 0.35)
            ctx.addPath(path)
            ctx.setFillColor(color)
            ctx.fillPath()

        case .pen:
            guard !a.points.isEmpty else { return }
            applyShadow(ctx, strength: 0.2)
            ctx.addPath(smoothPath(a.points))
            ctx.setStrokeColor(color)
            ctx.setLineWidth(a.lineWidth)
            ctx.strokePath()

        case .highlighter:
            guard !a.points.isEmpty else { return }
            ctx.setBlendMode(.multiply)
            ctx.addPath(smoothPath(a.points))
            ctx.setStrokeColor(a.color.withAlpha(0.45))
            ctx.setLineWidth(a.strokeWidth)
            ctx.setLineCap(.butt)
            ctx.strokePath()

        case .counter:
            let d = a.counterDiameter
            let circle = CGRect(x: a.start.x - d / 2, y: a.start.y - d / 2, width: d, height: d)
            applyShadow(ctx, strength: 0.35)
            ctx.setFillColor(color)
            ctx.fillEllipse(in: circle)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(max(1.5, d / 14))
            ctx.strokeEllipse(in: circle.insetBy(dx: d / 28, dy: d / 28))
            let text = "\(number)" as NSString
            let fontSize = d * (number >= 10 ? 0.45 : 0.55)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: a.color.contrastingText,
            ]
            let size = text.size(withAttributes: attrs)
            withNSContext(ctx) {
                text.draw(at: CGPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2), withAttributes: attrs)
            }

        case .text:
            drawText(a, in: ctx)

        case .pixelate, .blur, .spotlight:
            break
        }
    }

    private static func drawText(_ a: Annotation, in ctx: CGContext) {
        guard !a.text.isEmpty else { return }
        let b = a.bounds
        let pad = Annotation.textPadding
        let origin = CGPoint(x: b.minX + pad.width, y: b.minY + pad.height)
        let textRect = CGRect(origin: origin, size: a.textSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left

        withNSContext(ctx) {
            switch a.textStyle {
            case .plain:
                applyShadow(ctx, strength: 0.35)
                (a.text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [
                    .font: a.font, .foregroundColor: a.color.nsColor, .paragraphStyle: paragraph,
                ])
            case .outline:
                let outlineColor: NSColor = a.color.luminance > 0.75 ? NSColor(white: 0.08, alpha: 1) : .white
                applyShadow(ctx, strength: 0.3)
                (a.text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [
                    .font: a.font, .foregroundColor: outlineColor, .strokeColor: outlineColor,
                    .strokeWidth: 22.0, .paragraphStyle: paragraph,
                ])
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                (a.text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [
                    .font: a.font, .foregroundColor: a.color.nsColor, .paragraphStyle: paragraph,
                ])
            case .background:
                applyShadow(ctx, strength: 0.3)
                let radius = min(8, b.height / 2)
                ctx.addPath(CGPath(roundedRect: b, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.setFillColor(a.color.cgColor)
                ctx.fillPath()
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                (a.text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [
                    .font: a.font, .foregroundColor: a.color.contrastingText, .paragraphStyle: paragraph,
                ])
            }
        }
    }

    /// Runs AppKit text drawing against a flipped CGContext.
    static func withNSContext(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A tapered shaft plus a solid head, filled as one shape.
    static func arrowPath(from s: CGPoint, to e: CGPoint, width w: CGFloat) -> CGPath? {
        let dx = e.x - s.x, dy = e.y - s.y
        let length = hypot(dx, dy)
        guard length > 1 else { return nil }
        let ux = dx / length, uy = dy / length
        let nx = -uy, ny = ux
        let headLength = min(length * 0.6, max(12, w * 4.2))
        let headHalf = max(6, w * 2.1) * min(1, length / (headLength * 1.2))
        let base = CGPoint(x: e.x - ux * headLength, y: e.y - uy * headLength)
        let tail = max(0.8, w * 0.25)
        let neck = max(1.2, w * 0.6)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: s.x + nx * tail, y: s.y + ny * tail))
        path.addLine(to: CGPoint(x: base.x + nx * neck, y: base.y + ny * neck))
        path.addLine(to: CGPoint(x: base.x + nx * headHalf, y: base.y + ny * headHalf))
        path.addLine(to: e)
        path.addLine(to: CGPoint(x: base.x - nx * headHalf, y: base.y - ny * headHalf))
        path.addLine(to: CGPoint(x: base.x - nx * neck, y: base.y - ny * neck))
        path.addLine(to: CGPoint(x: s.x - nx * tail, y: s.y - ny * tail))
        path.addArc(center: s, radius: tail, startAngle: atan2(-ny, -nx), endAngle: atan2(ny, nx), clockwise: false)
        path.closeSubpath()
        return path
    }

    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: first)
            return path
        }
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    // MARK: Derived images for redaction

    static func pixelated(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let ci = CIImage(cgImage: image)
        let filter = CIFilter(name: "CIPixellate")
        filter?.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        filter?.setValue(max(8, 10 * scale), forKey: kCIInputScaleKey)
        filter?.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let out = filter?.outputImage?.cropped(to: ci.extent) else { return nil }
        return CIContext(options: nil).createCGImage(out, from: ci.extent)
    }

    static func blurred(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let ci = CIImage(cgImage: image)
        // Pixellate first so the blur can't be reversed, then blur for a smooth look.
        var input = ci.clampedToExtent()
        if let pix = CIFilter(name: "CIPixellate") {
            pix.setValue(input, forKey: kCIInputImageKey)
            pix.setValue(max(4, 5 * scale), forKey: kCIInputScaleKey)
            if let out = pix.outputImage { input = out }
        }
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(input, forKey: kCIInputImageKey)
        filter?.setValue(9 * scale, forKey: kCIInputRadiusKey)
        guard let out = filter?.outputImage?.cropped(to: ci.extent) else { return nil }
        return CIContext(options: nil).createCGImage(out, from: ci.extent)
    }

    // MARK: Export

    /// Renders the final image (cropped & resized) at full pixel resolution.
    static func export(base: CGImage, scale: CGFloat, state: EditorDocumentState,
                       pixelated: CGImage?, blurred: CGImage?) -> CGImage? {
        let imageSize = CGSize(width: CGFloat(base.width) / scale, height: CGFloat(base.height) / scale)
        let crop = state.cropRect.intersection(CGRect(origin: .zero, size: imageSize))
        guard crop.width >= 1, crop.height >= 1 else { return nil }
        let pixelScale = scale * state.outputScale
        let w = max(1, Int((crop.width * pixelScale).rounded()))
        let h = max(1, Int((crop.height * pixelScale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageUtil.bitmapSpace(for: base),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Flip to top-left origin, then map image points → output pixels.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(w) / crop.width, y: -CGFloat(h) / crop.height)
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        draw(Input(base: base, imageSize: imageSize, annotations: state.annotations,
                   pixelated: pixelated, blurred: blurred), in: ctx)
        return ctx.makeImage()
    }
}
