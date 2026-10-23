import AppKit
import Combine
import Meetings

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var recordingObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ImageExporter.cleanTemporaryFiles()
        buildMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Glimpse")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        let recording = RecordingController.shared
        recordingObserver = recording.$phase.combineLatest(recording.$elapsed.map { Int($0) }.removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak self] phase, seconds in self?.updateStatusItem(phase: phase, elapsed: Double(seconds)) }

        HotkeyManager.shared.handler = { action in CaptureCoordinator.shared.perform(action) }
        HotkeyManager.shared.install()

        #if DEBUG
        if DocsScenario.runIfRequested() { return }
        if ProcessInfo.processInfo.environment["GLIMPSE_DEBUG_SCENARIO"] != nil {
            DebugScenario.runIfRequested()
            return
        }
        #endif

        UpdateController.shared.start()
        AgentToolRunner.cleanOutput()
        AgentServer.shared.start()
        Meetings.openSettings = { SettingsWindowController.show(tab: "meetings") }
        if Preferences.shared.meetingsEnabled { Meetings.start() }

        if !ScreenCapture.hasPermission {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { PermissionsWindowController.show() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Meetings.isBusy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = Meetings.isRecording ? "A meeting is being recorded" : "A meeting is being transcribed"
        alert.informativeText = "If you quit now, Glimpse finishes it the next time it opens."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit Anyway")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        AgentServer.shared.stop()
        Meetings.prepareForQuit()
    }

    /// Images dropped on the app icon or opened with "Open With › Glimpse" go straight to the editor.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme?.lowercased() == "glimpse" {
                URLCommands.handle(url)
            } else if let (image, scale) = ImageUtil.load(url: url) {
                EditorWindowController.open(capture: Capture(image: image, scale: scale))
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { SettingsWindowController.show() }
        return true
    }

    /// Dock icon + menu bar only while an editor or Settings is open.
    static func refreshActivationPolicy() {
        let needsRegular = !EditorWindowController.openEditors.isEmpty || SettingsWindowController.isVisible
            || PermissionsWindowController.isVisible
        let desired: NSApplication.ActivationPolicy = needsRegular ? .regular : .accessory
        if NSApp.activationPolicy() != desired {
            NSApp.setActivationPolicy(desired)
            if needsRegular { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    /// While recording, the menu bar icon turns into a red dot with the elapsed time.
    private func updateStatusItem(phase: RecordingController.Phase, elapsed: Double) {
        guard let button = statusItem.button else { return }
        let recording = phase == .recording || phase == .paused
        if recording {
            let symbol = phase == .paused ? "pause.circle.fill" : "record.circle.fill"
            let config = NSImage.SymbolConfiguration(paletteColors: [.white, phase == .paused ? .systemOrange : .systemRed])
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Recording")?.withSymbolConfiguration(config)
            image?.isTemplate = false
            button.image = image
            button.imagePosition = .imageLeading
            button.title = " " + RecordingGeometry.formatDuration(elapsed)
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            statusItem.length = NSStatusItem.variableLength
        } else if statusItem.length != NSStatusItem.squareLength {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Glimpse")
            image?.isTemplate = true
            button.image = image
            button.title = ""
            button.imagePosition = .imageOnly
            statusItem.length = NSStatusItem.squareLength
        }
    }

    // MARK: Status menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // Items set isEnabled themselves (restore, update); AppKit would otherwise re-enable them.
        menu.autoenablesItems = false
        let shortcuts = Preferences.shared.shortcuts

        func item(_ title: String, _ action: Selector, symbol: String? = nil, hotkey: HotkeyAction? = nil) -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            if let symbol { mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            if let hotkey, let combo = shortcuts[hotkey], let key = combo.menuKeyEquivalent {
                mi.keyEquivalent = key
                mi.keyEquivalentModifierMask = combo.cocoaModifiers
            }
            return mi
        }

        if !ScreenCapture.hasPermission {
            let warn = item("Grant Screen Recording Permission…", #selector(openPermissions), symbol: "exclamationmark.triangle.fill")
            menu.addItem(warn)
            menu.addItem(.separator())
        }
        // The meeting happening now, one click away (recording is manual when auto-detection is off).
        if let title = Meetings.recordingTitle {
            menu.addItem(item("Stop Recording “\(title)”", #selector(stopMeetingRecording), symbol: "stop.circle.fill"))
            menu.addItem(.separator())
        } else if let title = Meetings.unrecordedMeetingNow {
            menu.addItem(item("Record “\(title)”", #selector(recordMeetingNow), symbol: "record.circle"))
            menu.addItem(.separator())
        }
        let recorder = RecordingController.shared
        if recorder.isRecording {
            menu.addItem(item("Stop Recording", #selector(stopRecording), symbol: "stop.circle", hotkey: .recordScreen))
            menu.addItem(item(recorder.phase == .paused ? "Resume Recording" : "Pause Recording", #selector(togglePauseRecording),
                              symbol: recorder.phase == .paused ? "play.circle" : "pause.circle"))
            menu.addItem(item("Discard Recording", #selector(discardRecording), symbol: "trash"))
            menu.addItem(.separator())
        }
        if let update = UpdateController.shared.availableUpdate {
            let mi = item("Update to Glimpse \(update.version)", #selector(installUpdate), symbol: "arrow.down.circle.fill")
            mi.isEnabled = !UpdateController.shared.isInstalling
            menu.addItem(mi)
            menu.addItem(.separator())
        }
        func header(_ title: String) {
            menu.addItem(NSMenuItem.sectionHeader(title: title))
        }
        func submenu(_ title: String, symbol: String, status: String? = nil, _ items: [NSMenuItem]) -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            if let status {
                if #available(macOS 14.4, *) { mi.subtitle = status } else { mi.title = "\(title) — \(status)" }
            }
            let sub = NSMenu()
            sub.autoenablesItems = false
            items.forEach(sub.addItem)
            mi.submenu = sub
            return mi
        }

        header("Capture")
        menu.addItem(item("Capture Area", #selector(captureArea), symbol: "rectangle.dashed", hotkey: .captureArea))
        menu.addItem(item("Capture Window", #selector(captureWindow), symbol: "macwindow", hotkey: .captureWindow))
        menu.addItem(item("Capture Fullscreen", #selector(captureFullscreen), symbol: "display", hotkey: .captureFullscreen))
        menu.addItem(item("Scrolling Capture", #selector(scrollingCapture), symbol: "arrow.up.and.down.text.horizontal", hotkey: .scrollingCapture))
        menu.addItem(item("Capture Text", #selector(captureText), symbol: "text.viewfinder", hotkey: .captureText))
        var more = [
            item("Capture Previous Area", #selector(capturePrevious), symbol: "arrow.counterclockwise", hotkey: .capturePreviousArea),
            item("Self-Timer Area (\(Preferences.shared.selfTimerSeconds)s)", #selector(selfTimerArea), symbol: "timer", hotkey: .selfTimer),
        ]
        for s in [3, 5, 10] {
            let mi = item("Self-Timer Fullscreen in \(s)s", #selector(selfTimerFullscreen(_:)))
            mi.tag = s
            more.append(mi)
        }
        let restore = item("Restore Recently Closed", #selector(restoreRecent), symbol: "clock.arrow.circlepath", hotkey: .restoreRecent)
        restore.isEnabled = QuickAccessManager.shared.recentlyClosed != nil
        more += [.separator(), restore]
        menu.addItem(submenu("More", symbol: "ellipsis.circle", more))

        if !recorder.isActive {
            header("Record")
            menu.addItem(item("Record Screen…", #selector(recordScreen), symbol: "record.circle", hotkey: .recordScreen))
            menu.addItem(item("Record Full Screen", #selector(recordFullScreen), symbol: "inset.filled.rectangle.badge.record"))
        }

        header("Meetings")
        let meetingsMenu = NSMenu()
        meetingsMenu.autoenablesItems = false
        if Meetings.isRunning {
            Meetings.populate(meetingsMenu)
        } else {
            meetingsMenu.addItem(item("Turn On Meetings", #selector(startMeetings)))
            meetingsMenu.addItem(.separator())
            meetingsMenu.addItem(item("Transcription History", #selector(openMeetingHistory)))
            meetingsMenu.addItem(item("Meetings Settings…", #selector(openMeetingsSettings)))
        }
        let meetings = submenu("Meetings", symbol: Meetings.isRecording ? "waveform.circle.fill" : "waveform",
                               status: Meetings.statusText, [])
        meetings.submenu = meetingsMenu
        menu.addItem(meetings)
        menu.addItem(.separator())

        var annotate = [
            item("Annotate Image…", #selector(annotateFile), symbol: "pencil.and.outline"),
            item("Annotate from Clipboard", #selector(annotateClipboard), symbol: "doc.on.clipboard"),
            item("Pin from Clipboard", #selector(pinClipboard), symbol: "pin"),
        ]
        if PinWindowController.hasLocked {
            annotate.append(item("Unlock Pinned Screenshots", #selector(unlockPins), symbol: "lock.open"))
        }
        menu.addItem(submenu("Annotate & Pin", symbol: "pencil.tip.crop.circle", annotate))
        menu.addItem(item("Open Screenshots Folder", #selector(openFolder), symbol: "folder"))
        let settings = item("Settings…", #selector(openSettings), symbol: "gearshape")
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = .command
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Glimpse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // Status-menu actions run after the menu closes so the menu isn't in the screenshot.
    private func afterMenu(_ body: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            body()
        }
    }

    @objc private func captureArea() { afterMenu { CaptureCoordinator.shared.captureArea() } }
    @objc private func capturePrevious() { afterMenu { CaptureCoordinator.shared.capturePreviousArea() } }
    @objc private func captureFullscreen() { afterMenu { CaptureCoordinator.shared.captureFullscreen() } }
    @objc private func captureWindow() { afterMenu { CaptureCoordinator.shared.captureWindow() } }
    @objc private func scrollingCapture() { afterMenu { CaptureCoordinator.shared.scrollingCapture() } }
    @objc private func selfTimerArea() { afterMenu { CaptureCoordinator.shared.selfTimerArea() } }
    @objc private func selfTimerFullscreen(_ sender: NSMenuItem) {
        let s = sender.tag
        afterMenu { CaptureCoordinator.shared.captureFullscreen(delay: s) }
    }
    @objc private func captureText() { afterMenu { CaptureCoordinator.shared.captureText() } }
    @objc private func recordScreen() { afterMenu { RecordingController.shared.recordInteractively() } }
    @objc private func recordFullScreen() {
        afterMenu { RecordingController.shared.prepare(.fullScreen(NSScreen.withMouse)) }
    }
    @objc private func stopRecording() { RecordingController.shared.stop() }
    @objc private func togglePauseRecording() { RecordingController.shared.togglePause() }
    @objc private func discardRecording() { RecordingController.shared.discard() }
    @objc private func annotateFile() { EditorWindowController.openImageFile() }
    @objc private func annotateClipboard() { CaptureCoordinator.shared.annotateClipboard() }
    @objc private func pinClipboard() { CaptureCoordinator.shared.pinClipboard() }
    @objc private func restoreRecent() { QuickAccessManager.shared.restoreRecentlyClosed() }
    @objc private func unlockPins() { PinWindowController.unlockAll() }
    @objc private func installUpdate() {
        // install() only returns if it failed; Settings shows why.
        Task { await UpdateController.shared.install(); SettingsWindowController.show() }
    }
    @objc private func openSettings() { SettingsWindowController.show() }
    @objc private func openPermissions() { PermissionsWindowController.show() }
    @objc private func startMeetings() { Preferences.shared.meetingsEnabled = true }
    @objc private func recordMeetingNow() { Meetings.recordMeetingNow() }
    @objc private func stopMeetingRecording() { Meetings.stopRecording() }
    @objc private func openMeetingHistory() { Meetings.showHistory() }
    @objc private func openMeetingsSettings() { SettingsWindowController.show(tab: "meetings") }
    @objc private func openFolder() {
        let dir = Preferences.shared.saveDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    // MARK: Main menu (visible while an editor/settings window is open)

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About Glimpse", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Glimpse", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit Glimpse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let open = NSMenuItem(title: "Open Image…", action: #selector(annotateFile), keyEquivalent: "o")
        open.target = self
        fileMenu.addItem(open)
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Save", action: Selector(("editorSave:")), keyEquivalent: "s"))
        let saveAs = NSMenuItem(title: "Save As…", action: Selector(("editorSaveAs:")), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAs)
        fileMenu.addItem(NSMenuItem(title: "Pin to Screen", action: Selector(("editorPin:")), keyEquivalent: "p"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("editorUndo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("editorRedo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Duplicate", action: Selector(("editorDuplicate:")), keyEquivalent: "d"))
        editMenu.addItem(NSMenuItem(title: "Bring to Front", action: Selector(("editorBringToFront:")), keyEquivalent: "]"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(NSMenuItem(title: "Zoom In", action: Selector(("zoomIn:")), keyEquivalent: "="))
        viewMenu.addItem(NSMenuItem(title: "Zoom Out", action: Selector(("zoomOut:")), keyEquivalent: "-"))
        viewMenu.addItem(NSMenuItem(title: "Zoom to Fit", action: Selector(("zoomToFit:")), keyEquivalent: "0"))
        viewMenu.addItem(NSMenuItem(title: "Actual Size", action: Selector(("zoomActualSize:")), keyEquivalent: "1"))
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}
