import Combine
import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static var shared: SettingsWindowController?

    static var isVisible: Bool { shared?.window?.isVisible == true }

    static func show() {
        if shared == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Glimpse Settings"
            window.isReleasedWhenClosed = false
            // A SwiftUI TabView hosted in a plain NSWindow gets its tabs pushed into an unconfigured toolbar,
            // which collapses them into the » overflow button. Use a real preferences-style toolbar instead.
            window.toolbarStyle = .preference
            window.contentViewController = SettingsTabController()
            window.center()
            let controller = SettingsWindowController(window: window)
            window.delegate = controller
            shared = controller
        }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
        AppDelegate.refreshActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { AppDelegate.refreshActivationPolicy() }
    }
}

private final class SettingsTabController: NSTabViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar
        addTab("General", "gearshape", GeneralSettings())
        addTab("Capture", "camera.viewfinder", CaptureSettings())
        addTab("Quick Access", "rectangle.on.rectangle", OverlaySettings())
        addTab("Shortcuts", "keyboard", ShortcutSettings())
        addTab("Permissions", "lock.shield", PermissionSettings())
    }

    private func addTab(_ label: String, _ symbol: String, _ view: some View) {
        let item = NSTabViewItem(viewController: NSHostingController(rootView: view.frame(width: 560, height: 540)))
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        addTabViewItem(item)
    }
}

private struct GeneralSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { value in
                    do {
                        if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        NSAlert(error: error).runModal()
                    }
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }))
                Toggle("Play sound", isOn: $prefs.playSound)
            }
            Section("After capture") {
                Toggle("Show Quick Access Overlay", isOn: $prefs.showOverlay)
                Toggle("Copy to clipboard", isOn: $prefs.copyToClipboard)
                Toggle("Save to disk automatically", isOn: $prefs.autoSave)
                Toggle("Open annotation editor", isOn: $prefs.openEditorAfterCapture)
            }
            Section("Saving") {
                HStack {
                    Text("Save to")
                    Spacer()
                    Text(prefs.saveDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…", action: chooseFolder)
                }
                Picker("Format", selection: $prefs.imageFormat) {
                    ForEach(ImageFormat.allCases) { Text($0.title).tag($0) }
                }
                if prefs.imageFormat == .jpeg {
                    HStack {
                        Text("JPEG quality")
                        Slider(value: $prefs.jpegQuality, in: 0.3...1)
                        Text("\(Int(prefs.jpegQuality * 100))%").monospacedDigit().frame(width: 40)
                    }
                }
                Toggle("Save and copy Retina screenshots at 1×", isOn: $prefs.saveAt1x)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.saveDirectory
        if panel.runModal() == .OK, let url = panel.url {
            prefs.saveDirectory = url
        }
    }
}

private struct CaptureSettings: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Area selection") {
                Toggle("Show crosshair", isOn: $prefs.showCrosshair)
                Toggle("Show magnifier", isOn: $prefs.showMagnifier)
            }
            Section("Window capture") {
                Toggle("Add window shadow", isOn: $prefs.windowShadow)
            }
            Section("Self-timer") {
                Picker("Countdown", selection: $prefs.selfTimerSeconds) {
                    ForEach([3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct OverlaySettings: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                Picker("Position", selection: $prefs.overlayCorner) {
                    ForEach(OverlayCorner.allCases) { Text($0.title).tag($0) }
                }
                Picker("Size", selection: $prefs.overlaySize) {
                    ForEach(OverlaySize.allCases) { Text($0.title).tag($0) }
                }
                Picker("Auto-close", selection: $prefs.overlayAutoClose) {
                    Text("Never").tag(0)
                    ForEach([5, 10, 30, 60], id: \.self) { Text("After \($0) seconds").tag($0) }
                }
                Toggle("Close after dragging into another app", isOn: $prefs.closeOverlayAfterDrag)
            }
            Section {
                Text("Hover a thumbnail for Copy and Save. Corner buttons: close, annotate, pin, copy text. Double-click to annotate, drag to drop the file anywhere, swipe sideways to dismiss.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutSettings: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    HStack {
                        Text(action.title)
                        if HotkeyManager.shared.failed.contains(action) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("This shortcut is used by another app")
                        }
                        Spacer()
                        ShortcutRecorder(combo: prefs.shortcuts[action]) { prefs.setShortcut($0, for: action) }
                            .frame(width: 150, height: 24)
                    }
                }
            } footer: {
                HStack {
                    Text("Click a shortcut and press a new combination. ⌫ clears it.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { prefs.resetShortcuts() }
                }
            }
            Section {
                Text("To use ⇧⌘3 / ⇧⌘4 / ⇧⌘5, first turn off the macOS screenshot shortcuts in System Settings › Keyboard › Keyboard Shortcuts › Screenshots.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let combo: KeyCombo?
    let onChange: (KeyCombo?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let v = ShortcutRecorderView()
        v.combo = combo
        v.onChange = onChange
        return v
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        nsView.combo = combo
        nsView.onChange = onChange
    }
}

private struct PermissionSettings: View {
    @State private var screen = ScreenCapture.hasPermission
    @State private var accessibility = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                row("Screen Recording", granted: screen, detail: "Required for every capture.") {
                    PermissionsWindowController.show()
                }
                row("Accessibility", granted: accessibility, detail: "Only needed for auto-scroll in Scrolling Capture.") {
                    ScreenCapture.openAccessibilitySettings()
                }
            } footer: {
                Text("After granting Screen Recording, macOS may ask you to quit and reopen Glimpse.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            screen = ScreenCapture.hasPermission
            accessibility = AXIsProcessTrusted()
        }
    }

    private func row(_ title: String, granted: Bool, detail: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Open Settings", action: action) }
        }
    }
}
