import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// The MCP tools Glimpse offers agents. Definitions are shared with the `Glimpse mcp` bridge; `AgentToolRunner`
/// executes them inside the app.
enum AgentTools {
    static let defaultMaxSize = 1568
    /// Recording limits: agents must say how long, and can't record for more than ten minutes.
    static let defaultRecordingSeconds = 60
    static let maxRecordingSeconds = 600
    static let defaultFrameCount = 4

    static func error(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    static func text(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]]]
    }

    private static let coordinates = "Coordinates are screen points in one global space: origin at the top-left of the "
        + "main display, y pointing down (the same space as list_windows bounds and list_displays frames)."

    private static let imageOptions: [String: Any] = [
        "max_size": ["type": "integer", "description": "Longest edge of the returned image in pixels (default \(defaultMaxSize)); 0 returns full resolution. The saved file is always full resolution."],
        "format": ["type": "string", "enum": ["png", "jpeg"], "description": "Image format (default png)."],
        "save_path": ["type": "string", "description": "Absolute file or folder path for the full-resolution file. Defaults to a temporary folder."],
        "include_image": ["type": "boolean", "description": "Return the image inline (default true). Set false to get only the saved file path."],
    ]

    private static let windowTarget: [String: Any] = [
        "window_id": ["type": "integer", "description": "Window id from list_windows."],
        "app": ["type": "string", "description": "App name or bundle id, e.g. \"Safari\" or \"com.apple.Safari\". Picks the frontmost matching window."],
        "title": ["type": "string", "description": "Case-insensitive substring of the window title."],
    ]

    private static let regionTarget: [String: Any] = [
        "x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"],
    ]

    private static func schema(_ properties: [String: Any]..., required: [String] = []) -> [String: Any] {
        var merged: [String: Any] = [:]
        for p in properties { merged.merge(p) { a, _ in a } }
        var schema: [String: Any] = ["type": "object", "properties": merged]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    static var definitions: [[String: Any]] {
        let display: [String: Any] = ["display": ["type": "integer", "description": "Display number from list_displays (default 1, the main display)."]]
        return [
            [
                "name": "list_windows",
                "description": "Lists on-screen windows front to back with id, app, bundle id, title and bounds. " + coordinates,
                "inputSchema": schema(["app": ["type": "string", "description": "Only windows of this app (name or bundle id)."]]),
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "list_displays",
                "description": "Lists displays with their number, frame and backing scale. " + coordinates,
                "inputSchema": schema(),
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "screenshot_screen",
                "description": "Screenshots a whole display. Returns the image and a JSON summary with the saved file path and the "
                    + "captured frame; a pixel (px, py) in the returned image is at screen point (frame.x + px / scale, frame.y + py / scale).",
                "inputSchema": schema(display, imageOptions),
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "screenshot_window",
                "description": "Screenshots one window, even when other windows cover it. Identify it by window_id, or by app and/or title. "
                    + "Returns the image and a JSON summary like screenshot_screen.",
                "inputSchema": schema(windowTarget, imageOptions),
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "screenshot_region",
                "description": "Screenshots a rectangle of the screen. " + coordinates + " Returns the image and a JSON summary like screenshot_screen.",
                "inputSchema": schema(regionTarget, imageOptions, required: ["x", "y", "width", "height"]),
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "start_recording",
                "description": "Starts a screen recording (MP4, screen and optionally system audio; never the microphone or camera) "
                    + "of a window (window_id, or app and/or title), a region (x, y, width, height) or a display (display, default 1). "
                    + "The user sees Glimpse's recording controls and can stop it. It stops by itself after max_duration seconds. "
                    + "Returns a recording id; call stop_recording to finish and get the file and frames from it. "
                    + "A window is recorded as the part of the screen it covers, so keep it where it is. " + coordinates,
                "inputSchema": schema(windowTarget, regionTarget, display, [
                    "max_duration": ["type": "integer", "description": "Stop after this many seconds (default \(defaultRecordingSeconds), at most \(maxRecordingSeconds))."],
                    "system_audio": ["type": "boolean", "description": "Also record the sound playing on the Mac (default false)."],
                    "save_path": ["type": "string", "description": "Absolute .mp4 file or folder path for the recording. Defaults to a temporary folder."],
                ]),
                "annotations": ["readOnlyHint": false, "destructiveHint": false],
            ],
            [
                "name": "stop_recording",
                "description": "Stops the recording started with start_recording (or, if it already stopped at max_duration, returns it) "
                    + "and returns the saved file's path and duration, plus still frames spread across the video so you can "
                    + "check what it shows.",
                "inputSchema": schema([
                    "recording_id": ["type": "string", "description": "Id from start_recording (default: the current or last one)."],
                    "frames": ["type": "integer", "description": "Still frames to return, 0–8 (default \(defaultFrameCount))."],
                    "max_size": ["type": "integer", "description": "Longest edge of each frame in pixels (default 1024)."],
                ]),
                "annotations": ["readOnlyHint": false, "destructiveHint": false],
            ],
            [
                "name": "recording_status",
                "description": "Tells whether Glimpse is recording, and for an agent's recording its id, elapsed seconds and limit.",
                "inputSchema": schema(),
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "read_text",
                "description": "Reads text (OCR, on-device) and QR/barcode contents from a window (window_id, or app and/or title), "
                    + "a region (x, y, width, height) or a whole display (display). Returns plain text.",
                "inputSchema": schema(windowTarget, regionTarget, display),
                "annotations": ["readOnlyHint": true],
            ],
        ]
    }
}

@MainActor
enum AgentToolRunner {
    private struct Shot {
        let image: CGImage
        /// Pixels per point.
        let scale: CGFloat
        /// Global top-left point coordinates.
        let frame: CGRect
        var window: AgentWindow?
    }

    struct AgentWindow {
        let id: CGWindowID
        let app: String
        let bundleID: String?
        let title: String
        let frame: CGRect

        var summary: [String: Any] {
            var s: [String: Any] = ["id": Int(id), "app": app, "title": title, "bounds": rectJSON(frame)]
            if let bundleID { s["bundle_id"] = bundleID }
            return s
        }
    }

    private struct Failure: Error { let message: String }

    static func call(_ name: String, _ args: [String: Any]) async -> [String: Any] {
        guard Preferences.shared.agentAccess else {
            return AgentTools.error("Agent access is turned off. Turn on \"Allow AI agents to take screenshots\" in Glimpse Settings › Agents.")
        }
        if name != "list_displays", !ScreenCapture.hasPermission {
            return AgentTools.error("Glimpse doesn't have Screen Recording permission. Grant it in System Settings › Privacy & Security › "
                + "Screen Recording (or Glimpse Settings › Permissions), then reopen Glimpse.")
        }
        do {
            switch name {
            case "list_windows": return try listWindows(args)
            case "list_displays": return listDisplays()
            case "screenshot_screen": return try finish(try await screen(args), args)
            case "screenshot_window": return try finish(try await window(args), args)
            case "screenshot_region": return try finish(try await region(args), args)
            case "read_text": return try await readText(args)
            case "start_recording": return try await startRecording(args)
            case "stop_recording": return try await stopRecording(args)
            case "recording_status": return recordingStatus()
            default: return AgentTools.error("Unknown tool \(name).")
            }
        } catch let failure as Failure {
            return AgentTools.error(failure.message)
        } catch {
            return AgentTools.error(error.localizedDescription)
        }
    }

    // MARK: Targets

    static func windows() -> [AgentWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let number = info[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 40, bounds.height >= 40,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01 else { return nil }
            return AgentWindow(id: number, app: info[kCGWindowOwnerName as String] as? String ?? "",
                               bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                               title: info[kCGWindowName as String] as? String ?? "", frame: bounds)
        }
    }

    private static func matches(_ window: AgentWindow, app: String) -> Bool {
        let app = app.lowercased()
        return window.app.lowercased() == app || window.bundleID?.lowercased() == app || window.app.lowercased().contains(app)
    }

    private static func listWindows(_ args: [String: Any]) throws -> [String: Any] {
        var list = windows()
        if let app = string(args["app"]) { list = list.filter { matches($0, app: app) } }
        return AgentTools.text(json(["windows": list.map(\.summary)]))
    }

    private static func listDisplays() -> [String: Any] {
        let displays = NSScreen.screens.enumerated().map { i, screen -> [String: Any] in
            ["display": i + 1, "name": screen.localizedName, "frame": rectJSON(screen.cgFrame),
             "scale": screen.backingScaleFactor, "main": i == 0]
        }
        return AgentTools.text(json(["displays": displays]))
    }

    private static func findWindow(_ args: [String: Any]) throws -> AgentWindow? {
        let all = windows()
        if let id = int(args["window_id"]) {
            guard let w = all.first(where: { $0.id == CGWindowID(id) }) else {
                throw Failure(message: "No on-screen window with id \(id). Use list_windows to get current ids.")
            }
            return w
        }
        let app = string(args["app"]), title = string(args["title"])
        guard app != nil || title != nil else { return nil }
        let found = all.first { w in
            (app.map { matches(w, app: $0) } ?? true) && (title.map { w.title.localizedCaseInsensitiveContains($0) } ?? true)
        }
        guard let found else {
            let known = all.prefix(20).map { "\($0.app) — \"\($0.title)\" (id \($0.id))" }.joined(separator: "\n")
            throw Failure(message: "No on-screen window matches\(app.map { " app \"\($0)\"" } ?? "")\(title.map { " title \"\($0)\"" } ?? ""). "
                + "On-screen windows:\n\(known.isEmpty ? "(none)" : known)")
        }
        return found
    }

    private static func window(_ args: [String: Any]) async throws -> Shot {
        guard let w = try findWindow(args) else {
            throw Failure(message: "Pass window_id, or app and/or title. Use list_windows to find the window.")
        }
        let (image, scale) = try await ScreenCapture.captureWindow(w.id)
        return Shot(image: image, scale: scale, frame: w.frame, window: w)
    }

    private static func screen(_ args: [String: Any]) async throws -> Shot {
        let number = int(args["display"]) ?? 1
        let screens = NSScreen.screens
        guard screens.indices.contains(number - 1) else {
            throw Failure(message: "No display \(number); there \(screens.count == 1 ? "is 1 display" : "are \(screens.count) displays").")
        }
        let screen = screens[number - 1]
        return Shot(image: try await ScreenCapture.captureScreen(screen), scale: screen.backingScaleFactor, frame: screen.cgFrame)
    }

    private static func regionRect(_ args: [String: Any]) -> CGRect? {
        guard let x = double(args["x"]), let y = double(args["y"]),
              let w = double(args["width"]), let h = double(args["height"]) else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func region(_ args: [String: Any]) async throws -> Shot {
        guard let rect = regionRect(args), rect.width >= 1, rect.height >= 1 else {
            throw Failure(message: "Pass x, y, width and height (points, width and height at least 1).")
        }
        // The display holding most of the rect; the capture is clipped to it.
        let best = NSScreen.screens.max { a, b in
            area(a.cgFrame.intersection(rect)) < area(b.cgFrame.intersection(rect))
        }
        guard let screen = best, area(screen.cgFrame.intersection(rect)) > 0 else {
            throw Failure(message: "The region \(json(rectJSON(rect))) is not on any display. Use list_displays for display frames.")
        }
        let clipped = screen.cgFrame.intersection(rect)
        let local = clipped.offsetBy(dx: -screen.cgFrame.minX, dy: -screen.cgFrame.minY)
        let image = try await ScreenCapture.captureRect(local, on: screen)
        return Shot(image: image, scale: screen.backingScaleFactor, frame: clipped.integral)
    }

    private static func readText(_ args: [String: Any]) async throws -> [String: Any] {
        let shot: Shot
        if args["window_id"] != nil || args["app"] != nil || args["title"] != nil {
            shot = try await window(args)
        } else if regionRect(args) != nil {
            shot = try await region(args)
        } else {
            shot = try await screen(args)
        }
        let text = await TextRecognizer.recognize(shot.image)
        return AgentTools.text(text.isEmpty ? "No text found." : text)
    }

    // MARK: Recording

    private static func recordingAllowed() throws {
        guard Preferences.shared.agentRecording else {
            throw Failure(message: "Screen recording by agents is turned off. Turn on \"Allow AI agents to record the screen\" "
                + "in Glimpse Settings › Agents.")
        }
    }

    /// The part of one display to record, in that display's local top-left points.
    private static func recordingTarget(_ args: [String: Any]) throws -> RecordingTarget {
        var global: CGRect?
        if args["window_id"] != nil || args["app"] != nil || args["title"] != nil {
            guard let w = try findWindow(args) else { throw Failure(message: "Pass window_id, or app and/or title.") }
            global = w.frame
        } else if let rect = regionRect(args) {
            guard rect.width >= 16, rect.height >= 16 else { throw Failure(message: "The region must be at least 16 × 16 points.") }
            global = rect
        }
        guard let global else {
            let number = int(args["display"]) ?? 1
            let screens = NSScreen.screens
            guard screens.indices.contains(number - 1) else {
                throw Failure(message: "No display \(number); there \(screens.count == 1 ? "is 1 display" : "are \(screens.count) displays").")
            }
            return .fullScreen(screens[number - 1])
        }
        let best = NSScreen.screens.max { a, b in area(a.cgFrame.intersection(global)) < area(b.cgFrame.intersection(global)) }
        guard let screen = best, area(screen.cgFrame.intersection(global)) > 0 else {
            throw Failure(message: "\(json(rectJSON(global))) is not on any display. Use list_displays for display frames.")
        }
        let local = screen.cgFrame.intersection(global).offsetBy(dx: -screen.cgFrame.minX, dy: -screen.cgFrame.minY).integral
        return RecordingTarget(screen: screen, rect: local)
    }

    private static func startRecording(_ args: [String: Any]) async throws -> [String: Any] {
        try recordingAllowed()
        let target = try recordingTarget(args)
        let seconds = min(max(int(args["max_duration"]) ?? AgentTools.defaultRecordingSeconds, 1), AgentTools.maxRecordingSeconds)
        let destination = try outputURL(string(args["save_path"]), ext: "mp4")
        let controller = RecordingController.shared
        let id = try await controller.startForAgent(target, systemAudio: (args["system_audio"] as? Bool) ?? false,
                                                     maxDuration: Double(seconds), destination: destination)
        let frame = target.rect.offsetBy(dx: target.screen.cgFrame.minX, dy: target.screen.cgFrame.minY)
        return AgentTools.text(json(["recording_id": id, "recording": true, "frame": rectJSON(frame),
                                     "max_duration": seconds, "path": destination.path]))
    }

    private static func stopRecording(_ args: [String: Any]) async throws -> [String: Any] {
        try recordingAllowed()
        let result: AgentRecordingResult
        do {
            result = try await RecordingController.shared.stopForAgent(id: string(args["recording_id"]))
        } catch let error as AgentRecordingError {
            throw Failure(message: error.message)
        }
        let count = min(max(int(args["frames"]) ?? AgentTools.defaultFrameCount, 0), 8)
        let maxSize = int(args["max_size"]) ?? 1024
        let attributes = try? FileManager.default.attributesOfItem(atPath: result.url.path)
        var summary: [String: Any] = [
            "recording_id": result.id,
            "path": result.url.path,
            "duration": rounded(CGFloat(result.duration)),
            "file_bytes": (attributes?[.size] as? NSNumber)?.intValue ?? 0,
        ]
        let asset = AVURLAsset(url: result.url)
        if let track = try? await asset.loadTracks(withMediaType: .video).first, let size = try? await track.load(.naturalSize) {
            summary["video_size"] = ["width": Int(size.width), "height": Int(size.height)]
        }
        var content: [[String: Any]] = []
        var times: [NSDecimalNumber] = []
        if count > 0 {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            if maxSize > 0 { generator.maximumSize = CGSize(width: maxSize, height: maxSize) }
            let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            for i in 0..<count {
                // Evenly spread, away from the very first and last frame.
                let t = result.duration * (Double(i) + 0.5) / Double(count)
                guard let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image,
                      let data = encode(image, jpeg: true) else { continue }
                content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"])
                times.append(NSDecimalNumber(string: String(format: "%.1f", t)))
            }
        }
        summary["frame_times"] = times
        content.append(["type": "text", "text": json(summary)])
        return ["content": content]
    }

    private static func recordingStatus() -> [String: Any] {
        let controller = RecordingController.shared
        var status: [String: Any] = ["recording": controller.isRecording, "paused": controller.phase == .paused]
        if let id = controller.agentRecordingID {
            status["recording_id"] = id
            status["elapsed"] = rounded(CGFloat(controller.elapsed))
            if let limit = controller.agentMaxDuration { status["max_duration"] = Int(limit) }
        } else if controller.isActive {
            status["started_by"] = "user"
        }
        return AgentTools.text(json(status))
    }

    // MARK: Output

    private static let outputDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("glimpse-agent", isDirectory: true)

    /// Removes screenshots from previous runs.
    static func cleanOutput() {
        try? FileManager.default.removeItem(at: outputDirectory)
    }

    private static func finish(_ shot: Shot, _ args: [String: Any]) throws -> [String: Any] {
        let jpeg = ["jpeg", "jpg"].contains(string(args["format"])?.lowercased() ?? "")
        guard let fullData = encode(shot.image, jpeg: jpeg) else { throw Failure(message: "Could not encode the image.") }
        let url = try outputURL(string(args["save_path"]), ext: jpeg ? "jpg" : "png")
        try fullData.write(to: url, options: .atomic)

        var image = shot.image
        let maxSize = int(args["max_size"]) ?? AgentTools.defaultMaxSize
        let longest = max(image.width, image.height)
        if maxSize > 0, longest > maxSize {
            let factor = CGFloat(max(maxSize, 64)) / CGFloat(longest)
            image = ImageUtil.resized(image, toPixelWidth: max(1, Int((CGFloat(image.width) * factor).rounded())),
                                      height: max(1, Int((CGFloat(image.height) * factor).rounded())))
        }
        var summary: [String: Any] = [
            "path": url.path,
            "frame": rectJSON(shot.frame),
            "image_size": ["width": image.width, "height": image.height],
            "file_size": ["width": shot.image.width, "height": shot.image.height],
            "scale": rounded(shot.scale * CGFloat(image.width) / CGFloat(shot.image.width)),
        ]
        if let window = shot.window { summary["window"] = window.summary }

        var content: [[String: Any]] = []
        if (args["include_image"] as? Bool) ?? true {
            let data = image === shot.image ? fullData : encode(image, jpeg: jpeg)
            guard let data else { throw Failure(message: "Could not encode the image.") }
            content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": jpeg ? "image/jpeg" : "image/png"])
        }
        content.append(["type": "text", "text": json(summary)])
        return ["content": content]
    }

    private static func outputURL(_ requested: String?, ext: String) throws -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let base = "glimpse-\(f.string(from: Date()))"
        guard let requested else {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            return ImageExporter.uniqueURL(in: outputDirectory, base: base, ext: ext)
        }
        let path = (requested as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { throw Failure(message: "save_path must be an absolute path.") }
        var isDir: ObjCBool = false
        if requested.hasSuffix("/") || (FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue) {
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return ImageExporter.uniqueURL(in: dir, base: base, ext: ext)
        }
        var url = URL(fileURLWithPath: path)
        if url.pathExtension.isEmpty { url.appendPathExtension(ext) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    private static func encode(_ image: CGImage, jpeg: Bool) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil)
        else { return nil }
        let props = jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary : nil
        CGImageDestinationAddImage(dest, jpeg ? (ImageExporter.flattened(image) ?? image) : image, props)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    // MARK: JSON helpers

    /// Three decimals that also print as three decimals in JSON.
    private static func rounded(_ value: CGFloat) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.3f", Double(value)))
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    private static func json(_ object: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }
}

private func rectJSON(_ r: CGRect) -> [String: Any] {
    ["x": Double(r.minX), "y": Double(r.minY), "width": Double(r.width), "height": Double(r.height)]
}
