import Foundation

enum MeetingType: String, Codable, Sendable {
    case googleMeet = "Google Meet"
    case zoom = "Zoom"
    case teams = "Teams"
    case slack = "Slack"
    case unknown = "Unknown"

    static func from(url: String?) -> MeetingType {
        guard let url = url?.lowercased() else { return .unknown }
        if url.contains("meet.google.com") { return .googleMeet }
        if url.contains("zoom.us") { return .zoom }
        if url.contains("teams.microsoft.com") || url.contains("teams.live.com") { return .teams }
        if url.contains("slack.com") { return .slack }
        return .unknown
    }
}

/// A meeting, from the calendar or auto-detected.
struct Meeting: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var attendees: [String]
    var meetingURL: String?
    var type: MeetingType
    /// True when this meeting came from a calendar event.
    var fromCalendar: Bool

    var durationMinutes: Int { max(1, Int((end.timeIntervalSince(start) / 60).rounded())) }

    static func adHoc(title: String, start: Date = Date()) -> Meeting {
        Meeting(
            id: "adhoc-\(Int(start.timeIntervalSince1970))",
            title: title, start: start, end: start.addingTimeInterval(3600),
            attendees: [], meetingURL: nil, type: .unknown, fromCalendar: false)
    }
}

extension Meeting {
    /// When the meeting is, for the menu: "Now" while it runs, the time today, "Tomorrow 2:00 PM",
    /// or the weekday and time further out. The menu lists 24 hours ahead, so a recurring meeting
    /// can appear twice at the same time of day; the day keeps the two apart.
    func menuWhen(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        if start <= now && end > now { return "Now" }
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = calendar.timeZone
        time.dateStyle = .none
        time.timeStyle = .short
        let clock = time.string(from: start)
        if calendar.isDate(start, inSameDayAs: now) { return clock }
        if let next = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(start, inSameDayAs: next) {
            return "Tomorrow \(clock)"
        }
        let day = DateFormatter()
        day.locale = locale
        day.timeZone = calendar.timeZone
        day.setLocalizedDateFormatFromTemplate("EEE")
        return "\(day.string(from: start)) \(clock)"
    }
}
