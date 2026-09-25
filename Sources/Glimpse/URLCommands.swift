import AppKit

/// `glimpse://<command>` automation API. Examples:
///   open "glimpse://capture-area"
///   open "glimpse://capture-fullscreen?delay=3"
///   open "glimpse://annotate?filepath=/path/to/image.png"
@MainActor
enum URLCommands {
    static func handle(_ url: URL) {
        let command = (url.host ?? url.path).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name.lowercased(), $0.value ?? "") })
        let c = CaptureCoordinator.shared
        // Optional explicit region: x, y, width, height in points from the top-left of `display` (1-based).
        var region: (CGRect, NSScreen)?
        if let x = Double(query["x"] ?? ""), let y = Double(query["y"] ?? ""),
           let w = Double(query["width"] ?? ""), let h = Double(query["height"] ?? ""), w > 0, h > 0 {
            let index = (Int(query["display"] ?? "") ?? 1) - 1
            let screens = NSScreen.screens
            let screen = screens.indices.contains(index) ? screens[index] : screens[0]
            let r = CGRect(x: x, y: y, width: w, height: h).intersection(CGRect(origin: .zero, size: screen.frame.size))
            if !r.isNull, r.width >= 1, r.height >= 1 { region = (r, screen) }
        }
        switch command {
        case "capture-area" where region != nil: c.captureArea(rect: region!.0, on: region!.1)
        case "self-timer" where region != nil:
            c.selfTimer(rect: region!.0, on: region!.1,
                        seconds: Int(query["delay"] ?? "") ?? Preferences.shared.selfTimerSeconds)
        case "capture-text" where region != nil: c.captureText(rect: region!.0, on: region!.1)
        case "scrolling-capture" where region != nil:
            c.scrollingCapture(rect: region!.0, on: region!.1, autoScroll: query["autoscroll"] == "1")
        case "capture-window" where UInt32(query["windowid"] ?? "") != nil:
            c.captureWindow(id: UInt32(query["windowid"]!)!)
        case "capture-area": c.captureArea()
        case "capture-previous-area": c.capturePreviousArea()
        case "capture-fullscreen": c.captureFullscreen(delay: Int(query["delay"] ?? "") ?? 0)
        case "capture-window": c.captureWindow()
        case "scrolling-capture": c.scrollingCapture()
        case "self-timer": c.selfTimerArea()
        case "capture-text": c.captureText()
        case "restore-recently-closed": QuickAccessManager.shared.restoreRecentlyClosed()
        case "annotate-clipboard": c.annotateClipboard()
        case "pin-clipboard": c.pinClipboard()
        case "annotate", "pin":
            guard let path = query["filepath"], let (image, scale) = ImageUtil.load(url: URL(fileURLWithPath: path)) else {
                HUD.show("Could not open image", symbol: "exclamationmark.triangle")
                return
            }
            if command == "pin" {
                PinWindowController.pin(image: image, scale: scale)
            } else {
                EditorWindowController.open(capture: Capture(image: image, scale: scale))
            }
        case "open-settings": SettingsWindowController.show(tab: query["tab"])
        case "permissions": PermissionsWindowController.show()
        default:
            NSLog("Glimpse: unknown URL command \(url.absoluteString)")
        }
    }
}
