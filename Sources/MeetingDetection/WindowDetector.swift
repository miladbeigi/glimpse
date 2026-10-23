import CoreGraphics
import Foundation

/// Detects meeting app windows by app name + window title patterns. Uses
/// `CGWindowListCopyWindowInfo` with all windows (not only on-screen), so windows on other
/// Spaces and minimized windows count. Window titles require Screen Recording permission.
public final class WindowDetector: @unchecked Sendable {
    public struct Pattern: Sendable {
        public let service: String
        public let owners: [String]
        /// Title regex; nil means any window of the owner app counts.
        public let title: String?
    }

    static let browsers = [
        "Google Chrome", "Safari", "Arc", "Brave Browser", "Microsoft Edge", "Firefox", "Opera",
        "Vivaldi", "Dia", "Chromium", "Orion",
    ]

    /// Dash class accepting hyphen, en dash, em dash and minus sign.
    static let dash = "[-\u{2013}\u{2014}\u{2212}]"

    public static let patterns: [Pattern] = [
        Pattern(service: "Google Meet", owners: browsers, title: "^Meet\\s*\(dash)\\s*[a-z]{3}-[a-z]{4}-[a-z]{3}|Google Meet|meet\\.google\\.com"),
        Pattern(service: "Zoom", owners: ["zoom.us", "Zoom"], title: "^(Zoom Meeting|Zoom Webinar|Meeting|Zoom)$|Zoom Meeting"),
        Pattern(service: "Zoom", owners: browsers, title: "Zoom Meeting|zoom\\.us/(j|wc)/"),
        Pattern(service: "Microsoft Teams", owners: ["Microsoft Teams", "Microsoft Teams (work or school)", "MSTeams"], title: "Meeting|Call|\\|\\s*Microsoft Teams"),
        Pattern(service: "Microsoft Teams", owners: browsers, title: "Meeting.*Microsoft Teams|teams\\.microsoft\\.com.*(meetup|call)"),
        Pattern(service: "Slack Huddles", owners: ["Slack"], title: "[Hh]uddle"),
        Pattern(service: "Discord", owners: ["Discord"], title: "Voice Connected|Stage|🔊"),
        Pattern(service: "FaceTime", owners: ["FaceTime"], title: "."),
        Pattern(service: "Webex", owners: ["Webex", "Cisco Webex Meetings"], title: "Meeting|Webex"),
        Pattern(service: "Tuple", owners: ["Tuple"], title: "."),
    ]

    public struct WindowInfo: Sendable {
        public let owner: String
        public let title: String
    }

    public struct Reading: Sendable {
        public var state: SignalState
        public var matches: [String]
    }

    private let regexCache: [String: NSRegularExpression]

    public init() {
        var cache: [String: NSRegularExpression] = [:]
        for p in Self.patterns {
            if let t = p.title, cache[t] == nil {
                cache[t] = try? NSRegularExpression(pattern: t, options: [])
            }
        }
        regexCache = cache
    }

    public func check() -> Reading {
        guard let windows = Self.allWindows() else { return Reading(state: .unknown, matches: []) }
        // Without Screen Recording, titles come back empty for every other app's windows:
        // we cannot tell, so report unknown rather than a false "inactive".
        let anyTitle = windows.contains { !$0.title.isEmpty }
        let matches = self.matches(in: windows)
        if !matches.isEmpty { return Reading(state: .active, matches: matches) }
        return Reading(state: anyTitle ? .inactive : .unknown, matches: [])
    }

    public func matches(in windows: [WindowInfo]) -> [String] {
        var found: [String] = []
        for w in windows {
            for p in Self.patterns where p.owners.contains(where: { w.owner == $0 || w.owner.hasPrefix($0) }) {
                let ok: Bool
                if let t = p.title, let re = regexCache[t] {
                    ok = re.firstMatch(in: w.title, range: NSRange(w.title.startIndex..., in: w.title)) != nil
                } else {
                    ok = true
                }
                if ok && !found.contains(p.service) { found.append(p.service) }
            }
        }
        return found
    }

    /// Titles of browser / meeting-app windows, for the diagnostic log.
    public func candidateWindowTitles() -> [String] {
        guard let windows = Self.allWindows() else { return [] }
        let owners = Set(Self.patterns.flatMap(\.owners))
        return windows
            .filter { w in !w.title.isEmpty && owners.contains(where: { w.owner.hasPrefix($0) }) }
            .map { "\($0.owner): \($0.title)" }
    }

    static func allWindows() -> [WindowInfo]? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return list.compactMap { dict in
            guard let layer = dict[kCGWindowLayer as String] as? Int, layer == 0 else { return nil }
            let owner = dict[kCGWindowOwnerName as String] as? String ?? ""
            let title = dict[kCGWindowName as String] as? String ?? ""
            return WindowInfo(owner: owner, title: title)
        }
    }
}
