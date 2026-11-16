import AppKit
import SwiftUI

public extension View {
    /// Drags the view's window with the pointer. Floating panels that host SwiftUI can't rely on
    /// `isMovableByWindowBackground` or `performDrag`: the hosting view takes the mouse-down first, so AppKit never
    /// starts a window drag. This follows the pointer in screen coordinates instead. Buttons inside keep working.
    func movesWindowOnDrag() -> some View {
        modifier(MovesWindowOnDrag())
    }
}

private struct MovesWindowOnDrag: ViewModifier {
    @State private var anchor = WindowAnchor()
    @State private var start: (mouse: NSPoint, origin: NSPoint)?

    func body(content: Content) -> some View {
        content
            .background(WindowAnchorView(anchor: anchor))
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { _ in
                        guard let window = anchor.view?.window else { return }
                        let mouse = NSEvent.mouseLocation
                        if start == nil { start = (mouse, window.frame.origin) }
                        guard let start else { return }
                        window.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                                      y: start.origin.y + mouse.y - start.mouse.y))
                    }
                    .onEnded { _ in start = nil }
            )
    }
}

/// Holds an empty view inside the hosted content, to find its window when a drag starts.
private final class WindowAnchor {
    weak var view: NSView?
}

private struct WindowAnchorView: NSViewRepresentable {
    let anchor: WindowAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}
