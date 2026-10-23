import Foundation

public enum FileNaming {
    /// `yyyyMMddHHmm` in the local time zone.
    public static func timestampPrefix(for date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMddHHmm"
        return f.string(from: date)
    }

    /// `yyyy-MM-dd` day folder name.
    public static func dayFolder(for date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Filesystem-safe slug: "1:1 with Bob / Q3" → "1-1-with-Bob-Q3".
    public static func slug(_ title: String, maxLength: Int = 80) -> String {
        let allowed = CharacterSet.alphanumerics
        var out = ""
        var lastWasDash = false
        for scalar in title.unicodeScalars {
            if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > maxLength {
            out = String(out.prefix(maxLength))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out.isEmpty ? "Meeting" : out
    }

    /// `<yyyyMMddHHmm>-<slug>.<ext>`
    public static func baseName(date: Date, title: String, ext: String, timeZone: TimeZone = .current) -> String {
        "\(timestampPrefix(for: date, timeZone: timeZone))-\(slug(title)).\(ext)"
    }

    /// Returns `directory/name` if free, otherwise appends `-2`, `-3`, … before the extension
    /// so nothing is ever overwritten.
    public static func uniqueFileURL(
        in directory: URL, name: String,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let candidate = directory.appendingPathComponent(name)
        if !exists(candidate) { return candidate }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let next = directory.appendingPathComponent(ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)")
            if !exists(next) { return next }
            n += 1
        }
    }
}
