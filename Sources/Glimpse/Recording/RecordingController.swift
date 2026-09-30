import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit

/// What to record: part or all of one display.
struct RecordingTarget {
    let screen: NSScreen
    /// Local top-left points on `screen`.
    let rect: CGRect

    var isFullScreen: Bool { rect.size == screen.frame.size && rect.origin == .zero }
    /// Cocoa global coordinates.
    var globalRect: NSRect { screen.globalRect(fromLocalTopLeft: rect) }

    static func fullScreen(_ screen: NSScreen) -> RecordingTarget {
        RecordingTarget(screen: screen, rect: CGRect(origin: .zero, size: screen.frame.size))
    }
}

/// Overrides for scripted recordings (URL commands); nil fields use the saved settings.
struct RecordingOverrides {
    var camera: Bool?
    var microphone: Bool?
    var systemAudio: Bool?
    var countdown: Int?
    /// Stop automatically after this many seconds.
    var duration: Double?
}

/// Runs a screen recording: pick an area, get ready (camera bubble, audio toggles), count down, record, save.
@MainActor
final class RecordingController: ObservableObject {
    static let shared = RecordingController()

    enum Phase: Equatable { case idle, selecting, ready, countdown, recording, paused, saving }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var micLevel: Float = 0
    @Published var cameraOn = false
    @Published var micOn = false
    @Published var systemAudioOn = false

    private var target: RecordingTarget?
    private var recorder: ScreenRecorder?
    private var bubble: CameraBubble?
    private var chrome: RecordingChrome?
    private var tempURL: URL?
    private var startDate = Date()
    private var ticker: Timer?
    private var escMonitors: [Any] = []
    /// Bumped by every prepare and teardown, so work from an abandoned session can tell it's stale.
    private var generation = 0
    /// Stop after this many recorded seconds (pauses don't count).
    private var maxDuration: Double?

    var isActive: Bool { phase != .idle }
    var isRecording: Bool { phase == .recording || phase == .paused }

    // MARK: Entry points

    /// The Record Screen shortcut: start, or move on to the next step of a recording in progress.
    func toggle() {
        switch phase {
        case .idle: recordInteractively()
        case .ready: start()
        case .recording, .paused: stop()
        case .selecting, .countdown, .saving: break
        }
    }

    /// Select an area (click for the whole screen, Space for a window), then get ready.
    func recordInteractively(overrides: RecordingOverrides = RecordingOverrides(), startImmediately: Bool = false) {
        guard phase == .idle, ensureScreenPermission() else { return }
        phase = .selecting
        Task {
            guard let sel = await SelectionController.select(mode: .area, clickSelectsScreen: true) else {
                phase = .idle
                return
            }
            phase = .idle
            prepare(RecordingTarget(screen: sel.screen, rect: sel.rect), overrides: overrides, startImmediately: startImmediately)
        }
    }

    /// Shows the camera bubble and control bar for `target`; with `startImmediately` it goes straight on to the
    /// countdown (scripted recordings).
    func prepare(_ target: RecordingTarget, overrides: RecordingOverrides = RecordingOverrides(), startImmediately: Bool = false) {
        guard phase == .idle, ensureScreenPermission() else { return }
        let prefs = Preferences.shared
        self.target = target
        cameraOn = overrides.camera ?? prefs.recordCamera
        micOn = overrides.microphone ?? prefs.recordMicrophone
        systemAudioOn = overrides.systemAudio ?? prefs.recordSystemAudio
        elapsed = 0
        micLevel = 0
        generation += 1
        phase = .ready

        let chrome = RecordingChrome(target: target, controller: self)
        self.chrome = chrome
        chrome.show()
        installEscapeMonitors()
        let session = generation
        Task {
            // Settings turned these on; if access was refused, quietly leave them off rather than opening
            // System Settings on top of what's about to be recorded.
            if cameraOn { await showCamera(explicit: false) }
            if micOn, !(await MediaDevices.requestAccess(.audio, explicit: false)) { micOn = false }
            guard session == generation else { return }
            if startImmediately { start(countdown: overrides.countdown, duration: overrides.duration) }
        }
    }

    // MARK: Ready

    func setCamera(_ on: Bool) {
        if on {
            Task { await showCamera(explicit: true) }
        } else {
            cameraOn = false
            bubble?.hide()
        }
        if phase == .ready { Preferences.shared.recordCamera = on }
    }

    func setMicrophone(_ on: Bool) {
        guard phase == .ready else { return }
        Preferences.shared.recordMicrophone = on
        guard on else { micOn = false; return }
        Task {
            let granted = await MediaDevices.requestAccess(.audio, explicit: true)
            if phase == .ready { micOn = granted }
        }
    }

    func setSystemAudio(_ on: Bool) {
        guard phase == .ready else { return }
        systemAudioOn = on
        Preferences.shared.recordSystemAudio = on
    }

    private func showCamera(explicit: Bool) async {
        let session = generation
        guard target != nil, await MediaDevices.requestAccess(.video, explicit: explicit) else {
            cameraOn = false
            return
        }
        guard session == generation, let target else { return }
        if bubble == nil {
            guard let device = MediaDevices.camera else {
                HUD.show("No camera found", symbol: "video.slash")
                cameraOn = false
                return
            }
            do {
                let bubble = try CameraBubble(device: device)
                bubble.onHide = { [weak self] in self?.setCamera(false) }
                self.bubble = bubble
            } catch {
                HUD.show(error.localizedDescription, symbol: "video.slash")
                cameraOn = false
                return
            }
        }
        bubble?.show(in: target.globalRect, on: target.screen)
        cameraOn = true
        // A recording in progress only includes windows it was told about.
        if isRecording, let filter = try? await makeFilter() { recorder?.update(filter: filter) }
    }

    // MARK: Recording

    func start(countdown: Int? = nil, duration: Double? = nil) {
        guard phase == .ready, let target else { return }
        phase = .countdown
        removeEscapeMonitors()
        let session = generation
        Task {
            let seconds = countdown ?? Preferences.shared.recordCountdown
            if seconds > 0 {
                chrome?.setControlsHidden(true)
                let go = await Countdown.run(seconds: seconds, on: target.screen, centeredOn: target.globalRect)
                guard session == generation else { return }
                chrome?.setControlsHidden(false)
                guard go else {
                    phase = .ready
                    installEscapeMonitors()
                    return
                }
            }
            await begin(target: target, duration: duration, session: session)
        }
    }

    /// `session` is the generation that asked for it: a teardown in the meantime makes it a no-op.
    private func begin(target: RecordingTarget, duration: Double?, session: Int) async {
        guard session == generation else { return }
        let prefs = Preferences.shared
        if micOn, MediaDevices.microphone == nil {
            HUD.show("No microphone found: recording without it", symbol: "mic.slash")
            micOn = false
        }
        let scale = prefs.recordRetina ? target.screen.backingScaleFactor : 1
        let size = RecordingGeometry.outputSize(points: target.rect.size, scale: scale)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Glimpse Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")

        let recorder = ScreenRecorder()
        recorder.onMicLevel = { [weak self] level in self?.micLevel = level }
        recorder.onInterrupted = { [weak self] _ in
            guard let self, self.isRecording else { return }
            HUD.show("Recording stopped", symbol: "stop.circle")
            self.stop()
        }
        do {
            let options = ScreenRecorder.Options(
                filter: try await makeFilter(), sourceRect: target.isFullScreen ? nil : target.rect,
                width: size.width, height: size.height, fps: prefs.recordFrameRate,
                showsCursor: prefs.recordShowCursor, showsClicks: prefs.recordShowClicks,
                systemAudio: systemAudioOn, microphone: micOn ? MediaDevices.microphone : nil)
            try await recorder.start(options, to: url)
        } catch {
            NSLog("Glimpse: recording failed to start: \(error)")
            guard session == generation else { return }
            HUD.show("Recording failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle", duration: 2.5)
            tearDown()
            return
        }
        guard session == generation, phase == .countdown else {
            // Cancelled while starting.
            await recorder.cancel()
            return
        }
        self.recorder = recorder
        tempURL = url
        startDate = Date()
        phase = .recording
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        maxDuration = duration
    }

    private func tick() {
        guard isRecording, let recorder else { return }
        elapsed = recorder.elapsed
        if let maxDuration, elapsed >= maxDuration { stop() }
    }

    /// The whole display without Glimpse's own windows, except the camera bubble.
    private func makeFilter() async throws -> SCContentFilter {
        guard let target else { throw CaptureError.displayNotFound }
        var content = try await ScreenCapture.shareableContent()
        // A bubble that was only just shown can take a moment to be listed.
        if let bubble, bubble.isVisible {
            for _ in 0..<20 where !content.windows.contains(where: { $0.windowID == bubble.windowID }) {
                try? await Task.sleep(nanoseconds: 50_000_000)
                content = try await ScreenCapture.shareableContent()
            }
        }
        guard let display = content.displays.first(where: { $0.displayID == target.screen.displayID }) else {
            throw CaptureError.displayNotFound
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let own = content.applications.filter { $0.processID == pid }
        var include: [SCWindow] = []
        if let bubble, bubble.isVisible {
            if let window = content.windows.first(where: { $0.windowID == bubble.windowID }) {
                include.append(window)
            } else {
                NSLog("Glimpse: camera bubble window \(bubble.windowID) not in shareable content")
            }
        }
        return SCContentFilter(display: display, excludingApplications: own, exceptingWindows: include)
    }

    func pause() {
        guard phase == .recording else { return }
        recorder?.pause()
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        recorder?.resume()
        phase = .recording
    }

    func togglePause() {
        phase == .paused ? resume() : pause()
    }

    /// Stops and saves.
    func stop() {
        guard isRecording, let recorder, let tempURL else { return }
        phase = .saving
        stopTimers()
        Task {
            let duration: Double
            do {
                // Stop first so the bubble doesn't vanish on the last frames.
                duration = try await recorder.stop()
            } catch {
                NSLog("Glimpse: recording failed: \(error)")
                HUD.show("Recording failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle", duration: 2.5)
                try? FileManager.default.removeItem(at: tempURL)
                tearDown()
                return
            }
            bubble?.hide()
            chrome?.hideAreaBorder()
            let url = await finalize(tempURL)
            tearDown()
            deliver(url, duration: duration)
        }
    }

    /// Throws the recording away and starts a new one straight away (no countdown).
    func restart(confirm: Bool = true) {
        guard isRecording, !confirm || confirmDiscard(title: "Restart recording?") else { return }
        // The dialog is modal, but queued work (a stop, an interruption) still runs while it's up.
        guard isRecording, let target else { return }
        let session = generation
        let recorder = self.recorder
        let duration = maxDuration
        self.recorder = nil
        stopTimers()
        elapsed = 0
        phase = .countdown
        Task {
            await recorder?.cancel()
            await begin(target: target, duration: duration, session: session)
        }
    }

    /// Stops without saving (after asking, if there's anything worth keeping).
    func discard(confirm: Bool = true) {
        switch phase {
        case .ready, .countdown:
            tearDown()
        case .recording, .paused:
            guard !confirm || confirmDiscard(title: "Discard recording?"), isRecording else { return }
            let recorder = self.recorder
            tearDown()
            Task { await recorder?.cancel() }
        default:
            break
        }
    }

    private func confirmDiscard(title: String) -> Bool {
        guard elapsed >= 5 else { return true }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "The \(RecordingGeometry.formatDuration(elapsed)) recorded so far will be deleted."
        alert.addButton(withTitle: title.hasPrefix("Restart") ? "Restart" : "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Mixes the audio into one track and moves the file into the save folder. Never loses the recording: if the
    /// folder can't be written, it goes to Movies, and failing that stays where it is.
    private func finalize(_ url: URL) async -> URL {
        var file = url
        if let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio), tracks.count > 1 {
            let mixed = url.deletingPathExtension().appendingPathExtension("mixed.mp4")
            do {
                try await AudioTrackMixer.mixAudioTracks(of: url, into: mixed)
                try? FileManager.default.removeItem(at: url)
                file = mixed
            } catch {
                // Separate tracks still play in QuickTime; better than losing the recording.
                NSLog("Glimpse: could not mix audio tracks: \(error)")
                try? FileManager.default.removeItem(at: mixed)
            }
        }
        let name = ImageExporter.filename(for: startDate).replacingOccurrences(of: "Glimpse ", with: "Glimpse Recording ")
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        for dir in [Preferences.shared.saveDirectory, movies].compactMap({ $0 }) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = ImageExporter.uniqueURL(in: dir, base: name, ext: "mp4")
                try FileManager.default.moveItem(at: file, to: dest)
                if dir != Preferences.shared.saveDirectory {
                    HUD.show("Couldn't save to \(Preferences.shared.saveDirectory.lastPathComponent): saved to \(dir.lastPathComponent)",
                             symbol: "exclamationmark.triangle", duration: 3)
                }
                return dest
            } catch {
                NSLog("Glimpse: could not save the recording to \(dir.path): \(error)")
            }
        }
        return file
    }

    private func deliver(_ url: URL, duration: Double) {
        let prefs = Preferences.shared
        if prefs.copyToClipboard { Clipboard.copy(fileURL: url) }
        let recording = Recording(url: url, duration: duration)
        Task {
            await recording.loadThumbnail()
            QuickAccessManager.shared.show(recording)
        }
    }

    // MARK: Teardown

    private func stopTimers() {
        ticker?.invalidate()
        ticker = nil
        maxDuration = nil
    }

    private func tearDown() {
        stopTimers()
        removeEscapeMonitors()
        Countdown.cancelActive()
        bubble?.hide()
        bubble = nil
        chrome?.close()
        chrome = nil
        recorder = nil
        tempURL = nil
        target = nil
        generation += 1
        phase = .idle
    }

    private func ensureScreenPermission() -> Bool {
        if ScreenCapture.hasPermission { return true }
        PermissionsWindowController.show()
        return false
    }

    /// Esc cancels while getting ready (not while recording: Esc belongs to whatever is being recorded).
    private func installEscapeMonitors() {
        removeEscapeMonitors()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return } // Esc
            Task { @MainActor in if self?.phase == .ready { self?.discard() } }
        }) { escMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            // Leave Esc to Settings or an editor if one of them is in front.
            guard event.keyCode == 53, let self, self.phase == .ready,
                  NSApp.keyWindow == nil || NSApp.keyWindow is NSPanel else { return event }
            self.discard()
            return nil
        }) { escMonitors.append(m) }
    }

    private func removeEscapeMonitors() {
        escMonitors.forEach(NSEvent.removeMonitor)
        escMonitors.removeAll()
    }
}

#if DEBUG
extension RecordingController {
    /// Shows the control bar as if `seconds` had been recorded with the mic on (README screenshots). Returns the
    /// bar's window.
    func debugShowRecordingControls(on screen: NSScreen, seconds: Double) -> NSWindow? {
        let target = RecordingTarget.fullScreen(screen)
        self.target = target
        cameraOn = true
        micOn = true
        micLevel = 0.62
        elapsed = seconds
        phase = .recording
        let chrome = RecordingChrome(target: target, controller: self)
        chrome.show()
        self.chrome = chrome
        return chrome.controlWindow
    }

    func debugHideControls() {
        chrome?.close()
        chrome = nil
        target = nil
        phase = .idle
    }
}
#endif
