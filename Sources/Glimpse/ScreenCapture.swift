import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noPermission
    case displayNotFound
    case windowNotFound

    var errorDescription: String? {
        switch self {
        case .noPermission: return "Screen Recording permission is required."
        case .displayNotFound: return "The display could not be found."
        case .windowNotFound: return "The window could not be found."
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    /// Frame in CoreGraphics global coordinates (origin top-left of the primary display, y down).
    var cgFrame: CGRect { CGDisplayBounds(displayID) }

    /// Converts a point in Cocoa global coordinates to this screen's local, top-left-origin coordinates.
    func localTopLeft(fromGlobal p: NSPoint) -> CGPoint {
        CGPoint(x: p.x - frame.minX, y: frame.maxY - p.y)
    }

    /// Converts a local top-left rect on this screen to Cocoa global coordinates.
    func globalRect(fromLocalTopLeft r: CGRect) -> NSRect {
        NSRect(x: frame.minX + r.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    static var withMouse: NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func with(displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }
}

struct WindowInfo {
    let id: CGWindowID
    /// CoreGraphics global coordinates.
    let frame: CGRect
    let ownerName: String
}

@MainActor
enum ScreenCapture {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// A filter for the whole display that hides all of Glimpse's own windows.
    static func displayFilter(for screen: NSScreen, content: SCShareableContent) throws -> SCContentFilter {
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CaptureError.displayNotFound
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let own = content.applications.filter { $0.processID == pid }
        return SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
    }

    static func configuration(pixelWidth: Int, pixelHeight: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = max(1, pixelWidth)
        config.height = max(1, pixelHeight)
        config.showsCursor = false
        config.captureResolution = .best
        return config
    }

    /// Captures the entire screen (without Glimpse's windows).
    static func captureScreen(_ screen: NSScreen, content: SCShareableContent? = nil) async throws -> CGImage {
        let resolved: SCShareableContent
        if let content { resolved = content } else { resolved = try await shareableContent() }
        let filter = try displayFilter(for: screen, content: resolved)
        let scale = screen.backingScaleFactor
        let config = configuration(pixelWidth: Int((screen.frame.width * scale).rounded()),
                                   pixelHeight: Int((screen.frame.height * scale).rounded()))
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Captures a rect given in the screen's local top-left point coordinates.
    static func captureRect(_ rect: CGRect, on screen: NSScreen, filter: SCContentFilter? = nil) async throws -> CGImage {
        let resolved: SCContentFilter
        if let filter { resolved = filter } else { resolved = try displayFilter(for: screen, content: try await shareableContent()) }
        let scale = screen.backingScaleFactor
        let r = rect.integral
        let config = configuration(pixelWidth: Int((r.width * scale).rounded()), pixelHeight: Int((r.height * scale).rounded()))
        config.sourceRect = r
        return try await SCScreenshotManager.captureImage(contentFilter: resolved, configuration: config)
    }

    /// Captures a single window as a standalone image (transparent corners, no shadow).
    static func captureWindow(_ windowID: CGWindowID) async throws -> (CGImage, CGFloat) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = configuration(pixelWidth: Int((filter.contentRect.width * scale).rounded()),
                                   pixelHeight: Int((filter.contentRect.height * scale).rounded()))
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }

    /// On-screen normal windows of other apps, front to back.
    static func onScreenWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let number = info[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 40, bounds.height >= 40 else { return nil }
            let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1
            guard alpha > 0.01 else { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            return WindowInfo(id: number, frame: bounds, ownerName: owner)
        }
    }
}

// MARK: - Image helpers

enum ImageUtil {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A colour space usable for an 8-bit RGBA bitmap context (falls back to sRGB for HDR/odd spaces).
    static func bitmapSpace(for image: CGImage) -> CGColorSpace {
        guard let cs = image.colorSpace, cs.model == .rgb, cs.supportsOutput, !CGColorSpaceUsesExtendedRange(cs) else { return sRGB }
        return cs
    }

    static func crop(_ image: CGImage, toPoints rect: CGRect, scale: CGFloat) -> CGImage? {
        let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                               width: rect.width * scale, height: rect.height * scale).integral
        return image.cropping(to: pixelRect)
    }

    /// Adds a soft macOS-like drop shadow around a window image.
    static func addShadow(to image: CGImage, scale: CGFloat) -> CGImage {
        let blur = 28 * scale
        let offsetY = 12 * scale
        let pad = Int((blur * 1.6).rounded())
        let w = image.width + pad * 2
        let h = image.height + pad * 2
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: bitmapSpace(for: image),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.setShadow(offset: CGSize(width: 0, height: -offsetY), blur: blur,
                      color: CGColor(gray: 0, alpha: 0.45))
        ctx.draw(image, in: CGRect(x: pad, y: pad, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    static func resized(_ image: CGImage, toPixelWidth w: Int, height h: Int) -> CGImage {
        guard w > 0, h > 0, w != image.width || h != image.height,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: bitmapSpace(for: image),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    static func load(url: URL) -> (CGImage, CGFloat)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return load(source: src)
    }

    static func load(data: Data) -> (CGImage, CGFloat)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return load(source: src)
    }

    private static func load(source: CGImageSource) -> (CGImage, CGFloat)? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var scale: CGFloat = 1
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let dpi = props[kCGImagePropertyDPIWidth] as? Double, dpi > 72 {
            scale = max(1, (CGFloat(dpi) / 72).rounded())
        }
        return (image, scale)
    }
}

/// Draws a CGImage into a flipped (top-left origin) context without turning it upside down.
func drawImageFlipped(_ image: CGImage, in rect: CGRect, context ctx: CGContext) {
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
    ctx.restoreGState()
}
