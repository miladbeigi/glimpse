import Carbon.HIToolbox
import Foundation

/// A system-wide keyboard shortcut via Carbon's `RegisterEventHotKey`, which needs no
/// Accessibility permission.
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextId: UInt32 = 1
    private static var eventHandlerInstalled = false
    private let id: UInt32
    /// 'GMTG'. Other shortcut handlers in the app (Glimpse's own) use their own signature.
    private static let signature = OSType(0x474D5447)

    /// - Parameters:
    ///   - keyCode: virtual key code (e.g. `kVK_ANSI_M`)
    ///   - modifiers: Carbon modifier mask (e.g. `controlKey | optionKey`)
    init?(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        Self.installEventHandler()
        id = Self.nextId
        Self.nextId += 1
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        Self.handlers[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installEventHandler() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            // Every hotkey handler on the app target sees every hotkey; pass on the ones that aren't ours.
            guard status == noErr, hotKeyID.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
            let handler = GlobalHotKey.handlers[hotKeyID.id]
            DispatchQueue.main.async { handler?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
