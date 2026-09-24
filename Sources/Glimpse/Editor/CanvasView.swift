import AppKit
import Carbon.HIToolbox
import Combine

/// The drawing surface. Its coordinate space is image points of `model.displayRect`, top-left origin.
final class CanvasView: NSView, NSTextFieldDelegate {
    let model: EditorModel
    var onDisplayRectChange: (() -> Void)?

    private var cancellables: Set<AnyCancellable> = []
    private var lastDisplayRect: CGRect = .zero
    private var lastTool: EditorTool?

    private enum Handle { case start, end, topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right }

    private enum Drag {
        case none
        case creating(UUID)
        case moving(UUID, last: CGPoint, checkpointed: Bool)
        case resizing(UUID, Handle, checkpointed: Bool)
        case cropNew(start: CGPoint)
        case cropMove(startRect: CGRect, startPoint: CGPoint)
        case cropResize(Handle, startRect: CGRect)
    }

    private var drag: Drag = .none
    private var textField: EditorTextField?
    private var editingIsNew = false
    private var originalText = ""

    @MainActor
    init(model: EditorModel) {
        self.model = model
        super.init(frame: NSRect(origin: .zero, size: model.displayRect.size))
        clipsToBounds = true
        lastDisplayRect = model.displayRect
        lastTool = model.tool
        model.commitPendingEdits = { [weak self] in self?.commitText() ?? false }
        model.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.modelChanged() }
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func modelChanged() {
        if model.displayRect != lastDisplayRect {
            lastDisplayRect = model.displayRect
            setFrameSize(model.displayRect.size)
            onDisplayRectChange?()
        }
        if model.tool != lastTool {
            lastTool = model.tool
            if textField != nil && model.tool != .text { commitText() }
            window?.invalidateCursorRects(for: self)
        }
        if model.editingTextID == nil, textField != nil { commitText() }
        needsDisplay = true
    }

    private var origin: CGPoint { model.displayRect.origin }
    private var handleSize: CGFloat { 9 / max(model.magnification, 0.05) }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x + origin.x, y: p.y + origin.y)
    }

    // MARK: Cursor

    override func resetCursorRects() {
        let cursor: NSCursor
        switch model.tool {
        case .select: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(visibleRect, cursor: cursor)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.clip(to: bounds)
        ctx.translateBy(x: -origin.x, y: -origin.y)
        Renderer.draw(Renderer.Input(base: model.baseImage, imageSize: model.imageSize, annotations: model.annotations,
                                     pixelated: model.needsPixelated ? model.pixelatedImage : nil,
                                     blurred: model.needsBlurred ? model.blurredImage : nil,
                                     hiddenID: model.editingTextID), in: ctx)
        if model.isCropping {
            drawCropOverlay(ctx)
        } else if let sel = model.selected, sel.id != model.editingTextID {
            drawSelection(sel, ctx)
        }
        ctx.restoreGState()
    }

    private func drawHandle(at p: CGPoint, _ ctx: CGContext) {
        let s = handleSize
        let r = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
        ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 2, color: CGColor(gray: 0, alpha: 0.4))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: r)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5 / max(model.magnification, 0.05))
        ctx.strokeEllipse(in: r)
    }

    private func drawSelection(_ a: Annotation, _ ctx: CGContext) {
        ctx.saveGState()
        let lw = 1 / max(model.magnification, 0.05)
        if a.kind.isLinear {
            drawHandle(at: a.start, ctx)
            drawHandle(at: a.end, ctx)
        } else {
            let r = (a.kind.isBoxed ? a.rect : a.bounds).insetBy(dx: -3 * lw, dy: -3 * lw)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(lw)
            ctx.setLineDash(phase: 0, lengths: [4 * lw, 3 * lw])
            ctx.stroke(r)
            ctx.setLineDash(phase: 0, lengths: [])
            if a.kind.isBoxed {
                let rr = a.rect
                for p in [CGPoint(x: rr.minX, y: rr.minY), CGPoint(x: rr.maxX, y: rr.minY),
                          CGPoint(x: rr.minX, y: rr.maxY), CGPoint(x: rr.maxX, y: rr.maxY)] {
                    drawHandle(at: p, ctx)
                }
            }
        }
        ctx.restoreGState()
    }

    private func drawCropOverlay(_ ctx: CGContext) {
        let full = model.fullRect
        let c = model.cropDraft
        let lw = 1 / max(model.magnification, 0.05)
        ctx.saveGState()
        let path = CGMutablePath()
        path.addRect(full)
        path.addRect(c)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fillPath(using: .evenOdd)

        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        ctx.setLineWidth(lw)
        for i in 1...2 {
            let x = c.minX + c.width * CGFloat(i) / 3
            let y = c.minY + c.height * CGFloat(i) / 3
            ctx.strokeLineSegments(between: [CGPoint(x: x, y: c.minY), CGPoint(x: x, y: c.maxY),
                                             CGPoint(x: c.minX, y: y), CGPoint(x: c.maxX, y: y)])
        }
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(lw * 1.5)
        ctx.stroke(c)

        // Corner brackets
        let len = min(20 * lw, c.width / 3, c.height / 3)
        ctx.setLineWidth(4 * lw)
        ctx.setLineCap(.square)
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: c.minX, y: c.minY), 1, 1), (CGPoint(x: c.maxX, y: c.minY), -1, 1),
            (CGPoint(x: c.minX, y: c.maxY), 1, -1), (CGPoint(x: c.maxX, y: c.maxY), -1, -1),
        ]
        for (p, sx, sy) in corners {
            ctx.move(to: CGPoint(x: p.x, y: p.y + sy * len))
            ctx.addLine(to: p)
            ctx.addLine(to: CGPoint(x: p.x + sx * len, y: p.y))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // Size label
        let text = "\(Int((c.width * model.scale).rounded())) × \(Int((c.height * model.scale).rounded())) px"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12 * lw, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        var box = CGRect(x: c.midX - size.width / 2 - 8 * lw, y: c.maxY + 8 * lw,
                         width: size.width + 16 * lw, height: size.height + 6 * lw)
        if box.maxY > full.maxY { box.origin.y = c.maxY - box.height - 8 * lw }
        Renderer.withNSContext(ctx) {
            NSColor(white: 0, alpha: 0.7).setFill()
            NSBezierPath(roundedRect: box, xRadius: 6 * lw, yRadius: 6 * lw).fill()
            (text as NSString).draw(at: CGPoint(x: box.minX + 8 * lw, y: box.minY + 3 * lw), withAttributes: attrs)
        }
    }

    // MARK: Hit testing

    private func topHit(_ p: CGPoint, strict: Bool) -> Annotation? {
        for a in model.annotations.reversed() {
            if strict && a.kind.isArea && a.id != model.selectedID { continue }
            if a.hitTest(p, strict: strict, tolerance: 5 / max(model.magnification, 0.05)) { return a }
        }
        return nil
    }

    private func handle(at p: CGPoint, for a: Annotation) -> Handle? {
        let tol = handleSize
        func near(_ q: CGPoint) -> Bool { abs(q.x - p.x) <= tol && abs(q.y - p.y) <= tol }
        if a.kind.isLinear {
            if near(a.end) { return .end }
            if near(a.start) { return .start }
        } else if a.kind.isBoxed {
            let r = a.rect
            if near(CGPoint(x: r.minX, y: r.minY)) { return .topLeft }
            if near(CGPoint(x: r.maxX, y: r.minY)) { return .topRight }
            if near(CGPoint(x: r.minX, y: r.maxY)) { return .bottomLeft }
            if near(CGPoint(x: r.maxX, y: r.maxY)) { return .bottomRight }
        }
        return nil
    }

    private func cropHandle(at p: CGPoint) -> Handle? {
        let c = model.cropDraft
        let tol = handleSize * 1.4
        func near(_ q: CGPoint) -> Bool { abs(q.x - p.x) <= tol && abs(q.y - p.y) <= tol }
        if near(CGPoint(x: c.minX, y: c.minY)) { return .topLeft }
        if near(CGPoint(x: c.maxX, y: c.minY)) { return .topRight }
        if near(CGPoint(x: c.minX, y: c.maxY)) { return .bottomLeft }
        if near(CGPoint(x: c.maxX, y: c.maxY)) { return .bottomRight }
        let inY = p.y >= c.minY && p.y <= c.maxY
        let inX = p.x >= c.minX && p.x <= c.maxX
        if abs(p.x - c.minX) <= tol && inY { return .left }
        if abs(p.x - c.maxX) <= tol && inY { return .right }
        if abs(p.y - c.minY) <= tol && inX { return .top }
        if abs(p.y - c.maxY) <= tol && inX { return .bottom }
        return nil
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        // Clicking away from a text box only finishes editing.
        if textField != nil {
            commitText()
            return
        }
        window?.makeFirstResponder(self)
        let p = imagePoint(event)

        if model.isCropping {
            let c = model.cropDraft
            if let h = cropHandle(at: p) {
                drag = .cropResize(h, startRect: c)
            } else if c.contains(p) {
                drag = .cropMove(startRect: c, startPoint: p)
            } else {
                drag = .cropNew(start: clampToImage(p))
            }
            return
        }

        if event.clickCount == 2, let hit = topHit(p, strict: false), hit.kind == .text {
            beginEditing(hit.id, isNew: false)
            return
        }

        if let sel = model.selected, let h = handle(at: p, for: sel) {
            drag = .resizing(sel.id, h, checkpointed: false)
            return
        }

        if let hit = topHit(p, strict: model.tool != .select) {
            if model.tool == .text && hit.kind == .text {
                beginEditing(hit.id, isNew: false)
                return
            }
            model.selectedID = hit.id
            model.adoptStyle(of: hit)
            drag = .moving(hit.id, last: p, checkpointed: false)
            return
        }

        guard let kind = model.tool.kind else {
            model.selectedID = nil
            drag = .none
            return
        }

        switch kind {
        case .text:
            let font = NSFont.systemFont(ofSize: model.fontSize, weight: .bold)
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            let pad = Annotation.textPadding
            var a = Annotation(kind: .text, start: .zero, end: .zero, color: model.color, lineWidth: model.lineWidth,
                               fontSize: model.fontSize, textStyle: model.textStyle)
            a.start = CGPoint(x: p.x - pad.width, y: p.y - lineHeight / 2 - pad.height)
            a.end = a.start
            model.checkpoint()
            model.add(a)
            model.selectedID = a.id
            beginEditing(a.id, isNew: true)
        case .counter:
            let a = Annotation(kind: .counter, start: p, end: p, color: model.color, lineWidth: model.lineWidth)
            model.checkpoint()
            model.add(a)
            model.selectedID = a.id
            drag = .moving(a.id, last: p, checkpointed: true)
        default:
            let a = Annotation(kind: kind, start: p, end: p, points: kind.isFreehand ? [p] : [],
                               color: model.color, lineWidth: model.lineWidth)
            model.checkpoint()
            model.add(a)
            model.selectedID = a.id
            drag = .creating(a.id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(event)
        let shift = event.modifierFlags.contains(.shift)
        autoscroll(with: event)

        switch drag {
        case .none:
            break
        case .creating(let id):
            model.update(id) { a in
                if a.kind.isFreehand {
                    if shift, let first = a.points.first {
                        a.points = [first, CGPoint(x: p.x, y: a.kind == .highlighter ? first.y : p.y)]
                    } else if let last = a.points.last, hypot(p.x - last.x, p.y - last.y) >= 0.75 {
                        a.points.append(p)
                    }
                } else {
                    a.end = constrained(p, from: a.start, kind: a.kind, shift: shift)
                }
            }
        case .moving(let id, let last, let checkpointed):
            if !checkpointed { model.checkpoint() }
            let dx = p.x - last.x, dy = p.y - last.y
            model.update(id) { $0.offset(dx: dx, dy: dy) }
            drag = .moving(id, last: p, checkpointed: true)
        case .resizing(let id, let h, let checkpointed):
            if !checkpointed { model.checkpoint() }
            model.update(id) { a in resize(&a, handle: h, to: p, shift: shift) }
            drag = .resizing(id, h, checkpointed: true)
        case .cropNew(let start):
            let q = clampToImage(p)
            model.cropDraft = CGRect(x: min(start.x, q.x), y: min(start.y, q.y), width: abs(q.x - start.x), height: abs(q.y - start.y))
        case .cropMove(let startRect, let startPoint):
            var r = startRect.offsetBy(dx: p.x - startPoint.x, dy: p.y - startPoint.y)
            let full = model.fullRect
            r.origin.x = min(max(r.minX, full.minX), full.maxX - r.width)
            r.origin.y = min(max(r.minY, full.minY), full.maxY - r.height)
            model.cropDraft = r
        case .cropResize(let h, let startRect):
            let q = clampToImage(p)
            var minX = startRect.minX, minY = startRect.minY, maxX = startRect.maxX, maxY = startRect.maxY
            switch h {
            case .topLeft: minX = q.x; minY = q.y
            case .topRight: maxX = q.x; minY = q.y
            case .bottomLeft: minX = q.x; maxY = q.y
            case .bottomRight: maxX = q.x; maxY = q.y
            case .left: minX = q.x
            case .right: maxX = q.x
            case .top: minY = q.y
            case .bottom: maxY = q.y
            case .start, .end: break
            }
            model.cropDraft = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .creating(let id) = drag, let a = model.annotations.first(where: { $0.id == id }) {
            let tooSmall: Bool
            if a.kind.isLinear {
                tooSmall = hypot(a.end.x - a.start.x, a.end.y - a.start.y) < 3
            } else if a.kind.isBoxed {
                tooSmall = a.rect.width < 3 || a.rect.height < 3
            } else {
                tooSmall = false
            }
            if tooSmall {
                model.annotations.removeAll { $0.id == id }
                model.selectedID = nil
                model.dropLastCheckpoint()
            }
        }
        if case .cropNew = drag, model.cropDraft.width < 4 || model.cropDraft.height < 4 {
            model.resetCrop()
        }
        drag = .none
    }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        let f = model.fullRect
        return CGPoint(x: min(max(p.x, f.minX), f.maxX), y: min(max(p.y, f.minY), f.maxY))
    }

    private func constrained(_ p: CGPoint, from s: CGPoint, kind: AnnotationKind, shift: Bool) -> CGPoint {
        guard shift else { return p }
        let dx = p.x - s.x, dy = p.y - s.y
        if kind.isLinear {
            let angle = atan2(dy, dx)
            let step = CGFloat.pi / 4
            let snapped = (angle / step).rounded() * step
            let length = hypot(dx, dy)
            return CGPoint(x: s.x + cos(snapped) * length, y: s.y + sin(snapped) * length)
        }
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: s.x + (dx < 0 ? -side : side), y: s.y + (dy < 0 ? -side : side))
    }

    private func resize(_ a: inout Annotation, handle h: Handle, to p: CGPoint, shift: Bool) {
        switch h {
        case .start: a.start = constrained(p, from: a.end, kind: a.kind, shift: shift)
        case .end: a.end = constrained(p, from: a.start, kind: a.kind, shift: shift)
        default:
            let r = a.rect
            // Anchor is the opposite corner.
            let anchor: CGPoint
            switch h {
            case .topLeft: anchor = CGPoint(x: r.maxX, y: r.maxY)
            case .topRight: anchor = CGPoint(x: r.minX, y: r.maxY)
            case .bottomLeft: anchor = CGPoint(x: r.maxX, y: r.minY)
            default: anchor = CGPoint(x: r.minX, y: r.minY)
            }
            a.start = anchor
            a.end = constrained(p, from: anchor, kind: a.kind, shift: shift)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        let code = Int(event.keyCode)

        if model.isCropping {
            if code == kVK_Return || code == kVK_ANSI_KeypadEnter { model.applyCrop(); return }
            if code == kVK_Escape { model.cancelCrop(); return }
        }

        switch code {
        case kVK_Delete, kVK_ForwardDelete:
            model.deleteSelected()
            return
        case kVK_Escape:
            if model.selectedID != nil { model.selectedID = nil } else if model.tool != .select { model.tool = .select }
            return
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            guard let id = model.selectedID else { break }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let dx: CGFloat = code == kVK_LeftArrow ? -step : (code == kVK_RightArrow ? step : 0)
            let dy: CGFloat = code == kVK_UpArrow ? -step : (code == kVK_DownArrow ? step : 0)
            model.checkpoint()
            model.update(id) { $0.offset(dx: dx, dy: dy) }
            return
        case kVK_Return:
            if let sel = model.selected, sel.kind == .text {
                beginEditing(sel.id, isNew: false)
                return
            }
        default:
            break
        }

        if mods.isEmpty, let ch = event.charactersIgnoringModifiers?.lowercased().first,
           let tool = EditorTool.allCases.first(where: { $0.shortcut == ch }) {
            model.tool = tool
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Text editing

    private func beginEditing(_ id: UUID, isNew: Bool) {
        guard let a = model.annotations.first(where: { $0.id == id }) else { return }
        if !isNew { model.checkpoint() }
        editingIsNew = isNew
        originalText = a.text
        model.selectedID = id
        model.editingTextID = id

        let field = EditorTextField()
        field.annotationID = id
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = a.textStyle == .background
        field.backgroundColor = a.color.nsColor
        field.focusRingType = .none
        field.font = a.font
        field.textColor = a.textStyle == .background ? a.color.contrastingText : a.color.nsColor
        field.stringValue = a.text
        field.usesSingleLineMode = false
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        field.lineBreakMode = .byClipping
        field.delegate = self
        textField = field
        addSubview(field)
        layoutTextField()
        window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
        needsDisplay = true
    }

    private func layoutTextField() {
        guard let field = textField, let id = field.annotationID,
              let a = model.annotations.first(where: { $0.id == id }) else { return }
        let b = a.bounds
        let pad = Annotation.textPadding
        let size = a.textSize
        field.frame = CGRect(x: b.minX + pad.width - 2 - origin.x, y: b.minY + pad.height - origin.y,
                             width: size.width + max(40, a.fontSize * 2), height: size.height + 4)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField, let id = field.annotationID else { return }
        let text = field.stringValue
        model.update(id) { $0.text = text }
        layoutTextField()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitText()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) || selector == #selector(NSResponder.insertNewline(_:)) {
            commitText()
            return true
        }
        return false
    }

    /// Ends text editing. Returns true when a brand-new, empty text box was discarded
    /// (that already reverted the last undo step).
    @discardableResult
    func commitText() -> Bool {
        guard let field = textField else { return false }
        var discardedNew = false
        textField = nil
        let id = field.annotationID
        let text = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()
        model.editingTextID = nil
        if let id {
            let original = originalText
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.annotations.removeAll { $0.id == id }
                if model.selectedID == id { model.selectedID = nil }
                // A new text box left blank shouldn't leave an undo step behind.
                if editingIsNew {
                    model.dropLastCheckpoint()
                    discardedNew = true
                }
            } else {
                model.update(id) { $0.text = text }
                if !editingIsNew && text == original { model.dropLastCheckpoint() }
            }
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
        return discardedNew
    }
}

final class EditorTextField: NSTextField {
    var annotationID: UUID?
}
