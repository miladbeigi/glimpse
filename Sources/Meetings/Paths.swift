import Foundation

/// Where Glimpse keeps meetings: the transcripts you browse (and point other tools at) under one
/// data folder, the app's own state in Application Support.
public enum DataFolder {
    public static let defaultsKey = "dataFolder"
    public static var defaultPath: String { "~/Glimpse" }

    /// The data folder (default ~/Glimpse), holding Meetings/.
    public static var root: URL {
        let path = UserDefaults.standard.string(forKey: defaultsKey) ?? defaultPath
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Meeting transcripts: <yyyy-MM-dd>/<time>-<title>.md.
    public static var meetings: URL { root.appendingPathComponent("Meetings", isDirectory: true) }
}

enum Paths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// ~/Library/Application Support/Glimpse/Meetings: history, settings, recordings, voices, calendar sign-in.
    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Glimpse/Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var settingsFile: URL { applicationSupport.appendingPathComponent("settings.json") }
    static var historyDatabase: URL { applicationSupport.appendingPathComponent("history.db") }

    static var recordingsStore: URL {
        let dir = applicationSupport.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Live recording spools. Not in the temp directory: macOS may purge that, and these are
    /// what a crash leaves behind for recovery on next launch.
    static var inProgressRecordings: URL {
        let dir = applicationSupport.appendingPathComponent("in-progress", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var tempRecordings: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glimpse-meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Voice profiles ({name}.json), kept out of the data folder.
    static var voiceProfiles: URL { applicationSupport.appendingPathComponent("voices", isDirectory: true) }

    /// Google OAuth client (Desktop app) downloaded from the Cloud console.
    static var calendarCredentials: URL { applicationSupport.appendingPathComponent("google-credentials.json") }
    static var calendarToken: URL { applicationSupport.appendingPathComponent("google-token.json") }

    /// `~`-abbreviated path for display, so UI and logs don't show the user's home directory.
    static func display(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }

    /// Expand a leading `~`.
    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }
}
