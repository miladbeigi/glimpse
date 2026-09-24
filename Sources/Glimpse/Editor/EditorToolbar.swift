import AppKit
import SwiftUI

struct EditorTopBar: View {
    @ObservedObject var model: EditorModel

    private let toolGroups: [[EditorTool]] = [
        [.select],
        [.arrow, .line, .rectangle, .filledRectangle, .ellipse],
        [.pen, .highlighter, .text, .counter],
        [.pixelate, .blur, .spotlight],
        [.crop],
    ]
    private let widths: [CGFloat] = [2, 4, 6, 10, 16]
    private let fontSizes: [CGFloat] = [14, 18, 24, 32, 48, 64, 96]

    private var styleTarget: Annotation? { model.selected }
    private var showsText: Bool { model.tool == .text || styleTarget?.kind == .text }
    private var showsWidth: Bool {
        if let k = styleTarget?.kind { return [.arrow, .line, .rectangle, .ellipse, .pen, .highlighter, .counter].contains(k) }
        return model.tool.usesLineWidth
    }
    private var showsColor: Bool {
        if let k = styleTarget?.kind { return !k.isRedaction && k != .spotlight }
        return model.tool.usesColor
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(toolGroups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider().frame(height: 22) }
                HStack(spacing: 2) {
                    ForEach(group) { tool in
                        ToolButton(tool: tool, selected: model.tool == tool) { model.tool = tool }
                    }
                }
            }
            Divider().frame(height: 22)
            if model.isCropping {
                cropControls
            } else {
                styleControls
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(.bar)
    }

    @ViewBuilder
    private var styleControls: some View {
        if showsColor {
            HStack(spacing: 5) {
                ForEach(RGBA.presets, id: \.self) { c in
                    Button { model.setColor(c) } label: {
                        Circle()
                            .fill(Color(nsColor: c.nsColor))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
                            .padding(2)
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: model.color == c ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                }
                ColorPicker("", selection: Binding(
                    get: { model.color.cgColor },
                    set: { model.setColor(RGBA(NSColor(cgColor: $0) ?? .red)) }), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 26)
                    .help("Custom colour")
                Button {
                    NSColorSampler().show { color in
                        guard let color else { return }
                        let rgba = RGBA(color)
                        Task { @MainActor in model.setColor(rgba) }
                    }
                } label: {
                    Image(systemName: "eyedropper")
                }
                .buttonStyle(.borderless)
                .help("Pick a colour from the screen")
            }
        }
        if showsWidth {
            Divider().frame(height: 22)
            HStack(spacing: 2) {
                ForEach(widths, id: \.self) { w in
                    Button { model.setLineWidth(w) } label: {
                        Circle()
                            .fill(Color.primary)
                            .frame(width: 3 + w * 0.7, height: 3 + w * 0.7)
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(model.lineWidth == w ? Color.accentColor.opacity(0.25) : .clear))
                    }
                    .buttonStyle(.plain)
                    .help("Stroke \(Int(w)) pt")
                }
            }
        }
        if showsText {
            Divider().frame(height: 22)
            Picker("", selection: Binding(get: { model.fontSize }, set: { model.setFontSize($0) })) {
                ForEach(fontSizes, id: \.self) { s in Text("\(Int(s)) pt").tag(s) }
            }
            .labelsHidden()
            .frame(width: 74)
            Picker("", selection: Binding(get: { model.textStyle }, set: { model.setTextStyle($0) })) {
                ForEach(TextStyle.allCases) { s in Text(s.title).tag(s) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 210)
        }
    }

    @ViewBuilder
    private var cropControls: some View {
        Text("\(Int((model.cropDraft.width * model.scale).rounded())) × \(Int((model.cropDraft.height * model.scale).rounded())) px")
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(.secondary)
        Button("Reset") { model.resetCrop() }
        Button("Cancel") { model.cancelCrop() }
            .keyboardShortcut(.cancelAction)
        Button("Apply Crop") { model.applyCrop() }
            .buttonStyle(.borderedProminent)
    }
}

private struct ToolButton: View {
    let tool: EditorTool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : .clear))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(tool.title) (\(String(tool.shortcut).uppercased()))")
    }
}

struct EditorBottomBar: View {
    @ObservedObject var model: EditorModel
    let makeDragFile: () -> URL?
    @State private var showResize = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Button { model.onZoom?(.zoomOut) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom Out (⌘−)")
                Button { model.onZoom?(.fit) } label: {
                    Text("\(Int((model.magnification * 100).rounded()))%")
                        .font(.system(size: 11).monospacedDigit())
                        .frame(minWidth: 40)
                }
                .help("Zoom to Fit (⌘0)")
                Button { model.onZoom?(.zoomIn) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom In (⌘+)")
            }
            .buttonStyle(.borderless)

            Text("\(Int(model.outputPixelSize.width)) × \(Int(model.outputPixelSize.height)) px")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)

            Button { showResize.toggle() } label: { Label("Resize", systemImage: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.borderless)
                .popover(isPresented: $showResize, arrowEdge: .top) { ResizePopover(model: model) }

            HStack(spacing: 2) {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.canUndo).help("Undo (⌘Z)")
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!model.canRedo).help("Redo (⇧⌘Z)")
            }
            .buttonStyle(.borderless)

            Spacer(minLength: 8)

            DragHandle(makeFile: makeDragFile)
                .frame(width: 30, height: 26)
                .help("Drag the image into another app")

            Button { model.onPin?() } label: { Label("Pin", systemImage: "pin") }
            Button { model.onCopy?() } label: { Label("Copy", systemImage: "doc.on.doc") }
            Button { model.onSave?() } label: { Label("Save", systemImage: "square.and.arrow.down") }
            Button("Done") { model.onDone?() }
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.bar)
    }
}

private struct ResizePopover: View {
    @ObservedObject var model: EditorModel
    @State private var width: String = ""
    @State private var height: String = ""

    private var baseSize: CGSize {
        CGSize(width: model.cropRect.width * model.scale, height: model.cropRect.height * model.scale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Resize Image").font(.headline)
            HStack {
                TextField("Width", text: $width)
                    .frame(width: 80)
                    .onSubmit(applyWidth)
                Text("×")
                TextField("Height", text: $height)
                    .frame(width: 80)
                    .onSubmit(applyHeight)
                Text("px").foregroundStyle(.secondary)
            }
            HStack {
                ForEach([25, 50, 75, 100, 200], id: \.self) { pct in
                    Button("\(pct)%") {
                        model.setOutputScale(CGFloat(pct) / 100)
                        sync()
                    }
                }
            }
            HStack {
                Text("Aspect ratio is kept").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Apply") { applyWidth() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .onAppear(perform: sync)
    }

    private func sync() {
        width = "\(Int(model.outputPixelSize.width))"
        height = "\(Int(model.outputPixelSize.height))"
    }

    private func applyWidth() {
        guard let w = Double(width), w > 0, baseSize.width > 0 else { return sync() }
        model.setOutputScale(CGFloat(w) / baseSize.width)
        sync()
    }

    private func applyHeight() {
        guard let h = Double(height), h > 0, baseSize.height > 0 else { return sync() }
        model.setOutputScale(CGFloat(h) / baseSize.height)
        sync()
    }
}

/// A small grip that starts a file drag of the rendered image.
struct DragHandle: NSViewRepresentable {
    let makeFile: () -> URL?

    func makeNSView(context: Context) -> DragHandleView {
        let v = DragHandleView()
        v.makeFile = makeFile
        return v
    }

    func updateNSView(_ nsView: DragHandleView, context: Context) {
        nsView.makeFile = makeFile
    }
}

final class DragHandleView: NSView, NSDraggingSource {
    var makeFile: (() -> URL?)?
    private var downPoint: NSPoint?

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        if let img = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "Drag")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) {
            let tinted = img.tinted(.secondaryLabelColor)
            let s = tinted.size
            tinted.draw(in: NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2, width: s.width, height: s.height))
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) { downPoint = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 3, let url = makeFile?() else { return }
        downPoint = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let preview = NSImage(contentsOf: url) ?? NSImage()
        let aspect = preview.size.height / max(preview.size.width, 1)
        let w: CGFloat = 160
        item.setDraggingFrame(NSRect(x: 0, y: 0, width: w, height: w * aspect), contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = copy() as! NSImage
        image.lockFocus()
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
