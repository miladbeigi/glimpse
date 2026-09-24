import AppKit
import Carbon.HIToolbox

/// A key + Carbon modifier mask, as used by RegisterEventHotKey.
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let optShiftCmd = UInt32(optionKey | shiftKey | cmdKey)

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let mods = KeyCombo.carbonModifiers(from: event.modifierFlags)
        let code = UInt32(event.keyCode)
        let isFunctionKey = KeyCombo.functionKeyCodes.contains(Int(code))
        // Require a "real" modifier unless it's an F-key, so plain typing can't become a global shortcut.
        let hasPrimary = mods & UInt32(cmdKey | controlKey | optionKey) != 0
        guard hasPrimary || isFunctionKey else { return nil }
        self.init(keyCode: code, modifiers: mods)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        return f
    }

    var modifierSymbols: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }

    var keyName: String { KeyCombo.name(forKeyCode: keyCode) }
    var displayString: String { modifierSymbols + keyName }

    /// Character usable as an NSMenuItem key equivalent (for display in menus), if any.
    var menuKeyEquivalent: String? {
        let name = keyName
        guard name.count == 1, let ch = name.first, ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isSymbol else { return nil }
        return name.lowercased()
    }

    static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let specialNames: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_Help: "?⃝",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
        kVK_ANSI_Keypad0: "Num0", kVK_ANSI_Keypad1: "Num1", kVK_ANSI_Keypad2: "Num2", kVK_ANSI_Keypad3: "Num3",
        kVK_ANSI_Keypad4: "Num4", kVK_ANSI_Keypad5: "Num5", kVK_ANSI_Keypad6: "Num6", kVK_ANSI_Keypad7: "Num7",
        kVK_ANSI_Keypad8: "Num8", kVK_ANSI_Keypad9: "Num9",
    ]

    private static let ansiFallback: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
    ]

    static func name(forKeyCode keyCode: UInt32) -> String {
        if let special = specialNames[Int(keyCode)] { return special }
        if let translated = translate(keyCode), !translated.isEmpty { return translated.uppercased() }
        return ansiFallback[Int(keyCode)] ?? "#\(keyCode)"
    }

    private static func translate(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case captureArea, captureFullscreen, captureWindow, scrollingCapture, capturePreviousArea,
         selfTimer, captureText, restoreRecent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureArea: return "Capture Area"
        case .captureFullscreen: return "Capture Fullscreen"
        case .captureWindow: return "Capture Window"
        case .scrollingCapture: return "Scrolling Capture"
        case .capturePreviousArea: return "Capture Previous Area"
        case .selfTimer: return "Self-Timer (Area)"
        case .captureText: return "Capture Text (OCR)"
        case .restoreRecent: return "Restore Recently Closed"
        }
    }

    var defaultCombo: KeyCombo? {
        let m = KeyCombo.optShiftCmd
        switch self {
        case .captureArea: return KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: m)
        case .captureFullscreen: return KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: m)
        case .captureWindow: return KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: m)
        case .scrollingCapture: return KeyCombo(keyCode: UInt32(kVK_ANSI_6), modifiers: m)
        case .capturePreviousArea: return KeyCombo(keyCode: UInt32(kVK_ANSI_7), modifiers: m)
        case .selfTimer: return KeyCombo(keyCode: UInt32(kVK_ANSI_8), modifiers: m)
        case .captureText: return KeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: m)
        case .restoreRecent: return KeyCombo(keyCode: UInt32(kVK_ANSI_9), modifiers: m)
        }
    }
}

private func hotKeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let id = hotKeyID.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated { HotkeyManager.shared.fire(id: id) }
    }
    return noErr
}

/// Registers global shortcuts through Carbon (no Accessibility permission needed).
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    var handler: ((HotkeyAction) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var suspendCount = 0
    /// Actions whose shortcut could not be registered (already taken by another app).
    private(set) var failed: Set<HotkeyAction> = []

    private static let signature: OSType = {
        var result: OSType = 0
        for ch in "GLMP".utf8 { result = (result << 8) | OSType(ch) }
        return result
    }()

    func install() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, &eventHandler)
        registerAll()
    }

    func registerAll() {
        unregisterAll()
        guard suspendCount == 0 else { return }
        failed = []
        for (index, action) in HotkeyAction.allCases.enumerated() {
            guard let combo = Preferences.shared.shortcuts[action] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: HotkeyManager.signature, id: UInt32(index))
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
            } else {
                failed.insert(action)
                NSLog("Glimpse: could not register shortcut \(combo.displayString) for \(action.title) (\(status))")
            }
        }
    }

    private func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    /// Temporarily disables all shortcuts (while the shortcut recorder is active).
    func suspend() {
        suspendCount += 1
        unregisterAll()
    }

    func resume() {
        suspendCount = max(0, suspendCount - 1)
        registerAll()
    }

    fileprivate func fire(id: UInt32) {
        let all = HotkeyAction.allCases
        guard Int(id) < all.count else { return }
        handler?(all[Int(id)])
    }
}

// MARK: - Shortcut recorder

/// Click to record; press a combination to set it, ⌫ to clear, Esc to cancel.
final class ShortcutRecorderView: NSView {
    var combo: KeyCombo? { didSet { needsDisplay = true } }
    var onChange: ((KeyCombo?) -> Void)?
    private var recording = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

    override func mouseDown(with event: NSEvent) {
        if recording {
            stopRecording()
        } else {
            recording = true
            HotkeyManager.shared.suspend()
            window?.makeFirstResponder(self)
        }
    }

    private func stopRecording() {
        guard recording else { return }
        recording = false
        HotkeyManager.shared.resume()
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        handle(event)
    }

    private func handle(_ event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if plain && Int(event.keyCode) == kVK_Escape {
            stopRecording()
            return
        }
        if plain && (Int(event.keyCode) == kVK_Delete || Int(event.keyCode) == kVK_ForwardDelete) {
            // Order matters: resume() re-registers shortcuts, so update the preference first.
            recording = false
            combo = nil
            onChange?(nil)
            HotkeyManager.shared.resume()
            return
        }
        guard let newCombo = KeyCombo(event: event) else {
            NSSound.beep()
            return
        }
        recording = false
        combo = newCombo
        onChange?(newCombo)
        HotkeyManager.shared.resume()
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()

        let text: String
        let color: NSColor
        if recording {
            text = "Type shortcut…"
            color = .controlAccentColor
        } else if let combo {
            text = combo.displayString
            color = .labelColor
        } else {
            text = "Click to record"
            color = .tertiaryLabelColor
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
}
