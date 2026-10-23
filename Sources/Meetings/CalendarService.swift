import AppKit
import CryptoKit
import Foundation
import Network

enum CalendarError: LocalizedError {
    case missingCredentials
    case notAuthenticated
    case tokenExchangeFailed(String)
    case tokenRefreshFailed(String)
    case apiFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "Google OAuth client file not found at \(Paths.display(Paths.calendarCredentials))"
        case .notAuthenticated: return "Not signed in to Google Calendar"
        case .tokenExchangeFailed(let m): return "Token exchange failed: \(m)"
        case .tokenRefreshFailed(let m): return "Token refresh failed: \(m)"
        case .apiFailed(let m): return "Calendar API error: \(m)"
        }
    }
}

/// Google Calendar integration: OAuth 2.0 + PKCE through a loopback server on port 8085.
@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    @Published private(set) var upcomingMeetings: [Meeting] = []
    @Published private(set) var isAuthenticated = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefresh: Date?

    static let redirectPort: UInt16 = 8085
    static let scope = "https://www.googleapis.com/auth/calendar.readonly"
    static let lookahead: TimeInterval = 24 * 3600

    private var token: OAuthToken?
    private var listener: NWListener?
    private var refreshTimer: Timer?

    struct ClientCredentials {
        var clientId: String
        var clientSecret: String?
        var authURI: String
        var tokenURI: String
    }

    struct OAuthToken: Codable {
        var token: String
        var refresh_token: String?
        var token_uri: String?
        var client_id: String?
        var client_secret: String?
        var scopes: [String]?
        var expiry: String?

        var expiryDate: Date? {
            guard let expiry else { return nil }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: expiry) { return d }
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: expiry) { return d }
            // google-auth writes "2026-04-09T14:00:00.123456Z" or without zone.
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(identifier: "UTC")
            for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'", "yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss"] {
                df.dateFormat = fmt
                if let d = df.date(from: expiry) { return d }
            }
            return nil
        }
    }

    private init() {
        token = Self.loadToken()
        isAuthenticated = token?.refresh_token != nil || token != nil
    }

    // MARK: - Polling

    func startPolling(intervalMinutes: Int) {
        refreshTimer?.invalidate()
        let interval = TimeInterval(max(1, intervalMinutes) * 60)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() async {
        guard isAuthenticated else { return }
        do {
            let now = Date()
            let meetings = try await getMeetings(from: now.addingTimeInterval(-3 * 3600), to: now.addingTimeInterval(Self.lookahead))
            upcomingMeetings = meetings
            lastRefresh = Date()
            lastError = nil
            log("📅 Calendar refreshed: \(meetings.count) meeting(s)")
        } catch {
            lastError = error.localizedDescription
            log("❌ Calendar refresh failed: \(error.localizedDescription)")
            if case CalendarError.notAuthenticated = error { isAuthenticated = false }
        }
    }

    /// The meeting considered "current" at `date`, allowing an early start and an overrun.
    func currentMeeting(at date: Date = Date(), earlyStartMinutes: Int, overrunMinutes: Int) -> Meeting? {
        upcomingMeetings
            .filter { m in
                date >= m.start.addingTimeInterval(-Double(earlyStartMinutes) * 60) &&
                date <= m.end.addingTimeInterval(Double(overrunMinutes) * 60)
            }
            // Prefer the meeting whose start is closest to now.
            .min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
    }

    /// Future meetings for the menu.
    var menuMeetings: [Meeting] {
        let now = Date()
        return upcomingMeetings.filter { $0.end > now }.sorted { $0.start < $1.start }
    }

    // MARK: - API

    /// Events in an arbitrary window across the configured calendars.
    func getMeetings(from: Date, to: Date) async throws -> [Meeting] {
        let accessToken = try await validAccessToken()
        let calendars = AppSettings.shared.data.calendars.isEmpty ? ["primary"] : AppSettings.shared.data.calendars
        let iso = ISO8601DateFormatter()
        var all: [Meeting] = []
        for calendarId in calendars {
            var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId)/events")!
            comps.queryItems = [
                .init(name: "timeMin", value: iso.string(from: from)),
                .init(name: "timeMax", value: iso.string(from: to)),
                .init(name: "singleEvents", value: "true"),
                .init(name: "orderBy", value: "startTime"),
                .init(name: "maxResults", value: "250"),
            ]
            var request = URLRequest(url: comps.url!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CalendarError.apiFailed("no response") }
            if http.statusCode == 401 { throw CalendarError.notAuthenticated }
            guard http.statusCode == 200 else {
                throw CalendarError.apiFailed("HTTP \(http.statusCode): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
            }
            all.append(contentsOf: Self.parseEvents(data))
        }
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }.sorted { $0.start < $1.start }
    }

    static func parseEvents(_ data: Data) -> [Meeting] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        return items.compactMap { item -> Meeting? in
            guard (item["status"] as? String) != "cancelled",
                  let id = item["id"] as? String,
                  let startObj = item["start"] as? [String: Any], let endObj = item["end"] as? [String: Any],
                  // All-day events only have "date".
                  let startStr = startObj["dateTime"] as? String, let endStr = endObj["dateTime"] as? String,
                  let start = iso.date(from: startStr), let end = iso.date(from: endStr) else { return nil }

            let rawAttendees = (item["attendees"] as? [[String: Any]]) ?? []
            let people = rawAttendees.filter { ($0["resource"] as? Bool) != true && ($0["responseStatus"] as? String) != "declined" }
            // Solo calendar blocks: nobody but me.
            let others = people.filter { ($0["self"] as? Bool) != true }
            guard !others.isEmpty else { return nil }

            func name(_ a: [String: Any]) -> String {
                if let n = a["displayName"] as? String, !n.isEmpty { return n }
                let email = a["email"] as? String ?? "Unknown"
                return String(email.split(separator: "@").first ?? Substring(email))
            }
            // Self first, for speaker matching priority.
            let me = people.filter { ($0["self"] as? Bool) == true }.map(name)
            let attendees = me + others.map(name)

            let url = meetingURL(item)
            return Meeting(
                id: id, title: (item["summary"] as? String) ?? "Untitled meeting",
                start: start, end: end, attendees: attendees, meetingURL: url,
                type: MeetingType.from(url: url), fromCalendar: true)
        }
    }

    static func meetingURL(_ item: [String: Any]) -> String? {
        if let link = item["hangoutLink"] as? String { return link }
        if let conf = item["conferenceData"] as? [String: Any], let eps = conf["entryPoints"] as? [[String: Any]] {
            if let video = eps.first(where: { ($0["entryPointType"] as? String) == "video" }), let uri = video["uri"] as? String { return uri }
        }
        let text = [(item["description"] as? String) ?? "", (item["location"] as? String) ?? ""].joined(separator: "\n")
        let patterns = [
            "https://[\\w.-]*zoom\\.us/j/[^\\s\"<>]+",
            "https://teams\\.microsoft\\.com/l/meetup-join/[^\\s\"<>]+",
            "https://meet\\.google\\.com/[a-z-]+",
            "https://app\\.slack\\.com/huddle/[^\\s\"<>]+",
        ]
        for p in patterns {
            if let r = text.range(of: p, options: .regularExpression) { return String(text[r]) }
        }
        return nil
    }

    // MARK: - OAuth

    static func loadCredentials() throws -> ClientCredentials {
        guard let data = try? Data(contentsOf: Paths.calendarCredentials),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = (json["installed"] ?? json["web"]) as? [String: Any],
              let clientId = inner["client_id"] as? String else {
            throw CalendarError.missingCredentials
        }
        return ClientCredentials(
            clientId: clientId, clientSecret: inner["client_secret"] as? String,
            authURI: inner["auth_uri"] as? String ?? "https://accounts.google.com/o/oauth2/auth",
            tokenURI: inner["token_uri"] as? String ?? "https://oauth2.googleapis.com/token")
    }

    private static func loadToken() -> OAuthToken? {
        guard let data = try? Data(contentsOf: Paths.calendarToken) else { return nil }
        if let t = try? JSONDecoder().decode(OAuthToken.self, from: data) { return t }
        // Also accept a raw OAuth response {"access_token": ...}.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let access = json["access_token"] as? String {
            return OAuthToken(token: access, refresh_token: json["refresh_token"] as? String, expiry: nil)
        }
        return nil
    }

    private func saveToken(_ t: OAuthToken) {
        token = t
        do {
            try FileManager.default.createDirectory(at: Paths.calendarToken.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try encoder.encode(t).write(to: Paths.calendarToken, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.calendarToken.path)
        } catch {
            log("❌ Could not save calendar token: \(error.localizedDescription)")
        }
    }

    private func validAccessToken() async throws -> String {
        guard let token else { throw CalendarError.notAuthenticated }
        if let expiry = token.expiryDate, expiry.timeIntervalSinceNow > 60 { return token.token }
        if token.expiryDate == nil && token.refresh_token == nil { return token.token }
        return try await refreshAccessToken()
    }

    private func refreshAccessToken() async throws -> String {
        guard let refresh = token?.refresh_token else { throw CalendarError.notAuthenticated }
        let creds = try Self.loadCredentials()
        var params = ["client_id": creds.clientId, "refresh_token": refresh, "grant_type": "refresh_token"]
        if let secret = creds.clientSecret { params["client_secret"] = secret }
        let json = try await postForm(creds.tokenURI, params, failure: CalendarError.tokenRefreshFailed)
        guard let access = json["access_token"] as? String else { throw CalendarError.tokenRefreshFailed("no access_token") }
        let expiresIn = json["expires_in"] as? Double ?? 3600
        var t = token!
        t.token = access
        t.expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(expiresIn))
        saveToken(t)
        log("📅 Access token refreshed")
        return access
    }

    /// Opens the browser for consent and waits for the loopback redirect.
    func signIn() async {
        do {
            let creds = try Self.loadCredentials()
            let verifier = Self.randomURLSafe(64)
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
            let state = Self.randomURLSafe(24)
            let redirect = "http://127.0.0.1:\(Self.redirectPort)/"

            var comps = URLComponents(string: creds.authURI)!
            comps.queryItems = [
                .init(name: "client_id", value: creds.clientId),
                .init(name: "redirect_uri", value: redirect),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: Self.scope),
                .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "access_type", value: "offline"),
                .init(name: "prompt", value: "consent"),
                .init(name: "state", value: state),
            ]
            let codeTask = Task { try await self.waitForAuthorizationCode(expectedState: state) }
            NSWorkspace.shared.open(comps.url!)
            let code = try await codeTask.value

            var params = [
                "client_id": creds.clientId, "code": code, "code_verifier": verifier,
                "grant_type": "authorization_code", "redirect_uri": redirect,
            ]
            if let secret = creds.clientSecret { params["client_secret"] = secret }
            let json = try await postForm(creds.tokenURI, params, failure: CalendarError.tokenExchangeFailed)
            guard let access = json["access_token"] as? String else { throw CalendarError.tokenExchangeFailed("no access_token") }
            let expiresIn = json["expires_in"] as? Double ?? 3600
            saveToken(OAuthToken(
                token: access, refresh_token: json["refresh_token"] as? String, token_uri: creds.tokenURI,
                client_id: creds.clientId, client_secret: creds.clientSecret, scopes: [Self.scope],
                expiry: ISO8601DateFormatter().string(from: Date().addingTimeInterval(expiresIn))))
            isAuthenticated = true
            lastError = nil
            log("✅ Signed in to Google Calendar")
            await refresh()
        } catch {
            lastError = error.localizedDescription
            log("❌ Google sign-in failed: \(error.localizedDescription)")
        }
    }

    func signOut() {
        token = nil
        try? FileManager.default.removeItem(at: Paths.calendarToken)
        isAuthenticated = false
        upcomingMeetings = []
    }

    private func postForm(_ url: String, _ params: [String: String], failure: (String) -> CalendarError) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw failure(String(data: data, encoding: .utf8) ?? "unknown error")
        }
        return json
    }

    /// Minimal one-shot HTTP server for the OAuth redirect.
    private func waitForAuthorizationCode(expectedState: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.redirectPort)!)
                var finished = false
                listener.newConnectionHandler = { [weak self] connection in
                    connection.start(queue: .main)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                        let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
                        let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                        let comps = URLComponents(string: "http://localhost\(path)")
                        let items = comps?.queryItems ?? []
                        let code = items.first { $0.name == "code" }?.value
                        let state = items.first { $0.name == "state" }?.value
                        let error = items.first { $0.name == "error" }?.value

                        let ok = code != nil && state == expectedState
                        let body = ok
                            ? "<html><body style='font-family:-apple-system;padding:40px'><h2>Glimpse is connected to Google Calendar.</h2><p>You can close this tab.</p></body></html>"
                            : "<html><body style='font-family:-apple-system;padding:40px'><h2>Sign-in failed</h2><p>\(error ?? "Invalid response")</p></body></html>"
                        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })

                        guard !finished, path != "/favicon.ico" else { return }
                        finished = true
                        // Handlers run on the main queue.
                        MainActor.assumeIsolated {
                            self?.listener?.cancel()
                            self?.listener = nil
                        }
                        if ok, let code {
                            continuation.resume(returning: code)
                        } else {
                            continuation.resume(throwing: CalendarError.tokenExchangeFailed(error ?? "state mismatch"))
                        }
                    }
                }
                listener.start(queue: .main)
                self.listener = listener
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func randomURLSafe(_ length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes).base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
