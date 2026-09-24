import AppKit
import Combine

enum EditorTool: String, CaseIterable, Identifiable {
    case select, arrow, line, rectangle, filledRectangle, ellipse, pen, highlighter, text, counter, pixelate, blur, spotlight, crop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .filledRectangle: return "Filled Rectangle"
        case .ellipse: return "Ellipse"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .text: return "Text"
        case .counter: return "Counter"
        case .pixelate: return "Pixelate"
        case .blur: return "Blur"
        case .spotlight: return "Spotlight"
        case .crop: return "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .filledRectangle: return "rectangle.fill"
        case .ellipse: return "circle"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .pixelate: return "checkerboard.rectangle"
        case .blur: return "drop.fill"
        case .spotlight: return "flashlight.on.fill"
        case .crop: return "crop"
        }
    }

    var shortcut: Character {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .line: return "l"
        case .rectangle: return "r"
        case .filledRectangle: return "f"
        case .ellipse: return "o"
        case .pen: return "p"
        case .highlighter: return "h"
        case .text: return "t"
        case .counter: return "n"
        case .pixelate: return "x"
        case .blur: return "b"
        case .spotlight: return "s"
        case .crop: return "c"
        }
    }

    var kind: AnnotationKind? {
        switch self {
        case .select, .crop: return nil
        case .arrow: return .arrow
        case .line: return .line
        case .rectangle: return .rectangle
        case .filledRectangle: return .filledRectangle
        case .ellipse: return .ellipse
        case .pen: return .pen
        case .highlighter: return .highlighter
        case .text: return .text
        case .counter: return .counter
        case .pixelate: return .pixelate
        case .blur: return .blur
        case .spotlight: return .spotlight
        }
    }

    /// Tools whose look depends on colour.
    var usesColor: Bool { ![.pixelate, .blur, .spotlight, .crop].contains(self) }
    var usesLineWidth: Bool { [.arrow, .line, .rectangle, .ellipse, .pen, .highlighter, .counter].contains(self) }
}

@MainActor
final class EditorModel: ObservableObject {
    let baseImage: CGImage
    let scale: CGFloat
    let imageSize: CGSize

    @Published var annotations: [Annotation] = []
    @Published var cropRect: CGRect
    @Published var outputScale: CGFloat = 1

    @Published var tool: EditorTool = .arrow {
        didSet {
            if tool != oldValue {
                if oldValue == .crop { cancelCrop() }
                if tool == .crop { beginCrop() }
                if tool != .select { selectedID = nil }
            }
        }
    }
    @Published var color: RGBA
    @Published var lineWidth: CGFloat
    @Published var fontSize: CGFloat
    @Published var textStyle: TextStyle
    @Published var selectedID: UUID?
    @Published var editingTextID: UUID?

    @Published private(set) var isCropping = false
    @Published var cropDraft: CGRect = .zero
    @Published var magnification: CGFloat = 1

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var undoStack: [EditorDocumentState] = []
    private var redoStack: [EditorDocumentState] = []
    private let initialState: EditorDocumentState

    private(set) lazy var pixelatedImage: CGImage? = Renderer.pixelated(baseImage, scale: scale)
    private(set) lazy var blurredImage: CGImage? = Renderer.blurred(baseImage, scale: scale)

    /// Hooks for the window controller (actions that need AppKit context).
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onPin: (() -> Void)?
    var onDone: (() -> Void)?
    var onZoom: ((ZoomAction) -> Void)?
    /// Set by the canvas: finishes in-progress text editing before undo/redo.
    var commitPendingEdits: (() -> Bool)?

    enum ZoomAction { case zoomIn, zoomOut, fit, actual }

    init(image: CGImage, scale: CGFloat, state: EditorDocumentState?) {
        baseImage = image
        self.scale = scale
        imageSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let full = CGRect(origin: .zero, size: imageSize)
        let initial = state ?? EditorDocumentState(annotations: [], cropRect: full, outputScale: 1)
        initialState = initial
        annotations = initial.annotations
        cropRect = initial.cropRect
        outputScale = initial.outputScale

        let prefs = Preferences.shared
        color = prefs.editorColor
        lineWidth = prefs.editorLineWidth
        fontSize = prefs.editorFontSize
        textStyle = prefs.editorTextStyle
    }

    var state: EditorDocumentState {
        EditorDocumentState(annotations: annotations, cropRect: cropRect, outputScale: outputScale)
    }

    var hasChanges: Bool { state != initialState }

    var fullRect: CGRect { CGRect(origin: .zero, size: imageSize) }

    /// The part of the image the canvas shows (whole image while cropping).
    var displayRect: CGRect { isCropping ? fullRect : cropRect }

    var outputPixelSize: CGSize {
        CGSize(width: (cropRect.width * scale * outputScale).rounded(), height: (cropRect.height * scale * outputScale).rounded())
    }

    var selected: Annotation? {
        guard let id = selectedID else { return nil }
        return annotations.first { $0.id == id }
    }

    // MARK: Undo

    func checkpoint() {
        undoStack.append(state)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        updateUndoFlags()
    }

    /// Forgets the most recent checkpoint (when an action turned out to be a no-op).
    func dropLastCheckpoint() {
        _ = undoStack.popLast()
        updateUndoFlags()
    }

    func undo() {
        if commitPendingEdits?() == true { return }
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        apply(previous)
    }

    func redo() {
        _ = commitPendingEdits?()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        apply(next)
    }

    private func apply(_ s: EditorDocumentState) {
        annotations = s.annotations
        cropRect = s.cropRect
        outputScale = s.outputScale
        if let id = selectedID, !annotations.contains(where: { $0.id == id }) { selectedID = nil }
        editingTextID = nil
        updateUndoFlags()
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: Annotation editing

    func index(of id: UUID) -> Int? { annotations.firstIndex { $0.id == id } }

    func update(_ id: UUID, _ change: (inout Annotation) -> Void) {
        guard let i = index(of: id) else { return }
        change(&annotations[i])
    }

    func add(_ a: Annotation) {
        annotations.append(a)
    }

    func deleteSelected() {
        guard let id = selectedID, let i = index(of: id) else { return }
        checkpoint()
        annotations.remove(at: i)
        selectedID = nil
    }

    func bringSelectedToFront() {
        guard let id = selectedID, let i = index(of: id) else { return }
        checkpoint()
        let a = annotations.remove(at: i)
        annotations.append(a)
    }

    func duplicateSelected() {
        guard var copy = selected else { return }
        checkpoint()
        copy.id = UUID()
        copy.offset(dx: 16, dy: 16)
        annotations.append(copy)
        selectedID = copy.id
    }

    private var lastStyleChange: (id: UUID, time: Date)?

    /// Continuous style edits (e.g. dragging in the colour panel) collapse into one undo step.
    private func styleCheckpoint(for id: UUID) {
        if let last = lastStyleChange, last.id == id, Date().timeIntervalSince(last.time) < 1 {
            lastStyleChange = (id, Date())
            return
        }
        checkpoint()
        lastStyleChange = (id, Date())
    }

    func setColor(_ c: RGBA) {
        color = c
        Preferences.shared.editorColor = c
        if let id = selectedID, let a = selected, a.color != c, a.kind != .pixelate, a.kind != .blur, a.kind != .spotlight {
            styleCheckpoint(for: id)
            update(id) { $0.color = c }
        }
    }

    func setLineWidth(_ w: CGFloat) {
        lineWidth = w
        Preferences.shared.editorLineWidth = w
        if let id = selectedID, let a = selected, a.lineWidth != w {
            styleCheckpoint(for: id)
            update(id) { $0.lineWidth = w }
        }
    }

    func setFontSize(_ s: CGFloat) {
        fontSize = s
        Preferences.shared.editorFontSize = s
        if let id = selectedID, let a = selected, a.kind == .text, a.fontSize != s {
            styleCheckpoint(for: id)
            update(id) { $0.fontSize = s }
        }
    }

    func setTextStyle(_ s: TextStyle) {
        textStyle = s
        Preferences.shared.editorTextStyle = s
        if let id = selectedID, let a = selected, a.kind == .text, a.textStyle != s {
            styleCheckpoint(for: id)
            update(id) { $0.textStyle = s }
        }
    }

    /// Reflects the selected annotation's style in the toolbar.
    func adoptStyle(of a: Annotation) {
        if !a.kind.isRedaction && a.kind != .spotlight { color = a.color }
        lineWidth = a.lineWidth
        if a.kind == .text {
            fontSize = a.fontSize
            textStyle = a.textStyle
        }
    }

    // MARK: Crop

    private func beginCrop() {
        isCropping = true
        cropDraft = cropRect
        selectedID = nil
        editingTextID = nil
    }

    func applyCrop() {
        guard isCropping else { return }
        // Snap to the pixel grid (not .integral, which would grow the rect).
        let c = cropDraft.intersection(fullRect)
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let r = CGRect(x: snap(c.minX), y: snap(c.minY), width: snap(c.width), height: snap(c.height)).intersection(fullRect)
        if r.width >= 4, r.height >= 4, r != cropRect {
            checkpoint()
            cropRect = r
        }
        isCropping = false
        tool = .select
    }

    func cancelCrop() {
        guard isCropping else { return }
        isCropping = false
        if tool == .crop { tool = .select }
    }

    func resetCrop() {
        cropDraft = fullRect
    }

    // MARK: Resize

    func setOutputScale(_ s: CGFloat) {
        let clamped = min(max(s, 0.05), 4)
        guard abs(clamped - outputScale) > 0.0001 else { return }
        checkpoint()
        outputScale = clamped
    }

    // MARK: Export

    func render() -> CGImage? {
        Renderer.export(base: baseImage, scale: scale, state: state,
                        pixelated: needsPixelated ? pixelatedImage : nil,
                        blurred: needsBlurred ? blurredImage : nil)
    }

    var needsPixelated: Bool { annotations.contains { $0.kind == .pixelate } }
    var needsBlurred: Bool { annotations.contains { $0.kind == .blur } }
}
