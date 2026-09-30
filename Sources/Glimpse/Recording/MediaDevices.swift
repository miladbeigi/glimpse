import AppKit
import AVFoundation

/// Cameras, microphones and their permissions.
@MainActor
enum MediaDevices {
    static var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    static var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                         position: .unspecified).devices
    }

    /// The chosen camera, falling back to the system default when it's unplugged.
    static var camera: AVCaptureDevice? {
        let id = Preferences.shared.cameraID
        return (id.isEmpty ? nil : AVCaptureDevice(uniqueID: id)) ?? AVCaptureDevice.default(for: .video) ?? cameras.first
    }

    static var microphone: AVCaptureDevice? {
        let id = Preferences.shared.microphoneID
        return (id.isEmpty ? nil : AVCaptureDevice(uniqueID: id)) ?? AVCaptureDevice.default(for: .audio) ?? microphones.first
    }

    static func isAuthorized(_ type: AVMediaType) -> Bool {
        AVCaptureDevice.authorizationStatus(for: type) == .authorized
    }

    /// Asks the first time. After that, if access was refused, `explicit` requests (the user just pressed the
    /// button) point to System Settings; others just return false.
    static func requestAccess(_ type: AVMediaType, explicit: Bool) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized:
            return true
        case .notDetermined:
            NSApp.activate(ignoringOtherApps: true)
            return await AVCaptureDevice.requestAccess(for: type)
        default:
            guard explicit else { return false }
            let what = type == .video ? "camera" : "microphone"
            HUD.show("Allow Glimpse to use the \(what) in System Settings", symbol: "exclamationmark.triangle", duration: 2.5)
            openPrivacySettings(type)
            return false
        }
    }

    static func openPrivacySettings(_ type: AVMediaType) {
        let pane = type == .video ? "Privacy_Camera" : "Privacy_Microphone"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
