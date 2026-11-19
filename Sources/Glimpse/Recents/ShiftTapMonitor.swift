import AppKit
import Carbon.HIToolbox

/// Double-tapping the right Shift key (alone, within a moment) toggles the recent screenshots stack.
/// Watching keys in other apps needs the Accessibility permission, which scrolling capture already asks for.
@MainActor
final class ShiftTapMonitor {
    static let shared = ShiftTapMonitor()

    private var monitors: [Any] = []
    private var detector = DoubleTapDetector()

    func refresh() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        guard Preferences.shared.doubleShiftShowsRecent else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { ShiftTapMonitor.shared.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { ShiftTapMonitor.shared.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    static var hasPermission: Bool { AXIsProcessTrusted() }

    private func handle(_ event: NSEvent) {
        let fired: Bool
        switch event.type {
        case .flagsChanged:
            let rightShiftDown = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            let others = event.modifierFlags.intersection([.command, .option, .control, .function])
            let leftShiftDown = event.modifierFlags.rawValue & UInt(NX_DEVICELSHIFTKEYMASK) != 0
            if Int(event.keyCode) == kVK_RightShift {
                fired = detector.rightShift(down: rightShiftDown, clean: others.isEmpty && !leftShiftDown,
                                            at: event.timestamp)
            } else {
                detector.reset()
                fired = false
            }
        default:
            detector.reset()
            fired = false
        }
        if fired { RecentStackController.shared.toggle() }
    }
}

/// The timing rule, separate so it can be tested: press, release, press again within `window` seconds, each press
/// short, with nothing else in between.
struct DoubleTapDetector {
    var window: TimeInterval = 0.4
    var maxHold: TimeInterval = 0.3
    private var lastTapEnd: TimeInterval?
    private var pressStart: TimeInterval?
    private var taps = 0

    mutating func reset() {
        lastTapEnd = nil
        pressStart = nil
        taps = 0
    }

    /// Returns true on the second tap's press.
    mutating func rightShift(down: Bool, clean: Bool, at time: TimeInterval) -> Bool {
        guard clean else { reset(); return false }
        if down {
            if let end = lastTapEnd, time - end <= window, taps == 1 {
                reset()
                return true
            }
            if let end = lastTapEnd, time - end > window { reset() }
            pressStart = time
            return false
        }
        guard let start = pressStart else { return false }
        pressStart = nil
        if time - start > maxHold { reset(); return false }
        taps = 1
        lastTapEnd = time
        return false
    }
}
