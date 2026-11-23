import AppKit
import SwiftUI

/// The box Send opens once it knows the session: it names the session, shows what goes, and takes an optional message
/// to send with the screenshots. ↩ sends (with or without a message), ⌥↩ starts a new line, Esc or clicking away
/// cancels.
@MainActor
enum SendComposer {
    private static var panel: ComposerPanel?
    /// The open box's `done`, so a second Send (or clicking away) settles the first one as cancelled.
    private static var pending: (@MainActor (String?) -> Void)?
    /// Puts the keyboard back where it was before the box took it, for a cancel.
    private static var restore: (@MainActor () -> Void)?

    /// The app activation observers of the open box.
    private static var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Run once the box closes, whichever way.
    private static var closeObservers: [@MainActor () -> Void] = []

    /// Whether the box is up, so windows that close when they lose the keyboard (the stack) stay while it's open.
    static var isShowing: Bool { panel != nil }

    /// Runs `body` once the open box closes (right away when none is open), e.g. for the stack to look again at
    /// whether it should close too.
    static func afterClose(_ body: @escaping @MainActor () -> Void) {
        guard isShowing else { return body() }
        closeObservers.append(body)
    }

    /// Opens the box at the mouse. `done` gets the message (empty when none was typed), or nil when it was cancelled.
    /// `previousApp`: on cancel, give the front back to it (Send came from a glimpse:// link, not a Glimpse window).
    static func ask(title: String, detail: String, images: [CGImage], previousApp: NSRunningApplication?,
                    done: @escaping @MainActor (String?) -> Void) {
        finish(nil, refocus: false)
        let previousKey = NSApp.keyWindow
        pending = done
        restore = {
            if let previousApp {
                previousApp.activate()
            } else if let previousKey, previousKey.isVisible {
                previousKey.makeKey()
            }
        }

        let view = SendComposerView(title: title, detail: detail, images: images,
                                    send: { finish($0, refocus: true) }, cancel: { finish(nil, refocus: true) })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let p = ComposerPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // Above the stack and the thumbnails (status bar level), which Send is often pressed in.
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        // A panel hides while its app isn't active, and Glimpse may not get to come forward (see below).
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.onCancel = { finish(nil, refocus: true) }
        p.onResignKey = { finish(nil, refocus: false) }
        // Glimpse is often not the active app when Send is pressed (the stack and the thumbnails leave the app you were
        // in at the front). The box can be key before Glimpse comes forward and lose it on the way: take it back.
        // Clicking into another app puts the box away, like clicking off a menu: Glimpse resigning active covers it when
        // it came forward, another app activating when it didn't.
        let center = NotificationCenter.default
        observers = [
            (center, center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { panel?.makeKeyAndOrderFront(nil) }
            }),
            (center, center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { finish(nil, refocus: false) }
            }),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.processIdentifier != getpid() else { return }
                MainActor.assumeIsolated { finish(nil, refocus: false) }
            }),
        ]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        host.frame = background.bounds
        host.autoresizingMask = [.width, .height]
        background.addSubview(host)
        p.contentView = background
        p.setFrameOrigin(origin(for: size))
        panel = p

        // Typing needs Glimpse active (the stack and thumbnails leave another app in front).
        // Shown whether or not Glimpse gets to come forward (macOS can turn that down); it becomes key once it does.
        NSApp.activate(ignoringOtherApps: true)
        p.orderFrontRegardless()
        p.makeKey()
    }

    /// Closes the box and reports `message` (nil: cancelled). `refocus`: on cancel, put the keyboard back where it was;
    /// not when the box lost it to another window or app, which should keep it.
    private static func finish(_ message: String?, refocus: Bool) {
        guard let p = panel, let done = pending else { return }
        let restore = restore
        panel = nil
        pending = nil
        Self.restore = nil
        p.onResignKey = nil
        observers.forEach { center, observer in center.removeObserver(observer) }
        observers = []
        p.orderOut(nil)
        if message == nil, refocus { restore?() }
        done(message?.trimmingCharacters(in: .whitespacesAndNewlines))
        let observers = closeObservers
        closeObservers = []
        observers.forEach { $0() }
    }

    /// Just below and to the right of the pointer, kept on its screen.
    private static func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x - 24, y: mouse.y - size.height - 12)
        if let vf = screen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
            origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        }
        return origin
    }
}

private final class ComposerPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func resignKey() {
        super.resignKey()
        // Clicking another of Glimpse's windows puts the box away, as clicking off a menu does (another app: see
        // didResignActive). Not when no window took the keyboard: that's Glimpse coming forward, which hands it back.
        // Async: the click's own handling (a button in the window behind) runs first.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isKeyWindow, NSApp.isActive, let key = NSApp.keyWindow, key !== self else { return }
            self.onResignKey?()
        }
    }
}

private struct SendComposerView: View {
    let title: String
    let detail: String
    let images: [CGImage]
    let send: (String) -> Void
    let cancel: () -> Void

    @State private var message = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send to \(title)")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.tail)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                thumbnails
            }
            TextField("Add a message (optional)", text: $message, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(3...8)
                .focused($focused)
                .onSubmit { send(message) }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor).opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
            HStack(spacing: 8) {
                Text("⌥↩ new line")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Send") { send(message) }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 400)
        .onAppear { focused = true }
    }

    /// The screenshots going, overlapping like a little stack (at most three shown).
    private var thumbnails: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(images.prefix(3).enumerated().reversed()), id: \.offset) { index, image in
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 52, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
                    .offset(x: CGFloat(index) * 5, y: CGFloat(index) * 4)
            }
        }
        .frame(width: 52 + CGFloat(min(images.count, 3) - 1) * 5, height: 36 + CGFloat(min(images.count, 3) - 1) * 4,
               alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) {
            if images.count > 1 {
                Text("\(images.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor))
                    .offset(x: 4, y: 4)
            }
        }
    }
}
