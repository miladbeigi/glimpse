import AppKit
import Combine
import CryptoKit
import Foundation

struct AppRelease: Sendable, Equatable {
    let version: String
    let zipURL: URL
    let checksumURL: URL?
    let pageURL: URL?
}

enum UpdateError: LocalizedError {
    case notConfigured
    case noAsset
    case checksumMismatch
    case badArchive
    case notWritable(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Updates aren't configured for this build."
        case .noAsset: return "The latest release has no app download."
        case .checksumMismatch: return "Downloaded update failed its checksum; not installed."
        case .badArchive: return "Downloaded update didn't contain Glimpse."
        case .notWritable(let path): return "Can't replace the app at \(path). Move it to ~/Applications or /Applications."
        }
    }
}

/// Self-update from GitHub Releases.
/// A release carries `Glimpse-<version>.zip` (containing Glimpse.app) and its `.zip.sha256`.
enum Updater {
    /// "owner/repo", baked into Info.plist by scripts/build.sh. Missing for local builds without a remote.
    static var repository: String? {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["UPDATE_REPO"] { return override }
        #endif
        let value = Bundle.main.object(forInfoDictionaryKey: "UpdateRepository") as? String
        return value?.isEmpty == false ? value : nil
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func latestRelease() async throws -> AppRelease? {
        guard let repository else { throw UpdateError.notConfigured }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Glimpse/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try parseRelease(data)
    }

    static func parseRelease(_ data: Data) throws -> AppRelease? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        func asset(_ match: (String) -> Bool) -> URL? {
            assets.first { match($0["name"] as? String ?? "") }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }
        guard let zip = asset({ $0.hasPrefix("Glimpse") && $0.hasSuffix(".zip") }) else { throw UpdateError.noAsset }
        return AppRelease(
            version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
            zipURL: zip,
            checksumURL: asset { $0.hasSuffix(".zip.sha256") },
            pageURL: (json["html_url"] as? String).flatMap(URL.init(string:))
        )
    }

    /// Numeric, dot-separated comparison: "1.10.0" > "1.9.2".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Downloads, verifies and stages the new app, then swaps it in after this process exits and relaunches.
    static func install(_ release: AppRelease) async throws {
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notWritable(current.path)
        }

        let (zip, _) = try await URLSession.shared.download(from: release.zipURL)
        if let checksumURL = release.checksumURL {
            let (sumData, _) = try await URLSession.shared.data(from: checksumURL)
            let expected = String(decoding: sumData, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
            let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
            guard expected.lowercased() == actual else { throw UpdateError.checksumMismatch }
        }

        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("Glimpse-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
        let contents = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        guard let newApp = contents.first(where: { $0.pathExtension == "app" }),
              let bundle = Bundle(url: newApp), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError.badArchive
        }
        let destination = parent.appendingPathComponent(newApp.lastPathComponent)

        // Wait for us to quit, put the new bundle in place (removing ours if it was renamed), relaunch.
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "$3.old"
        [ -e "$3" ] && mv "$3" "$3.old"
        mv "$1" "$3" && rm -rf "$3.old" "$4"
        [ "$2" != "$3" ] && rm -rf "$2"
        xattr -dr com.apple.quarantine "$3" 2>/dev/null
        open "$3"
        """
        let swapper = Process()
        swapper.executableURL = URL(fileURLWithPath: "/bin/sh")
        swapper.arguments = ["-c", script, "sh", newApp.path, current.path, destination.path, staging.path]
        try swapper.run()
        await MainActor.run { NSApp.terminate(nil) }
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.badArchive }
    }
}

/// Checks for updates at launch and every 6 hours (unless turned off), and drives the Settings / menu UI.
@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    @Published private(set) var availableUpdate: AppRelease?
    @Published private(set) var status: String?
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    @Published var checkAutomatically: Bool {
        didSet {
            UserDefaults.standard.set(checkAutomatically, forKey: "checkForUpdates")
            if checkAutomatically { Task { await check(manual: false) } }
        }
    }

    private var timer: Timer?

    private init() {
        checkAutomatically = UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true
    }

    func start() {
        guard Updater.repository != nil else { return }
        if checkAutomatically { Task { await check(manual: false) } }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in
                let controller = UpdateController.shared
                if controller.checkAutomatically { await controller.check(manual: false) }
            }
        }
    }

    func check(manual: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        if manual { status = nil }
        do {
            let release = try await Updater.latestRelease()
            if let release, Updater.isNewer(release.version, than: Updater.currentVersion) {
                availableUpdate = release
                status = nil
            } else {
                availableUpdate = nil
                if manual { showTransientStatus("You're on the latest version.") }
            }
        } catch {
            if manual { status = error.localizedDescription }
        }
    }

    func install() async {
        guard let release = availableUpdate, !isInstalling else { return }
        isInstalling = true
        status = "Downloading \(release.version)…"
        do {
            try await Updater.install(release) // quits and relaunches on success
        } catch {
            isInstalling = false
            status = error.localizedDescription
        }
    }

    /// Shows a status line that clears itself after a few seconds, unless something replaced it.
    private func showTransientStatus(_ message: String) {
        status = message
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if status == message { status = nil }
        }
    }
}
