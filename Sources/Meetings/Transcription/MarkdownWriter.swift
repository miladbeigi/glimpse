import Foundation
import MeetingDetection

/// Renders the markdown transcript.
enum MarkdownWriter {
    static func render(meeting: Meeting, duration: TimeInterval, attendees: [String], segments: [LabeledSegment]) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"

        let minutes = max(1, Int((duration / 60).rounded()))
        var out = "# \(meeting.title)\n\n"
        out += "**Date:** \(df.string(from: meeting.start))\n"
        out += "**Duration:** \(minutes) minute\(minutes == 1 ? "" : "s")\n"
        if !attendees.isEmpty { out += "**Attendees:** \(attendees.joined(separator: ", "))\n" }
        if let url = meeting.meetingURL, !url.isEmpty { out += "**Meeting URL:** \(url)\n" }
        out += "\n---\n\n"

        for paragraph in paragraphs(segments) {
            out += "**\(paragraph.speaker):** \(paragraph.text)\n\n"
        }
        return out
    }

    /// Merge consecutive segments of the same identified speaker. "Unknown" is never merged:
    /// consecutive unknowns may be different people or crosstalk.
    static func paragraphs(_ segments: [LabeledSegment]) -> [(speaker: String, text: String)] {
        var result: [(speaker: String, text: String)] = []
        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = result.last, last.speaker == seg.speaker, seg.speaker != SpeakerIdentifier.unknown {
                result[result.count - 1].text += " " + text
            } else {
                result.append((seg.speaker, text))
            }
        }
        return result
    }

    /// Write into `<output>/<yyyy-MM-dd>/<yyyyMMddHHmm>-<slug>.md`, never overwriting.
    static func write(_ markdown: String, meeting: Meeting, outputRoot: URL) throws -> URL {
        let dir = outputRoot.appendingPathComponent(FileNaming.dayFolder(for: meeting.start), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = FileNaming.uniqueFileURL(in: dir, name: FileNaming.baseName(date: meeting.start, title: meeting.title, ext: "md"))
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
