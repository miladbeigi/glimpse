import AppKit
import UniformTypeIdentifiers

/// One screenshot as it moves through overlay → editor → pin.
@MainActor
final class Capture {
    let id = UUID()
    let date = Date()
    let baseImage: CGImage
    let scale: CGFloat
    /// Editable annotation state; nil until the capture is opened in the editor.
    var document: EditorDocumentState?
    /// base + annotations, cropped and resized.
    private(set) var image: CGImage
    var savedURL: URL?
    private var tempURL: URL?

    init(image: CGImage, scale: CGFloat) {
        baseImage = image
        self.image = image
        self.scale = max(scale, 1)
    }

    var pointSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }
    var nsImage: NSImage { NSImage(cgImage: image, size: pointSize) }

    func update(rendered: CGImage, document: EditorDocumentState) {
        image = rendered
        self.document = document
        tempURL = nil
        if let url = savedURL {
            // Keep a file the user already saved in sync with the edits.
            try? ImageExporter.write(image, scale: scale, to: url)
        }
    }

    /// A file on disk suitable for drag & drop (the saved file, or a temporary copy).
    func fileForDragging() -> URL? {
        if let savedURL, FileManager.default.fileExists(atPath: savedURL.path) { return savedURL }
        if let tempURL, FileManager.default.fileExists(atPath: tempURL.path) { return tempURL }
        tempURL = try? ImageExporter.writeTemporary(image, scale: scale, date: date)
        return tempURL
    }

    @discardableResult
    func saveToDefaultLocation() throws -> URL {
        if let savedURL, FileManager.default.fileExists(atPath: savedURL.path) { return savedURL }
        let url = try ImageExporter.save(image, scale: scale, date: date)
        savedURL = url
        return url
    }
}

@MainActor
enum ImageExporter {
    static func filename(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Glimpse \(f.string(from: date))"
    }

    /// Applies the "save at 1x" preference.
    static func outputImage(_ image: CGImage, scale: CGFloat) -> (CGImage, CGFloat) {
        guard Preferences.shared.saveAt1x, scale > 1 else { return (image, scale) }
        let w = Int((CGFloat(image.width) / scale).rounded())
        let h = Int((CGFloat(image.height) / scale).rounded())
        return (ImageUtil.resized(image, toPixelWidth: w, height: h), 1)
    }

    static func encode(_ image: CGImage, scale: CGFloat, format: ImageFormat) -> Data? {
        let (out, outScale) = outputImage(image, scale: scale)
        let data = NSMutableData()
        let type = (format == .png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * outScale,
            kCGImagePropertyDPIHeight: 72 * outScale,
        ]
        var toWrite = out
        if format == .jpeg {
            props[kCGImageDestinationLossyCompressionQuality] = Preferences.shared.jpegQuality
            toWrite = flattened(out) ?? out
        }
        CGImageDestinationAddImage(dest, toWrite, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// JPEG has no alpha: composite over white.
    nonisolated static func flattened(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageUtil.bitmapSpace(for: image),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let r = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(r)
        ctx.draw(image, in: r)
        return ctx.makeImage()
    }

    static func write(_ image: CGImage, scale: CGFloat, to url: URL) throws {
        let format: ImageFormat = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
        guard let data = encode(image, scale: scale, format: format) else {
            throw NSError(domain: "Glimpse", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode image"])
        }
        try data.write(to: url, options: .atomic)
    }

    static func uniqueURL(in directory: URL, base: String, ext: String) -> URL {
        var url = directory.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    static func save(_ image: CGImage, scale: CGFloat, date: Date = Date()) throws -> URL {
        let prefs = Preferences.shared
        let dir = prefs.saveDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = uniqueURL(in: dir, base: filename(for: date), ext: prefs.imageFormat.fileExtension)
        try write(image, scale: scale, to: url)
        return url
    }

    static func writeTemporary(_ image: CGImage, scale: CGFloat, date: Date = Date()) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Glimpse", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename(for: date)).appendingPathExtension(Preferences.shared.imageFormat.fileExtension)
        try write(image, scale: scale, to: url)
        return url
    }

    static func saveAs(_ image: CGImage, scale: CGFloat, date: Date = Date(), window: NSWindow? = nil,
                       completion: ((URL) -> Void)? = nil) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = filename(for: date) + "." + Preferences.shared.imageFormat.fileExtension
        panel.directoryURL = Preferences.shared.saveDirectory
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try write(image, scale: scale, to: url)
                completion?(url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    /// Removes temporary drag files from previous runs.
    static func cleanTemporaryFiles() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Glimpse", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }
}

@MainActor
enum Clipboard {
    static func copy(_ image: CGImage, scale: CGFloat) {
        let (out, outScale) = ImageExporter.outputImage(image, scale: scale)
        let pb = NSPasteboard.general
        pb.clearContents()
        let size = CGSize(width: CGFloat(out.width) / outScale, height: CGFloat(out.height) / outScale)
        let rep = NSBitmapImageRep(cgImage: out)
        rep.size = size
        let item = NSPasteboardItem()
        if let png = rep.representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
        }
        if let tiff = rep.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pb.writeObjects([item])
    }

    static func copy(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func image() -> (CGImage, CGFloat)? {
        let pb = NSPasteboard.general
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type), let loaded = ImageUtil.load(data: data) { return loaded }
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let first = urls.first, let loaded = ImageUtil.load(url: first) {
            return loaded
        }
        if let image = NSImage(pasteboard: pb), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return (cg, max(1, CGFloat(cg.width) / max(image.size.width, 1)))
        }
        return nil
    }
}

@MainActor
enum Sound {
    private static let shutter: NSSound? = {
        let paths = [
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif",
        ]
        for p in paths where FileManager.default.fileExists(atPath: p) {
            return NSSound(contentsOfFile: p, byReference: true)
        }
        return NSSound(named: "Pop")
    }()

    static func playShutter() {
        guard Preferences.shared.playSound, let s = shutter else { return }
        s.stop()
        s.play()
    }
}
