import Foundation

/// A transcript file as written by MarkdownWriter: `# Title`, then `**Date:**`, `**Duration:**`,
/// `**Attendees:**` and `**Meeting URL:**` lines, a `---` rule and the speaker paragraphs.
public struct TranscriptFile: Sendable, Equatable {
    public var url: URL
    public var title: String
    /// From the Date line, else the file name's yyyyMMddHHmm prefix, else its yyyy-MM-dd folder.
    public var date: Date?
    public var durationMinutes: Int?
    public var attendees: [String]
    public var meetingURL: String?
    /// Everything after the header rule.
    public var body: String
}

public struct TranscriptHit: Sendable, Equatable {
    public var file: TranscriptFile
    /// Paragraphs containing a search term, in transcript order, trimmed around the first match.
    public var snippets: [String]
    /// How many paragraphs contain a search term.
    public var matchingParagraphs: Int
}

/// Finds meetings in the transcripts folder by text, attendee and date. Reads the files
/// themselves, so transcripts from before the history database are found too.
public enum TranscriptSearch {
    /// Files larger than this are not transcripts.
    static let maxFileSize = 5_000_000

    /// Every transcript under `root`, newest first (undated ones last). Skips hidden files and
    /// packages such as .app bundles.
    public static func all(in root: URL) -> [TranscriptFile] {
        // The enumerator doesn't descend into a root that is itself a symlink.
        let root = root.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [TranscriptFile] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "md" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  (values.fileSize ?? 0) <= maxFileSize, let file = load(url) else { continue }
            files.append(file)
        }
        return files.sorted { a, b in
            switch (a.date, b.date) {
            case let (x?, y?): return x != y ? x > y : a.url.path < b.url.path
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.url.path < b.url.path
            }
        }
    }

    public static func load(_ url: URL) -> TranscriptFile? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxFileSize,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text, url: url)
    }

    static func parse(_ text: String, url: URL) -> TranscriptFile {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        var title = url.deletingPathExtension().lastPathComponent
        var date: Date?
        var duration: Int?
        var attendees: [String] = []
        var meetingURL: String?
        var body = text

        let lines = text.components(separatedBy: "\n")
        // A Glimpse header is only `# Title` and `**Key:** value` lines before the rule; anything else
        // (hand-written notes with a `---` divider) is all body.
        if let rule = lines.prefix(20).firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
           lines[..<rule].allSatisfy({ line in
               let l = line.trimmingCharacters(in: .whitespaces)
               return l.isEmpty || l.hasPrefix("# ") || l.hasPrefix("**")
           }) {
            for line in lines[..<rule] {
                if line.hasPrefix("# ") {
                    title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                } else if let v = value(line, "Date") {
                    date = headerDate.date(from: v)
                } else if let v = value(line, "Duration") {
                    duration = Int(v.prefix { $0.isNumber })
                } else if let v = value(line, "Attendees") {
                    attendees = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                } else if let v = value(line, "Meeting URL") {
                    meetingURL = v
                }
            }
            body = lines[(rule + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if date == nil { date = dateFromName(url) }
        return TranscriptFile(url: url, title: title, date: date, durationMinutes: duration, attendees: attendees,
                              meetingURL: meetingURL, body: body)
    }

    /// Transcripts matching every term in `query` (in the title, attendees or text), an attendee
    /// substring, and the `from...to` days (inclusive; undated transcripts are left out when either is set).
    public static func search(_ files: [TranscriptFile], query: String? = nil, attendee: String? = nil,
                              from: Date? = nil, to: Date? = nil, maxSnippets: Int = 3, snippetLength: Int = 280) -> [TranscriptHit] {
        let terms = self.terms(query ?? "")
        let folded = terms.map(fold)
        let attendee = attendee?.trimmingCharacters(in: .whitespaces) ?? ""
        let end = to.flatMap { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: $0)) }
        let start = from.map { Calendar.current.startOfDay(for: $0) }

        return files.compactMap { file -> TranscriptHit? in
            if start != nil || end != nil {
                guard let date = file.date else { return nil }
                if let start, date < start { return nil }
                if let end, date >= end { return nil }
            }
            if !attendee.isEmpty, !file.attendees.contains(where: { contains($0, attendee) }) { return nil }
            // Fold case and accents once per transcript, then search literally: much faster than
            // case- and diacritic-insensitive range(of:) for every term.
            let haystack = fold(([file.title] + file.attendees + [file.body]).joined(separator: "\n"))
            guard folded.allSatisfy({ haystack.contains($0) }) else { return nil }

            var snippets: [String] = []
            var matching = 0
            if !terms.isEmpty {
                for paragraph in file.body.components(separatedBy: "\n\n") {
                    let foldedParagraph = fold(paragraph)
                    guard let index = folded.firstIndex(where: { foldedParagraph.contains($0) }) else { continue }
                    let term = terms[index]
                    matching += 1
                    if snippets.count < maxSnippets { snippets.append(excerpt(paragraph, around: term, length: snippetLength)) }
                }
            }
            return TranscriptHit(file: file, snippets: snippets, matchingParagraphs: matching)
        }
    }

    /// Whether `url` is inside `root`, following symlinks (~/Meetings may point at the data folder).
    public static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// Words, with "double-quoted phrases" kept whole.
    static func terms(_ query: String) -> [String] {
        var out: [String] = []
        for (i, part) in query.components(separatedBy: "\"").enumerated() {
            if i % 2 == 1 {
                let phrase = part.trimmingCharacters(in: .whitespaces)
                if !phrase.isEmpty { out.append(phrase) }
            } else {
                out += part.split(whereSeparator: \.isWhitespace).map(String.init)
            }
        }
        return out
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func contains(_ text: String, _ term: String) -> Bool {
        text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// The paragraph, cut to about `length` characters around the first match, keeping its `**Speaker:**` label.
    static func excerpt(_ paragraph: String, around term: String, length: Int) -> String {
        let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard text.count > length, let match = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return text
        }
        var label = ""
        var content = Substring(text)
        if text.hasPrefix("**"), let close = text.range(of: ":**"),
           text.distance(from: text.startIndex, to: close.lowerBound) <= 60 {
            label = String(text[..<close.upperBound]) + " "
            content = text[close.upperBound...].drop { $0 == " " }
        }
        let offset = content.distance(from: content.startIndex, to: max(match.lowerBound, content.startIndex))
        let lead = max(0, offset - length / 3)
        let from = content.index(content.startIndex, offsetBy: lead)
        let to = content.index(from, offsetBy: length, limitedBy: content.endIndex) ?? content.endIndex
        return label + (lead > 0 ? "…" : "") + content[from..<to] + (to < content.endIndex ? "…" : "")
    }

    private static func value(_ line: String, _ key: String) -> String? {
        let prefix = "**\(key):**"
        guard line.hasPrefix(prefix) else { return nil }
        return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }

    private static let headerDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static func dateFromName(_ url: URL) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let name = url.lastPathComponent
        if name.count >= 12, name.prefix(12).allSatisfy(\.isNumber) {
            f.dateFormat = "yyyyMMddHHmm"
            if let d = f.date(from: String(name.prefix(12))) { return d }
        }
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: url.deletingLastPathComponent().lastPathComponent)
    }
}
