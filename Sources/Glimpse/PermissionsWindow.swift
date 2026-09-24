import Combine
import AppKit
import SwiftUI

/// Onboarding / permissions window. Polls the permission state so it updates as soon as
/// the user flips the switch in System Settings, and offers a relaunch (ScreenCaptureKit
/// only picks up a new grant after the process restarts).
@MainActor
final class PermissionsWindowController: NSWindowController, NSWindowDelegate {
    static var shared: PermissionsWindowController?

    static var isVisible: Bool { shared?.window?.isVisible == true }

    static func show() {
        if shared == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Glimpse Permissions"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: PermissionsView())
            window.center()
            let controller = PermissionsWindowController(window: window)
            window.delegate = controller
            shared = controller
        }
        // Registers Glimpse in the Screen Recording list (shows the system prompt the first time).
        if !ScreenCapture.hasPermission { ScreenCapture.requestPermission() }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
        AppDelegate.refreshActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { AppDelegate.refreshActivationPolicy() }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

struct PermissionsView: View {
    @State private var screen = ScreenCapture.hasPermission
    @State private var screenAtLaunch = ScreenCapture.hasPermission
    @State private var accessibility = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up Glimpse").font(.title2.bold())
                    Text("Two macOS permissions, one required.").foregroundStyle(.secondary)
                }
            }

            step(number: 1, title: "Screen Recording", required: true, granted: screen,
                 detail: "Needed to take any screenshot. Turn on Glimpse in the list, then relaunch.") {
                ScreenCapture.requestPermission()
                ScreenCapture.openScreenRecordingSettings()
            }

            step(number: 2, title: "Accessibility", required: false, granted: accessibility,
                 detail: "Optional. Only used by Auto-scroll in Scrolling Capture.") {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                ScreenCapture.openAccessibilitySettings()
            }

            if screen && !screenAtLaunch {
                Label("Permission granted — relaunch Glimpse to start capturing.", systemImage: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.green)
            } else if !screen {
                Text("Don't see Glimpse in the list? Click “+”, choose Glimpse in Applications, and turn it on. If it's already on but still not detected, turn it off and on again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Relaunch Glimpse") { PermissionsWindowController.relaunch() }
                    .disabled(!screen)
                Button("Done") { PermissionsWindowController.shared?.window?.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480, height: 400)
        .onReceive(timer) { _ in
            screen = ScreenCapture.hasPermission
            accessibility = AXIsProcessTrusted()
        }
    }

    private func step(number: Int, title: String, required: Bool, granted: Bool, detail: String,
                      action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "\(number).circle")
                .font(.system(size: 22))
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(.headline)
                    Text(required ? "Required" : "Optional")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(required ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15)))
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Text("Granted").foregroundStyle(.green).font(.callout.weight(.medium))
            } else {
                Button("Open Settings", action: action)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}
