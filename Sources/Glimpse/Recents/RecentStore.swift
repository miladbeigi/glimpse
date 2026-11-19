import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

/// The recent screenshots behind the stack (double-tap right Shift): every capture, stitched image and image an agent
/// shows you, newest last. Each one is kept in `~/Library/Application Support/Glimpse/Recent/<id>/` (the original,
/// the marked-up image and the marks themselves, so they stay editable) unless that's turned off in Settings.
@MainActor
final class RecentStore: ObservableObject {
    static let shared = RecentStore()

    static let limit = 30

    /// Oldest first.
    @Published private(set) var captures: [Capture] = []
    /// Small previews for the cards, keyed by capture id.
    private(set) var thumbnails: [UUID: CGImage] = [:]

    private let writer = DispatchQueue(label: "Glimpse.RecentStore", qos: .utility)
    private var loaded = false

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glimpse", isDirectory: true)
            .appendingPathComponent("Recent", isDirectory: true)
    }

    /// Debug scenarios keep the stack in memory so they never touch the real folder.
    var inMemoryOnly = false

    private var keepsFiles: Bool { Preferences.shared.keepRecentScreenshots && !inMemoryOnly }

    // MARK: Loading

    /// Reads the folder once (at launch).
    func load() {
        guard !loaded else { return }
        loaded = true
        guard !inMemoryOnly else { return }
        guard keepsFiles else { return }
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil) else { return }
        var restored: [Capture] = []
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent),
                  let metaData = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
                  let meta = try? JSONDecoder().decode(Meta.self, from: metaData),
                  let base = Self.lazyImage(dir.appendingPathComponent("base.png")) else {
                try? fm.removeItem(at: dir)
                continue
            }
            let rendered = Self.lazyImage(dir.appendingPathComponent("image.png")) ?? base
            let document = (try? Data(contentsOf: dir.appendingPathComponent("marks.json")))
                .flatMap { try? JSONDecoder().decode(EditorDocumentState.self, from: $0) }
            let capture = Capture(base: base, rendered: rendered, scale: meta.scale, document: document, id: id, date: meta.date)
            capture.author = meta.author
            capture.label = meta.label
            if let path = meta.savedPath, fm.fileExists(atPath: path) { capture.savedURL = URL(fileURLWithPath: path) }
            restored.append(capture)
            if let thumb = Self.thumbnail(at: dir.appendingPathComponent("image.png"))
                ?? Self.thumbnail(at: dir.appendingPathComponent("base.png")) {
                thumbnails[id] = thumb
            }
        }
        restored.sort { $0.date < $1.date }
        captures = Array(restored.suffix(Self.limit))
        for old in restored.dropLast(Self.limit) { removeFiles(old.id) }
    }

    // MARK: Changes

    func add(_ capture: Capture) {
        load()
        guard !contains(capture) else { return captureDidChange(capture) }
        captures.append(capture)
        thumbnails[capture.id] = Self.makeThumbnail(capture.image)
        while captures.count > Self.limit {
            let old = captures.removeFirst()
            thumbnails[old.id] = nil
            removeFiles(old.id)
        }
        persist(capture, includingBase: true)
    }

    func contains(_ capture: Capture) -> Bool { captures.contains { $0 === capture } }

    func capture(id: UUID) -> Capture? { captures.first { $0.id == id } }

    /// Called by `Capture.update` after the editor or an agent changed it.
    func captureDidChange(_ capture: Capture) {
        guard contains(capture) else { return }
        thumbnails[capture.id] = Self.makeThumbnail(capture.image)
        persist(capture, includingBase: false)
        objectWillChange.send()
    }

    func remove(_ ids: Set<UUID>) {
        captures.removeAll { ids.contains($0.id) }
        for id in ids {
            thumbnails[id] = nil
            removeFiles(id)
        }
    }

    /// Settings › "Keep recent screenshots" turned off: forget the files (the cards stay for this session).
    func deleteAllFiles() {
        let dir = Self.directory
        writer.async { try? FileManager.default.removeItem(at: dir) }
    }

    /// Settings › "Keep recent screenshots" turned on: write what's in memory now.
    func persistAll() {
        for capture in captures { persist(capture, includingBase: true) }
    }

    // MARK: Files

    private struct Meta: Codable {
        var date: Date
        var scale: CGFloat
        var author: String?
        var label: String?
        var savedPath: String?
    }

    private func persist(_ capture: Capture, includingBase: Bool) {
        guard keepsFiles else { return }
        let dir = Self.directory.appendingPathComponent(capture.id.uuidString, isDirectory: true)
        let meta = Meta(date: capture.date, scale: capture.scale, author: capture.author, label: capture.label,
                        savedPath: capture.savedURL?.path)
        let base = includingBase ? capture.baseImage : nil
        let rendered = capture.image
        let marks = capture.document.flatMap { try? JSONEncoder().encode($0) }
        writer.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let base { Self.writePNG(base, to: dir.appendingPathComponent("base.png")) }
            if rendered !== base { Self.writePNG(rendered, to: dir.appendingPathComponent("image.png")) }
            if let marks { try? marks.write(to: dir.appendingPathComponent("marks.json"), options: .atomic) }
            if let data = try? JSONEncoder().encode(meta) {
                try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
            }
        }
    }

    private func removeFiles(_ id: UUID) {
        let dir = Self.directory.appendingPathComponent(id.uuidString, isDirectory: true)
        writer.async { try? FileManager.default.removeItem(at: dir) }
    }

    /// Waits for pending writes (tests and quitting).
    func flush() { writer.sync {} }

    nonisolated private static func writePNG(_ image: CGImage, to url: URL) {
        let tmp = url.appendingPathExtension("tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// Decodes on first draw rather than now.
    nonisolated private static func lazyImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: false] as CFDictionary)
    }

    nonisolated static let thumbnailSize = 640

    nonisolated private static func thumbnail(at url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    static func makeThumbnail(_ image: CGImage) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > thumbnailSize else { return image }
        let f = CGFloat(thumbnailSize) / CGFloat(longest)
        return ImageUtil.resized(image, toPixelWidth: max(1, Int(CGFloat(image.width) * f)),
                                 height: max(1, Int(CGFloat(image.height) * f)))
    }
}
