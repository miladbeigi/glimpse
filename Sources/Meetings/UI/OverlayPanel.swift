import AppKit
import SwiftUI

/// Borderless, non-activating, always-on-top panel on all Spaces. Never steals focus.
final class OverlayPanel: NSPanel {
    init(level: NSWindow.Level = .statusBar) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        self.level = level
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Host a SwiftUI view, sized to its ideal size for the given width.
    func host<V: View>(_ view: V, width: CGFloat) -> NSSize {
        let hosting = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
        hosting.layer?.backgroundColor = .clear
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        contentView = hosting
        return size
    }
}

/// The screen holding the mouse pointer.
func activeScreen() -> NSScreen {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
}
