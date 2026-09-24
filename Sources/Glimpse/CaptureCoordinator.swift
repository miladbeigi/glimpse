import AppKit

/// Runs each capture mode and the after-capture pipeline.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var busy = false
    private var lastArea: (displayID: CGDirectDisplayID, rect: CGRect)?

    func perform(_ action: HotkeyAction) {
        switch action {
        case .captureArea: captureArea()
        case .captureFullscreen: captureFullscreen()
        case .captureWindow: captureWindow()
        case .scrollingCapture: scrollingCapture()
        case .capturePreviousArea: capturePreviousArea()
        case .selfTimer: selfTimerArea()
        case .captureText: captureText()
        case .restoreRecent: QuickAccessManager.shared.restoreRecentlyClosed()
        }
    }

    private func ensurePermission() -> Bool {
        if ScreenCapture.hasPermission { return true }
        PermissionsWindowController.show()
        return false
    }

    /// Serialises captures so overlapping shortcuts can't stack overlays.
    private func run(_ body: @escaping () async -> Void) {
        guard !busy else { return }
        guard ensurePermission() else { return }
        busy = true
        Task {
            await body()
            busy = false
        }
    }

    private func report(_ error: Error) {
        NSLog("Glimpse: capture failed: \(error)")
        HUD.show("Capture failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
    }

    // MARK: Modes

    func captureArea() {
        run {
            guard let sel = await SelectionController.select(mode: .area) else { return }
            await self.finishSelection(sel)
        }
    }

    func captureWindow() {
        run {
            guard let sel = await SelectionController.select(mode: .window) else { return }
            await self.finishSelection(sel)
        }
    }

    private func finishSelection(_ sel: SelectionResult) async {
        if let windowID = sel.windowID {
            do {
                var (image, scale) = try await ScreenCapture.captureWindow(windowID)
                if Preferences.shared.windowShadow { image = ImageUtil.addShadow(to: image, scale: scale) }
                deliver(image, scale: scale)
                return
            } catch {
                NSLog("Glimpse: window capture failed, falling back to frozen crop: \(error)")
            }
        } else {
            lastArea = (sel.screen.displayID, sel.rect)
        }
        guard let image = ImageUtil.crop(sel.frozen, toPoints: sel.rect, scale: sel.scale) else { return }
        deliver(image, scale: sel.scale)
    }

    func captureFullscreen(delay: Int = 0) {
        run {
            let screen = NSScreen.withMouse
            if delay > 0 {
                guard await Countdown.run(seconds: delay, on: screen) else { return }
            }
            do {
                let image = try await ScreenCapture.captureScreen(screen)
                self.deliver(image, scale: screen.backingScaleFactor)
            } catch {
                self.report(error)
            }
        }
    }

    func capturePreviousArea() {
        guard let last = lastArea, let screen = NSScreen.with(displayID: last.displayID) else {
            captureArea()
            return
        }
        run {
            do {
                let image = try await ScreenCapture.captureRect(last.rect, on: screen)
                self.deliver(image, scale: screen.backingScaleFactor)
            } catch {
                self.report(error)
            }
        }
    }

    func selfTimerArea() {
        run {
            guard let sel = await SelectionController.select(mode: .area, allowModeToggle: false) else { return }
            self.lastArea = (sel.screen.displayID, sel.rect)
            guard await Countdown.run(seconds: Preferences.shared.selfTimerSeconds, on: sel.screen) else { return }
            do {
                let image = try await ScreenCapture.captureRect(sel.rect, on: sel.screen)
                self.deliver(image, scale: sel.screen.backingScaleFactor)
            } catch {
                self.report(error)
            }
        }
    }

    // MARK: Scripted captures (URL scheme with explicit coordinates)

    /// Live capture of a rect in the screen's top-left point coordinates.
    func captureArea(rect: CGRect, on screen: NSScreen) {
        run {
            do {
                let image = try await ScreenCapture.captureRect(rect, on: screen)
                self.lastArea = (screen.displayID, rect)
                self.deliver(image, scale: screen.backingScaleFactor)
            } catch {
                self.report(error)
            }
        }
    }

    /// Self-timer for a known region: countdown, then a live capture.
    func selfTimer(rect: CGRect, on screen: NSScreen, seconds: Int) {
        run {
            self.lastArea = (screen.displayID, rect)
            guard await Countdown.run(seconds: seconds, on: screen) else { return }
            do {
                let image = try await ScreenCapture.captureRect(rect, on: screen)
                self.deliver(image, scale: screen.backingScaleFactor)
            } catch {
                self.report(error)
            }
        }
    }

    func captureText(rect: CGRect, on screen: NSScreen) {
        run {
            do {
                let image = try await ScreenCapture.captureRect(rect, on: screen)
                await self.recognizeAndCopy(image)
            } catch {
                self.report(error)
            }
        }
    }

    func captureWindow(id: CGWindowID) {
        run {
            do {
                var (image, scale) = try await ScreenCapture.captureWindow(id)
                if Preferences.shared.windowShadow { image = ImageUtil.addShadow(to: image, scale: scale) }
                self.deliver(image, scale: scale)
            } catch {
                self.report(error)
            }
        }
    }

    func scrollingCapture(rect: CGRect, on screen: NSScreen, autoScroll: Bool) {
        run {
            let session = ScrollingCaptureSession(screen: screen, rect: rect, startAutoScroll: autoScroll)
            guard let image = await session.run() else { return }
            self.deliver(image, scale: screen.backingScaleFactor)
        }
    }

    private func recognizeAndCopy(_ image: CGImage) async {
        let text = await TextRecognizer.recognize(image)
        if text.isEmpty {
            HUD.show("No text found", symbol: "text.viewfinder")
        } else {
            Clipboard.copy(text: text)
            let preview = text.replacingOccurrences(of: "\n", with: " ")
            HUD.show("Copied: " + (preview.count > 60 ? String(preview.prefix(60)) + "…" : preview),
                     symbol: "text.viewfinder", duration: 2.2)
        }
    }

    func captureText() {
        run {
            guard let sel = await SelectionController.select(mode: .area) else { return }
            guard let image = ImageUtil.crop(sel.frozen, toPoints: sel.rect, scale: sel.scale) else { return }
            await self.recognizeAndCopy(image)
        }
    }

    func scrollingCapture() {
        run {
            guard let sel = await SelectionController.select(mode: .area, allowModeToggle: false) else { return }
            let session = ScrollingCaptureSession(screen: sel.screen, rect: sel.rect)
            guard let image = await session.run() else { return }
            self.deliver(image, scale: sel.screen.backingScaleFactor)
        }
    }

    // MARK: Pipeline

    func deliver(_ image: CGImage, scale: CGFloat) {
        let prefs = Preferences.shared
        let capture = Capture(image: image, scale: scale)
        Sound.playShutter()
        if prefs.copyToClipboard {
            Clipboard.copy(image, scale: scale)
        }
        if prefs.autoSave {
            do {
                try capture.saveToDefaultLocation()
            } catch {
                HUD.show("Save failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            }
        }
        if prefs.openEditorAfterCapture {
            EditorWindowController.open(capture: capture)
        } else if prefs.showOverlay || (!prefs.copyToClipboard && !prefs.autoSave) {
            // Never let a capture vanish: with every output disabled, fall back to the overlay.
            QuickAccessManager.shared.show(capture)
        } else if prefs.copyToClipboard {
            HUD.show("Copied to clipboard", symbol: "doc.on.doc.fill")
        }
    }

    // MARK: Clipboard / file sources

    func annotateClipboard() {
        guard let (image, scale) = Clipboard.image() else {
            HUD.show("No image on the clipboard", symbol: "doc.on.clipboard")
            return
        }
        EditorWindowController.open(capture: Capture(image: image, scale: scale))
    }

    func pinClipboard() {
        guard let (image, scale) = Clipboard.image() else {
            HUD.show("No image on the clipboard", symbol: "doc.on.clipboard")
            return
        }
        PinWindowController.pin(image: image, scale: scale)
    }
}
