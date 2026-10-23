import Foundation
import Meetings

/// MCP tools over recorded meetings: search the transcripts, then read one.
enum MeetingTools {
    static var definitions: [[String: Any]] {
        [
            [
                "name": "meeting_search",
                "description": "Searches the user's recorded meeting transcripts. Matches every word of query (\"quoted phrases\" "
                    + "stay together; case and accents ignored) in the title, attendees or what was said, optionally only "
                    + "meetings with an attendee or between two dates. Returns matching meetings newest first with date, "
                    + "title, duration, attendees, transcript path and the paragraphs that matched, labelled by speaker. "
                    + "With no query, lists meetings. Read a whole one with meeting_transcript and its path.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Words or \"phrases\" to find; all must appear."],
                        "attendee": ["type": "string", "description": "Part of an attendee's name or email."],
                        "from": ["type": "string", "description": "First day, yyyy-MM-dd (inclusive)."],
                        "to": ["type": "string", "description": "Last day, yyyy-MM-dd (inclusive)."],
                        "limit": ["type": "integer", "description": "At most this many meetings (default 20, max 100)."],
                        "snippets": ["type": "integer", "description": "Matching paragraphs shown per meeting (default 3, 0 for none)."],
                    ],
                ],
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "meeting_transcript",
                "description": "Returns a recorded meeting's speaker-labelled transcript. Pass a path from meeting_search, or pick "
                    + "the meeting by a time inside it or by title on a date; with none of these, lists the meetings "
                    + "recorded that day (time, title, attendees).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Transcript path from meeting_search."],
                        "time": ["type": "string", "description": "HH:mm, any time during the meeting."],
                        "title": ["type": "string", "description": "Part of the meeting title (latest match on the date)."],
                        "date": ["type": "string", "description": "yyyy-MM-dd (default today)."],
                        "max_chars": ["type": "integer", "description": "Transcript characters to return (default 30000)."],
                    ],
                ],
                "annotations": ["readOnlyHint": true],
            ],
        ]
    }

    /// nil when `name` isn't a meeting tool.
    @MainActor
    static func call(_ name: String, _ args: [String: Any]) async -> [String: Any]? {
        switch name {
        case "meeting_search":
            // Reading and searching every transcript can take a moment; keep it off the main thread.
            return await Task.detached(priority: .userInitiated) { search(args) }.value
        case "meeting_transcript": return transcript(args)
        default: return nil
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        // Days where DST starts at midnight have no 00:00.
        f.isLenient = true
        return f
    }()

    private static func describe(_ m: MeetingRecord) -> String {
        let hm = DateFormatter()
        hm.locale = Locale(identifier: "en_US_POSIX")
        hm.dateFormat = "HH:mm"
        var line = "\(hm.string(from: m.start))–\(hm.string(from: m.end)) \(m.title)"
        if !m.attendees.isEmpty {
            let shown = m.attendees.prefix(8).joined(separator: ", ")
            line += " — with " + shown + (m.attendees.count > 8 ? " and \(m.attendees.count - 8) more" : "")
        }
        if m.status != "completed" { line += " (\(m.status))" }
        return line
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static func describe(_ file: TranscriptFile) -> String {
        var parts = [file.date.map { stamp.string(from: $0) } ?? "undated", file.title]
        if let minutes = file.durationMinutes { parts.append("\(minutes) min") }
        var line = parts.joined(separator: " · ")
        if !file.attendees.isEmpty {
            let shown = file.attendees.prefix(8).joined(separator: ", ")
            line += " · with " + shown + (file.attendees.count > 8 ? " and \(file.attendees.count - 8) more" : "")
        }
        return line
    }

    nonisolated private static func search(_ args: [String: Any]) -> [String: Any] {
        func day(_ key: String) -> (Date?, String?) {
            guard let s = args[key] as? String, !s.isEmpty else { return (nil, nil) }
            guard let d = dayFormatter.date(from: s) else { return (nil, "\(key) must be yyyy-MM-dd.") }
            return (d, nil)
        }
        let (from, fromError) = day("from"), (to, toError) = day("to")
        if let error = fromError ?? toError { return AgentTools.error(error) }
        if let from, let to, from > to { return AgentTools.error("from is after to.") }
        let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let attendee = (args["attendee"] as? String) ?? ""
        let limit = min(100, max(1, (args["limit"] as? NSNumber)?.intValue ?? 20))
        let snippets = min(20, max(0, (args["snippets"] as? NSNumber)?.intValue ?? 3))

        let root = DataFolder.meetings
        let files = TranscriptSearch.all(in: root)
        guard !files.isEmpty else {
            return AgentTools.text("No meeting transcripts in \(root.path). Turn on Glimpse Settings › Meetings to record meetings.")
        }
        let hits = TranscriptSearch.search(files, query: query, attendee: attendee, from: from, to: to, maxSnippets: snippets)

        var filters: [String] = []
        if !query.isEmpty { filters.append("matching \(query)") }
        if !attendee.isEmpty { filters.append("with \(attendee)") }
        if let from = args["from"] as? String, !from.isEmpty { filters.append("from \(from)") }
        if let to = args["to"] as? String, !to.isEmpty { filters.append("to \(to)") }
        let scope = filters.isEmpty ? "" : " " + filters.joined(separator: ", ")
        guard !hits.isEmpty else {
            return AgentTools.text("No meetings\(scope), out of \(files.count) transcripts in \(root.path).")
        }

        var lines = ["\(hits.count) meeting\(hits.count == 1 ? "" : "s")\(scope), newest first"
            + (hits.count > limit ? " (showing \(limit); narrow the search or raise limit)" : "") + ":"]
        for hit in hits.prefix(limit) {
            lines.append("")
            lines.append(describe(hit.file))
            lines.append("  path: \(hit.file.url.path)")
            if !query.isEmpty {
                lines.append(hit.matchingParagraphs == 0 ? "  matched in the title or attendees"
                    : "  matching paragraphs: \(hit.matchingParagraphs)")
                for snippet in hit.snippets { lines.append("  > " + snippet) }
            }
        }
        return AgentTools.text(lines.joined(separator: "\n"))
    }

    private static func transcript(path: String, maxChars: Int) -> [String: Any] {
        let expanded = (path as NSString).expandingTildeInPath
        // Relative paths are relative to the meetings folder, not the app's working directory.
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : DataFolder.meetings.appendingPathComponent(expanded)
        guard TranscriptSearch.isInside(url, root: DataFolder.meetings), url.pathExtension.lowercased() == "md" else {
            return AgentTools.error("path must be a transcript from meeting_search.")
        }
        guard let file = TranscriptSearch.load(url) else { return AgentTools.error("No transcript at \(url.path).") }
        var header = ["# \(file.title)", ""]
        if let date = file.date { header.append("**Date:** \(stamp.string(from: date))") }
        if let minutes = file.durationMinutes { header.append("**Duration:** \(minutes) minutes") }
        if !file.attendees.isEmpty { header.append("**Attendees:** \(file.attendees.joined(separator: ", "))") }
        if let link = file.meetingURL { header.append("**Meeting URL:** \(link)") }
        let text = (header + ["", "---", "", file.body]).joined(separator: "\n")
        return AgentTools.text(["Meeting: " + describe(file), "", "Transcript (\(url.path)):",
                                text.count > maxChars ? String(text.prefix(maxChars)) + "\n… (truncated; raise max_chars)" : text]
            .joined(separator: "\n"))
    }

    @MainActor
    private static func transcript(_ args: [String: Any]) -> [String: Any] {
        let maxChars = max(1000, (args["max_chars"] as? NSNumber)?.intValue ?? 30_000)
        if let path = args["path"] as? String, !path.isEmpty { return transcript(path: path, maxChars: maxChars) }
        let dayString = (args["date"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? dayFormatter.string(from: Date())
        guard let day = dayFormatter.date(from: dayString) else { return AgentTools.error("date must be yyyy-MM-dd.") }
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: day)!.addingTimeInterval(-1)
        let all = Meetings.records(from: day, to: dayEnd)
        let list = all.isEmpty ? "none" : all.map { describe($0) }.joined(separator: "\n  ")

        var match: MeetingRecord?
        if let time = args["time"] as? String, !time.isEmpty {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm"
            guard let moment = f.date(from: "\(dayString) \(time.prefix(5))") else { return AgentTools.error("time must be HH:mm.") }
            match = all.last { $0.start <= moment && moment <= $0.end }
        } else if let title = args["title"] as? String, !title.isEmpty {
            match = all.last { $0.title.localizedCaseInsensitiveContains(title) }
        } else {
            return AgentTools.text("Meetings recorded on \(dayString):\n  \(list)\nPass time or title for a transcript.")
        }
        guard let m = match else {
            return AgentTools.error("No recorded meeting matches on \(dayString). Meetings that day:\n  \(list)")
        }

        var lines = ["Meeting: " + describe(m), ""]
        if let path = m.transcriptPath, let text = try? String(contentsOfFile: path, encoding: .utf8) {
            lines.append("Transcript (\(path)):")
            lines.append(text.count > maxChars ? String(text.prefix(maxChars)) + "\n… (truncated; raise max_chars)" : text)
        } else {
            lines.append("No transcript yet (\(m.status)).")
        }
        return AgentTools.text(lines.joined(separator: "\n"))
    }
}
