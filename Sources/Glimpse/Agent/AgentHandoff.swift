import AppKit
import Carbon.HIToolbox
import Darwin

/// Send: hands screenshots to the Claude Code or Codex session you were just in.
///
/// When an agent is waiting for an answer (ask_user, ask_user_to_choose), Send answers it. Otherwise, with one
/// session running it goes there; with several, a menu lists them, the one whose window was in front most recently
/// first. A box then names the session and takes an optional message to send with the screenshots (`SendComposer`).
/// Either way:
/// - a Claude Code session with Glimpse's plugin gets the image through its inbox (`ClaudePlugin`): no typing, no
///   Accessibility, and a request sent mid-turn waits for the turn to end;
/// - any other `claude` or `codex` in a terminal gets the image's path pasted into its prompt (both attach a pasted
///   image path as the image).
@MainActor
enum AgentHandoff {
    struct Session: Equatable {
        enum Kind: String { case claudeCode = "Claude Code", codex = "Codex" }
        var kind: Kind
        var pid: pid_t
        /// The app showing it (Ghostty, Terminal, iTerm2, VS Code, the Claude app, …).
        var host: NSRunningApplication
        /// The plugin's inbox, when the session has one; otherwise Send pastes.
        var inbox: ClaudePlugin.Inbox?

        static func == (a: Session, b: Session) -> Bool { a.pid == b.pid && a.host.processIdentifier == b.host.processIdentifier }
    }

    // MARK: Send

    /// `close` puts away the window Send was pressed in. It runs once the destination is settled, so a session menu
    /// and the message box open while that window is still up: closing it first hands the front to another app, which
    /// shuts the menu. Closing the menu or cancelling the box sends nothing and runs neither `close` nor `then`. `then` runs once the image has reached the
    /// agent (or the clipboard), e.g. to open the next one of a batch. `restoreFront`: when Send came from outside
    /// Glimpse's windows (a glimpse:// link), closing the menu gives the front back to the app that had it.
    static func send(_ captures: [Capture], restoreFront: Bool = false, close: (() -> Void)? = nil,
                     then: (() -> Void)? = nil) {
        guard !captures.isEmpty else { return }
        if captures.count == 1, AgentRequests.shared.answer(with: captures[0]) {
            close?()
            HUD.show("Sent to \(AgentRequests.lastAnsweredAuthor ?? "the agent")", symbol: "paperplane.fill")
            then?()
            return
        }
        cache = nil
        // Read before the menu or the box brings Glimpse forward.
        let previous = restoreFront
            ? NSWorkspace.shared.frontmostApplication.flatMap { $0 == NSRunningApplication.current ? nil : $0 } : nil
        let sessions = orderedSessions()
        guard let first = sessions.first else {
            close?()
            copy(captures)
            HUD.show("No Claude Code or Codex session found. Copied instead", symbol: "doc.on.doc.fill", duration: 2.4)
            then?()
            return
        }
        guard sessions.count > 1 else {
            compose(captures, to: first, previousApp: previous, close: close, then: then)
            return
        }
        choose(among: sessions, previousApp: previous) { chosen in
            guard let chosen else { return }
            compose(captures, to: chosen, previousApp: previous, close: close, then: then)
        }
    }

    /// Asks for an optional message to go with the screenshots, then sends. Cancelling sends nothing and runs neither
    /// `close` nor `then`, like closing the session menu.
    private static func compose(_ captures: [Capture], to session: Session, previousApp: NSRunningApplication?,
                                close: (() -> Void)?, then: (() -> Void)?) {
        let label = label(for: session)
        SendComposer.ask(title: label.title, detail: label.detail, images: captures.map(\.image),
                         previousApp: previousApp) { message in
            guard let message else { return }
            close?()
            deliver(captures, message: message.isEmpty ? nil : message, to: session, then: then)
        }
    }

    private static func copy(_ captures: [Capture]) {
        if captures.count == 1 {
            Clipboard.copy(captures[0].image, scale: captures[0].scale)
        } else {
            Clipboard.copy(images: captures.map { ($0.image, $0.scale) })
        }
    }

    private static func deliver(_ captures: [Capture], message: String?, to session: Session, then: (() -> Void)?) {
        let paths: [String]
        do {
            paths = try captures.map { try writeForSending($0).path }
        } catch {
            HUD.show("Couldn't write the image: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            then?()
            return
        }
        if let inbox = session.inbox {
            do {
                try ClaudePlugin.deliver(ClaudePlugin.requestLine(paths: paths, message: message), to: inbox)
                cache = nil
                if session.host != NSRunningApplication.current { session.host.activate() }
                HUD.show(inbox.busy ? "Sent to Claude Code. It reads it when the current turn ends" : "Sent to Claude Code",
                         symbol: "paperplane.fill", duration: inbox.busy ? 2.6 : 1.6)
                then?()
                return
            } catch {
                NSLog("Glimpse: couldn't write to the Claude Code inbox: \(error.localizedDescription); pasting instead")
            }
        }
        // A terminal session gets the message after the paths, as a paste of its own: an agent attaches a pasted path
        // as an image only when the paste is nothing but paths. One line, so pasting it doesn't send it early.
        paste([paths.joined(separator: " ") + " "] + (message.map { [ClaudePlugin.oneLine($0)] } ?? []),
              into: session, then: then)
    }

    /// The Send button's title for these cards.
    static func sendTitle(for captures: [Capture]) -> String {
        if captures.count == 1, let request = AgentRequests.shared.request(for: captures[0]) {
            return "Send to \(request.author)"
        }
        let sessions = cachedSessions()
        if sessions.count > 1 { return "Send to…" }
        if let session = sessions.first { return "Send to \(session.kind.rawValue)" }
        return "Send"
    }

    // MARK: Choosing

    /// Pops up a menu of the sessions at the mouse, the first one under the pointer. `done` gets nil when it's closed
    /// without a choice.
    private static func choose(among sessions: [Session], previousApp previous: NSRunningApplication?,
                               done: @escaping @MainActor (Session?) -> Void) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Send to"))
        var chosen: Session?
        for (index, session) in sessions.enumerated() {
            let label = label(for: session)
            // ↩ picks the first (the pointer may not be on it); the others take their place in the list, 2 to 9.
            let key = index == 0 ? "\r" : index < 9 ? "\(index + 1)" : ""
            let item = ClosureMenuItem(title: label.title, keyEquivalent: key) { chosen = session }
            item.keyEquivalentModifierMask = []
            if #available(macOS 14.4, *) {
                item.subtitle = label.detail
            } else {
                item.title = "\(label.title) — \(label.detail)"
            }
            item.image = session.host == NSRunningApplication.current ? nil : session.host.icon.map { icon in
                let small = icon.copy() as! NSImage
                small.size = NSSize(width: 18, height: 18)
                return small
            }
            menu.addItem(item)
        }
        // The menu needs Glimpse active to get the keyboard. From Glimpse's own windows (the stack is a panel that
        // leaves another app in front) the front stays with Glimpse after a cancel: giving it back would close the
        // stack. A glimpse:// link has no window of ours behind the menu, so that one gives it back (`previous`).
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: menu.items[1], at: NSEvent.mouseLocation, in: nil)
        // NSMenu sends the item's action before popUp returns; the hop only makes that ordering not matter.
        DispatchQueue.main.async {
            if chosen == nil, let previous { previous.activate() }
            done(chosen)
        }
    }

    /// The session's title (or folder) and where it runs: "Fix the login bug" / "Claude Code · ~/code/app · Ghostty".
    static func label(for session: Session) -> (title: String, detail: String) {
        let cwd = session.inbox?.cwd ?? ProcessList.cwd(of: session.pid)
        let home = NSHomeDirectory()
        let folder = cwd.map { $0 == home ? "~" : $0.hasPrefix(home + "/") ? "~" + $0.dropFirst(home.count) : $0 }
        let title = session.inbox?.title ?? cwd.map { ($0 as NSString).lastPathComponent } ?? "\(session.kind.rawValue) \(session.pid)"
        var detail = [session.kind.rawValue]
        if let folder { detail.append(folder) }
        if session.host != NSRunningApplication.current, let host = session.host.localizedName { detail.append(host) }
        if session.inbox?.busy == true { detail.append("busy") }
        return (title, detail.joined(separator: " · "))
    }

    /// Files sent to agents: a short path without spaces, so it pastes as one token.
    nonisolated static var sentDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("GlimpseSent", isDirectory: true)
    }

    static func writeForSending(_ capture: Capture) throws -> URL {
        let dir = sentDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = ImageExporter.uniqueURL(in: dir, base: "glimpse-\(f.string(from: Date()))", ext: "png")
        guard let data = ImageExporter.encode(capture.image, scale: capture.scale, format: .png) else {
            throw NSError(domain: "Glimpse", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode the image"])
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Pasting

    /// Pastes `pieces` one after another (each its own ⌘V), then presses ↩ if Send submits.
    private static func paste(_ pieces: [String], into session: Session, then: (() -> Void)?) {
        let pasteboard = NSPasteboard.general
        let saved = savePasteboard(pasteboard)
        let trusted = AXIsProcessTrusted()
        pasteboard.clearContents()
        // Without Accessibility only one paste is left for you to make: everything in it.
        pasteboard.setString(trusted ? pieces[0] : pieces.joined(), forType: .string)

        session.host.activate()
        let name = session.kind.rawValue
        guard trusted else {
            // Without Accessibility Glimpse can't press ⌘V for you: leave the path on the clipboard.
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            HUD.show("Press ⌘V in \(name) to attach it (allow Glimpse in Accessibility to send directly)",
                     symbol: "paperplane", duration: 3.5)
            then?()
            return
        }
        Task { @MainActor in
            // Wait for the terminal to be in front before typing into it.
            for _ in 0..<40 where NSWorkspace.shared.frontmostApplication?.processIdentifier != session.host.processIdentifier {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
            postKey(kVK_ANSI_V, flags: .maskCommand)
            for piece in pieces.dropFirst() {
                // Give the terminal time to read the clipboard (and the agent to take in the image) first.
                try? await Task.sleep(nanoseconds: 350_000_000)
                pasteboard.clearContents()
                pasteboard.setString(piece, forType: .string)
                postKey(kVK_ANSI_V, flags: .maskCommand)
            }
            if Preferences.shared.sendSubmits {
                try? await Task.sleep(nanoseconds: 350_000_000)
                postKey(kVK_Return, flags: [])
            }
            HUD.show("Sent to \(name)", symbol: "paperplane.fill")
            // Give the terminal time to read the clipboard before putting the user's back.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if pasteboard.string(forType: .string) == pieces.last { restorePasteboard(pasteboard, saved) }
            then?()
        }
    }

    private static func postKey(_ code: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    private static func savePasteboard(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { entry[type] = data } }
            return entry
        }
    }

    private static func restorePasteboard(_ pb: NSPasteboard, _ saved: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }

    // MARK: Finding the session

    private static var cache: (date: Date, sessions: [Session])?

    /// The interactive Claude Code or Codex session whose window was in front most recently.
    static func currentSession() -> Session? { cachedSessions().first }

    /// `orderedSessions()`, kept for 2 s: Send's title is asked for often.
    private static func cachedSessions() -> [Session] {
        if let cache, Date().timeIntervalSince(cache.date) < 2, !cache.sessions.contains(where: \.host.isTerminated) {
            return cache.sessions
        }
        let sessions = orderedSessions()
        cache = (Date(), sessions)
        return sessions
    }

    /// Every session Send can reach, the one whose window was in front most recently first.
    static func orderedSessions() -> [Session] {
        let sessions = findSessions()
        guard let first = pickMostRecent(sessions) else { return [] }
        return [first] + sessions.filter { $0 != first }
    }

    private static func pickMostRecent(_ sessions: [Session]) -> Session? {
        guard !sessions.isEmpty else { return nil }
        // On-screen windows come front to back, so the first one belonging to a host is the one used last.
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
        for w in windows where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t else { continue }
            // Several sessions in one app: the one whose turn moved last (it's the one being used), inbox ones first.
            let inApp = sessions.filter { $0.host.processIdentifier == pid }
            if let s = inApp.max(by: { a, b in
                if (a.inbox != nil) != (b.inbox != nil) { return a.inbox == nil }
                return (a.inbox?.lastTurn ?? .distantPast) < (b.inbox?.lastTurn ?? .distantPast)
            }) { return s }
        }
        if let inbox = sessions.filter({ $0.inbox != nil }).max(by: {
            ($0.inbox?.lastTurn ?? .distantPast) < ($1.inbox?.lastTurn ?? .distantPast)
        }) { return inbox }
        return AppActivity.shared.mostRecent(among: sessions.map(\.host)).flatMap { host in
            sessions.first { $0.host.processIdentifier == host.processIdentifier }
        } ?? sessions.first
    }

    private static let terminalBundleIDs: Set<String> = [
        "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty", "co.zeit.hyper", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.exafunction.windsurf", "com.raphaelamorim.rio",
    ]

    static func findSessions() -> [Session] {
        let me = ProcessInfo.processInfo.processIdentifier
        var sessions: [Session] = []
        // Sessions with the plugin, wherever they run (a terminal, an editor, the Claude app).
        for inbox in ClaudePlugin.liveInboxes() {
            // Inside tmux or screen the parent chain ends at a server: use the last terminal used. The inbox doesn't
            // need a window at all, so with no terminal either the session is still reachable (nothing to bring forward).
            let host = hostApp(of: inbox.pid, allowClaudeApp: true) ?? lastTerminal() ?? NSRunningApplication.current
            sessions.append(Session(kind: .claudeCode, pid: inbox.pid, host: host, inbox: inbox))
        }
        let withInbox = Set(sessions.map(\.pid))
        for pid in ProcessList.allPIDs() where pid != me && !withInbox.contains(pid) {
            guard let kind = ProcessList.agentKind(pid) else { continue }
            if let host = hostApp(of: pid) {
                sessions.append(Session(kind: kind, pid: pid, host: host))
            } else if let terminal = lastTerminal() {
                // Inside tmux/screen the parent chain ends at a server, not the terminal: use the last terminal used.
                sessions.append(Session(kind: kind, pid: pid, host: terminal))
            }
        }
        return sessions
    }

    private static func lastTerminal() -> NSRunningApplication? {
        AppActivity.shared.mostRecent(among: NSWorkspace.shared.runningApplications.filter {
            terminalBundleIDs.contains($0.bundleIdentifier ?? "")
        })
    }

    /// The regular app an agent process runs under, by walking up its parents.
    private static func hostApp(of pid: pid_t, allowClaudeApp: Bool = false) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<24 {
            guard let parent = ProcessList.parent(of: current), parent > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: parent), app.activationPolicy == .regular {
                // Claude's own desktop app runs Claude Code headless; that isn't a session you type into.
                if app.bundleIdentifier == "com.anthropic.claudefordesktop", !allowClaudeApp { return nil }
                return app
            }
            current = parent
        }
        return nil
    }
}

/// When each app was last brought to the front (for the case where no window order tells).
@MainActor
final class AppActivity {
    static let shared = AppActivity()
    private var lastActive: [pid_t: Date] = [:]
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        if let front = NSWorkspace.shared.frontmostApplication { lastActive[front.processIdentifier] = Date() }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { AppActivity.shared.lastActive[app.processIdentifier] = Date() }
        }
    }

    func mostRecent(among apps: [NSRunningApplication]) -> NSRunningApplication? {
        apps.max { (lastActive[$0.processIdentifier] ?? .distantPast) < (lastActive[$1.processIdentifier] ?? .distantPast) }
    }
}

/// Just enough of the process table to find agent sessions.
enum ProcessList {
    static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(max(0, Int(n)))).filter { $0 > 0 }
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// The process's working folder.
    static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The process's argv.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// KERN_PROCARGS2: argc (Int32), the executable path, NUL padding, then argc NUL-terminated arguments.
    static func parseProcArgs(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < bytes.count, bytes[i] != 0 { i += 1 } // executable path
        while i < bytes.count, bytes[i] == 0 { i += 1 } // padding
        var args: [String] = []
        while args.count < argc, i < bytes.count {
            let start = i
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            args.append(String(decoding: bytes[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// Whether `pid` is an interactive Claude Code or Codex session.
    static func agentKind(_ pid: pid_t) -> AgentHandoff.Session.Kind? {
        guard let path = path(of: pid) else { return nil }
        let exe = (path as NSString).lastPathComponent
        let interesting = exe == "claude" || exe == "codex" || ["node", "bun", "deno"].contains(exe)
            || path.contains("/claude/versions/") || path.contains("/claude-code/")
        guard interesting, let args = arguments(of: pid) else { return nil }
        return classify(path: path, arguments: args)
    }

    static func classify(path: String, arguments args: [String]) -> AgentHandoff.Session.Kind? {
        let joined = args.joined(separator: " ")
        let first = args.first.map { ($0 as NSString).lastPathComponent } ?? ""
        let exe = (path as NSString).lastPathComponent
        let rest = Array(args.dropFirst())
        let isClaude = exe == "claude" || first == "claude" || path.contains("/claude/versions/")
            || joined.contains("@anthropic-ai/claude-code") || joined.contains("claude-code/cli")
        let isCodex = exe == "codex" || first == "codex" || joined.contains("@openai/codex")
        if isClaude {
            // Headless runs (claude -p, the desktop app's stream-json sessions) and helper subcommands aren't sessions.
            let headless: Set<String> = ["-p", "--print", "mcp", "doctor", "update", "config", "install", "setup-token"]
            if rest.contains(where: headless.contains) || joined.contains("stream-json") { return nil }
            return .claudeCode
        }
        if isCodex {
            let headless: Set<String> = ["exec", "e", "mcp", "mcp-server", "app-server", "proto", "login", "logout", "apply", "completion"]
            if let sub = rest.first(where: { !$0.hasPrefix("-") }), headless.contains(sub) { return nil }
            return .codex
        }
        return nil
    }
}
