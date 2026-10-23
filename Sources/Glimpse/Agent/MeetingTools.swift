import Foundation
import Meetings

/// MCP tools over recorded meetings.
enum MeetingTools {
    static var definitions: [[String: Any]] {
        [
            [
                "name": "meeting_transcript",
                "description": "Returns a recorded meeting's speaker-labelled transcript. Pick the meeting by a time inside it, "
                    + "or by title; with neither, lists the meetings recorded that day (time, title, attendees).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
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
        case "meeting_transcript": return transcript(args)
        default: return nil
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
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

    @MainActor
    private static func transcript(_ args: [String: Any]) -> [String: Any] {
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
            let maxChars = max(1000, (args["max_chars"] as? NSNumber)?.intValue ?? 30_000)
            lines.append("Transcript (\(path)):")
            lines.append(text.count > maxChars ? String(text.prefix(maxChars)) + "\n… (truncated; raise max_chars)" : text)
        } else {
            lines.append("No transcript yet (\(m.status)).")
        }
        return AgentTools.text(lines.joined(separator: "\n"))
    }
}
