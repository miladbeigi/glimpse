import AppKit
import SwiftUI

/// Owns the meetings window (transcript history). Settings live in Glimpse's settings window.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var historyWindow: NSWindow?

    func showHistory() {
        if historyWindow == nil {
            historyWindow = makeWindow(title: "Transcription History", size: NSSize(width: 1020, height: 660),
                                       view: HistoryView().environmentObject(AppState.shared), resizable: true)
        }
        present(historyWindow)
    }

    func closeAll() {
        historyWindow?.close()
    }

    private func makeWindow<V: View>(title: String, size: NSSize, view: V, resizable: Bool = false) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
