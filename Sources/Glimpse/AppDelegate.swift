import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!

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

        HotkeyManager.shared.handler = { action in CaptureCoordinator.shared.perform(action) }
        HotkeyManager.shared.install()

        #if DEBUG
        if DocsScenario.runIfRequested() { return }
        if ProcessInfo.processInfo.environment["GLIMPSE_DEBUG_SCENARIO"] != nil {
            DebugScenario.runIfRequested()
            return
        }
        #endif

        if !ScreenCapture.hasPermission {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { PermissionsWindowController.show() }
        }
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

    // MARK: Status menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
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
        menu.addItem(item("Capture Area", #selector(captureArea), symbol: "rectangle.dashed", hotkey: .captureArea))
        menu.addItem(item("Capture Previous Area", #selector(capturePrevious), symbol: "arrow.counterclockwise", hotkey: .capturePreviousArea))
        menu.addItem(item("Capture Fullscreen", #selector(captureFullscreen), symbol: "display", hotkey: .captureFullscreen))
        menu.addItem(item("Capture Window", #selector(captureWindow), symbol: "macwindow", hotkey: .captureWindow))
        menu.addItem(item("Scrolling Capture", #selector(scrollingCapture), symbol: "arrow.up.and.down.text.horizontal", hotkey: .scrollingCapture))

        let timer = NSMenuItem(title: "Self-Timer", action: nil, keyEquivalent: "")
        timer.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        let timerMenu = NSMenu()
        timerMenu.addItem(item("Area (\(Preferences.shared.selfTimerSeconds)s)", #selector(selfTimerArea), hotkey: .selfTimer))
        for s in [3, 5, 10] {
            let mi = item("Fullscreen in \(s)s", #selector(selfTimerFullscreen(_:)))
            mi.tag = s
            timerMenu.addItem(mi)
        }
        timer.submenu = timerMenu
        menu.addItem(timer)

        menu.addItem(item("Capture Text", #selector(captureText), symbol: "text.viewfinder", hotkey: .captureText))
        menu.addItem(.separator())
        menu.addItem(item("Annotate Image…", #selector(annotateFile), symbol: "pencil.and.outline"))
        menu.addItem(item("Annotate from Clipboard", #selector(annotateClipboard), symbol: "doc.on.clipboard"))
        menu.addItem(item("Pin from Clipboard", #selector(pinClipboard), symbol: "pin"))
        let restore = item("Restore Recently Closed", #selector(restoreRecent), symbol: "clock.arrow.circlepath", hotkey: .restoreRecent)
        restore.isEnabled = QuickAccessManager.shared.recentlyClosed != nil
        menu.addItem(restore)
        if PinWindowController.hasLocked {
            menu.addItem(item("Unlock Pinned Screenshots", #selector(unlockPins), symbol: "lock.open"))
        }
        menu.addItem(.separator())
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
    @objc private func annotateFile() { EditorWindowController.openImageFile() }
    @objc private func annotateClipboard() { CaptureCoordinator.shared.annotateClipboard() }
    @objc private func pinClipboard() { CaptureCoordinator.shared.pinClipboard() }
    @objc private func restoreRecent() { QuickAccessManager.shared.restoreRecentlyClosed() }
    @objc private func unlockPins() { PinWindowController.unlockAll() }
    @objc private func openSettings() { SettingsWindowController.show() }
    @objc private func openPermissions() { PermissionsWindowController.show() }
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
