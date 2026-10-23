import Foundation

/// Meetings debug log (~/Library/Logs/Glimpse/meetings.log). Lines are prefixed with an
/// emoji per component and mirrored to stdout.
enum Log {
    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Glimpse")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("meetings.log")
    }()

    private static let queue = DispatchQueue(label: "glimpse.meetings.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static let instanceTag = MeetingsHost.isUITestMode ? "[dev] " : ""

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(instanceTag)\(message)\n"
        print(line, terminator: "")
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}

/// Shorthand used throughout the app.
func log(_ message: String) {
    Log.write(message)
}
