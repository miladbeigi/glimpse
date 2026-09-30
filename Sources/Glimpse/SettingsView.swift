import Combine
import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static var shared: SettingsWindowController?

    static var isVisible: Bool { shared?.window?.isVisible == true }

    /// `tab` is a tab's label, case-insensitive, spaces optional (e.g. "shortcuts"); nil keeps the current tab.
    static func show(tab: String? = nil) {
        if shared == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Glimpse Settings"
            window.isReleasedWhenClosed = false
            // The tab bar is drawn in SwiftUI below the title bar: a SwiftUI TabView collapses its tabs into the
            // toolbar's » overflow button, and the AppKit preference toolbar packs its icons tight under the title.
            let hosting = NSHostingController(rootView: SettingsView(selection: selection))
            // min = max = the view's fixed size, so the window resizes to fit each tab.
            hosting.sizingOptions = [.minSize, .maxSize]
            window.contentViewController = hosting
            window.center()
            let controller = SettingsWindowController(window: window)
            window.delegate = controller
            shared = controller
        }
        if let tab, let match = SettingsTab.allCases.first(where: {
            $0.title.lowercased().filter { !$0.isWhitespace } == tab.lowercased().filter { !$0.isWhitespace }
        }) {
            selection.tab = match
        }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
        AppDelegate.refreshActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
    }

    private static let selection = SettingsSelection()

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { AppDelegate.refreshActivationPolicy() }
    }
}

private enum SettingsTab: CaseIterable {
    case general, capture, recording, quickAccess, shortcuts, agents, permissions

    var title: String {
        switch self {
        case .general: "General"
        case .capture: "Capture"
        case .recording: "Recording"
        case .quickAccess: "Quick Access"
        case .shortcuts: "Shortcuts"
        case .agents: "Agents"
        case .permissions: "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .capture: "camera.viewfinder"
        case .recording: "record.circle"
        case .quickAccess: "rectangle.on.rectangle"
        case .shortcuts: "keyboard"
        case .agents: "sparkles"
        case .permissions: "lock.shield"
        }
    }

    /// Fits each tab's content; General adds `extraRows` for its optional rows. The form scrolls beyond that.
    func height(extraRows: CGFloat = 0) -> CGFloat {
        switch self {
        case .general: 640 + extraRows * 40
        case .capture: 340
        case .recording: 640
        case .quickAccess: 270
        case .shortcuts: 560
        case .agents: 400
        case .permissions: 300
        }
    }
}

@MainActor
private final class SettingsSelection: ObservableObject {
    @Published var tab = SettingsTab.general
}

private struct SettingsView: View {
    @ObservedObject var selection: SettingsSelection
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var updates = UpdateController.shared

    /// Rows General shows only sometimes: JPEG quality, an available update and the last check's status.
    private var generalExtraRows: CGFloat {
        var rows: CGFloat = prefs.imageFormat == .jpeg ? 1 : 0
        if Updater.repository != nil {
            if updates.availableUpdate != nil { rows += 1 }
            if updates.status != nil { rows += 1 }
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    TabButton(tab: tab, isSelected: selection.tab == tab) { selection.tab = tab }
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 8)
            Divider()
            Group {
                switch selection.tab {
                case .general: GeneralSettings()
                case .capture: CaptureSettings()
                case .recording: RecordingSettings()
                case .quickAccess: OverlaySettings()
                case .shortcuts: ShortcutSettings()
                case .agents: AgentSettings()
                case .permissions: PermissionSettings()
                }
            }
            .frame(width: 560, height: selection.tab.height(extraRows: generalExtraRows))
        }
    }
}

private struct TabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 20))
                    .frame(height: 24)
                Text(tab.title).font(.system(size: 11))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minWidth: 64)
            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .background {
                if isSelected { RoundedRectangle(cornerRadius: 8).fill(.quaternary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
            if Updater.repository != nil {
                UpdateSection()
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

private struct UpdateSection: View {
    @ObservedObject private var updates = UpdateController.shared

    var body: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: $updates.checkAutomatically)
            HStack {
                Text("Version \(Updater.currentVersion)")
                Spacer()
                if updates.isChecking { ProgressView().controlSize(.small) }
                Button("Check Now") { Task { await updates.check(manual: true) } }
                    .disabled(updates.isChecking || updates.isInstalling)
            }
            if let update = updates.availableUpdate {
                HStack {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                    Text("Version \(update.version) is available")
                    Spacer()
                    Button(updates.isInstalling ? "Updating…" : "Update and Relaunch") {
                        Task { await updates.install() }
                    }
                    .disabled(updates.isInstalling)
                }
            }
            if let status = updates.status {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
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

private struct RecordingSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var cameras: [AVCaptureDevice] = []
    @State private var microphones: [AVCaptureDevice] = []

    var body: some View {
        Form {
            Section("Video") {
                Picker("Frame rate", selection: $prefs.recordFrameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Toggle("Record at Retina resolution", isOn: $prefs.recordRetina)
                Toggle("Show mouse pointer", isOn: $prefs.recordShowCursor)
                if #available(macOS 15.0, *) {
                    Toggle("Highlight clicks", isOn: $prefs.recordShowClicks)
                }
                Picker("Countdown", selection: $prefs.recordCountdown) {
                    Text("None").tag(0)
                    ForEach([3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
                }
            }
            Section("Audio") {
                Toggle("Record microphone", isOn: $prefs.recordMicrophone)
                devicePicker("Microphone", selection: $prefs.microphoneID, devices: microphones)
                    .disabled(!prefs.recordMicrophone)
                Toggle("Record system audio", isOn: $prefs.recordSystemAudio)
            }
            Section {
                Toggle("Show camera", isOn: $prefs.recordCamera)
                devicePicker("Camera", selection: $prefs.cameraID, devices: cameras)
                Picker("Shape", selection: $prefs.cameraShape) {
                    ForEach(CameraShape.allCases) { Text($0.title).tag($0) }
                }
                Picker("Size", selection: $prefs.cameraSize) {
                    ForEach(CameraSize.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Mirror camera", isOn: $prefs.cameraMirror)
            } header: {
                Text("Camera")
            } footer: {
                Text("The camera bubble is part of the recording. Drag it anywhere, scroll to resize, right-click for more. Camera, microphone and system audio can also be switched on the control bar before you start.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            cameras = MediaDevices.cameras
            microphones = MediaDevices.microphones
        }
    }

    private func devicePicker(_ title: String, selection: Binding<String>, devices: [AVCaptureDevice]) -> some View {
        Picker(title, selection: selection) {
            Text("System Default").tag("")
            // Keep a device that's unplugged selectable so the choice isn't silently lost.
            if !selection.wrappedValue.isEmpty, !devices.contains(where: { $0.uniqueID == selection.wrappedValue }) {
                Text("Unavailable Device").tag(selection.wrappedValue)
            }
            ForEach(devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
        }
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

private struct AgentSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    private let executable = Bundle.main.executablePath ?? "/Applications/Glimpse.app/Contents/MacOS/Glimpse"

    private var claudeCommand: String { "claude mcp add glimpse -- \(executable) mcp" }
    private var jsonConfig: String {
        #"{ "mcpServers": { "glimpse": { "command": "\#(executable)", "args": ["mcp"] } } }"#
    }

    var body: some View {
        Form {
            Section {
                Toggle("Allow AI agents to take screenshots", isOn: $prefs.agentAccess)
            } footer: {
                Text("While this is on, agents you connect can list windows, take screenshots and read text from anything on screen.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Connect an agent") {
                command("Claude Code", claudeCommand)
                command("Other MCP clients (Claude Desktop, Cursor, …)", jsonConfig)
            }
            Section {
                Text("Tools: list_windows, list_displays, screenshot_screen, screenshot_window, screenshot_region and read_text. Screenshots are also saved as full-resolution files.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func command(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button("Copy") { Clipboard.copy(text: text) }
            }
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
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
    @State private var camera = MediaDevices.isAuthorized(.video)
    @State private var microphone = MediaDevices.isAuthorized(.audio)
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
                row("Camera", granted: camera, detail: "Only for the camera bubble in screen recordings.") {
                    Task { camera = await MediaDevices.requestAccess(.video, explicit: true) }
                }
                row("Microphone", granted: microphone, detail: "Only for recording your voice with the screen.") {
                    Task { microphone = await MediaDevices.requestAccess(.audio, explicit: true) }
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
            camera = MediaDevices.isAuthorized(.video)
            microphone = MediaDevices.isAuthorized(.audio)
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
