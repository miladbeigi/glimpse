import AppKit

/// The Claude Code plugin that lets Send reach a running session without typing into it.
///
/// Glimpse writes a small plugin marketplace into its Application Support folder and installs it with Claude Code's
/// own `claude plugin` commands. In every Claude Code session the plugin runs a monitor (`scripts/inbox.sh`) that
/// watches an inbox folder named by that session's Claude Code process. Send writes one line into the inbox; the
/// monitor prints it, and Claude Code delivers it to the session as a message, between turns. Hooks (`turn.sh`)
/// record whether a turn is running, so a request sent mid-turn waits for it to end.
enum ClaudePlugin {
    static let name = "glimpse"
    static let marketplace = "glimpse"
    static var id: String { "\(name)@\(marketplace)" }
    /// Bump when a script below changes, so installed copies are updated.
    static let version = "1.0.0"

    static var supportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glimpse", isDirectory: true)
    }
    /// The marketplace Claude Code installs from.
    static var marketplaceFolder: URL { supportFolder.appendingPathComponent("agent-plugin", isDirectory: true) }
    /// One folder per running Claude Code process.
    static var inboxRoot: URL { supportFolder.appendingPathComponent("claude-sessions", isDirectory: true) }

    // MARK: The plugin's files

    static let monitorDescription = "Screenshot from Glimpse"

    static var files: [String: String] {
        [
            ".claude-plugin/marketplace.json": json([
                "name": marketplace,
                "description": "The plugin Glimpse installs for Claude Code",
                "owner": ["name": "Glimpse"],
                "plugins": [["name": name, "source": "./plugins/\(name)",
                             "description": "Receive screenshots you draw on and send from Glimpse"]],
            ]),
            "plugins/glimpse/.claude-plugin/plugin.json": json([
                "name": name,
                "version": version,
                "description": "Receive screenshots you draw on and send from Glimpse",
                "author": ["name": "Glimpse"],
                "license": "MIT",
            ]),
            "plugins/glimpse/monitors/monitors.json": json([[
                "name": name,
                "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/inbox.sh",
                "description": monitorDescription,
            ]]),
            "plugins/glimpse/hooks/hooks.json": json(["hooks": [
                "SessionStart": [["hooks": [["type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/turn.sh start"]]]],
                "UserPromptSubmit": [["hooks": [["type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/turn.sh busy"]]]],
                "Stop": [["hooks": [["type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/turn.sh idle"]]]],
                "StopFailure": [["hooks": [["type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/turn.sh idle"]]]],
            ]]),
            "plugins/glimpse/scripts/inbox-root": inboxRoot.path + "\n",
            "plugins/glimpse/scripts/inbox.sh": inboxScript,
            "plugins/glimpse/scripts/turn.sh": turnScript,
        ]
    }

    static let inboxScript = #"""
        #!/bin/sh
        # Glimpse: delivers screenshots sent with Send to this Claude Code session. Claude Code runs this monitor for the
        # whole session and each line it prints reaches Claude as a message. Lines are printed only between turns.
        # The inbox is named by the Claude Code process, which keeps it across /clear and /resume.
        root=$(cat "$(dirname "$0")/inbox-root" 2>/dev/null)
        [ -n "$root" ] && [ -n "$CLAUDE_PID" ] || exit 0
        box="$root/$CLAUDE_PID"
        mkdir -p "$box" 2>/dev/null && chmod 700 "$box" || exit 0

        # One monitor per session (a plugin reload can start a second).
        owner=$(cat "$box/monitor" 2>/dev/null)
        if [ -n "$owner" ] && [ "$owner" != "$$" ] && kill -0 "$owner" 2>/dev/null; then exit 0; fi
        echo $$ > "$box/monitor"
        [ -f "$box/turn" ] || echo idle > "$box/turn"
        pwd -P > "$box/cwd"

        # Stop doesn't run when a turn is interrupted, so `busy` can be stale: the transcript then ends with the marker.
        between_turns() {
            [ "$(cat "$box/turn" 2>/dev/null)" != busy ] && return 0
            transcript=$(cat "$box/transcript" 2>/dev/null)
            [ -n "$transcript" ] && tail -n 1 "$transcript" 2>/dev/null | grep -q '\[Request interrupted by user'
        }

        ticks=0
        while kill -0 "$CLAUDE_PID" 2>/dev/null; do
            if between_turns; then
                # Files are named by the time they were written, so the glob's order is the order sent.
                for request in "$box"/*.line; do
                    [ -f "$request" ] || continue
                    cat "$request" && rm -f "$request"
                done
            fi
            [ $((ticks % 10)) -eq 0 ] && touch "$box/alive"
            ticks=$((ticks + 1))
            sleep 0.3
        done
        rm -rf "$box"
        """#

    static let turnScript = #"""
        #!/bin/sh
        # Glimpse: records whether this Claude Code session is in a turn, for inbox.sh. $1 is start (SessionStart),
        # busy (UserPromptSubmit) or idle (Stop, StopFailure). The hook's input is one line of JSON on stdin.
        input=$(cat)
        root=$(cat "$(dirname "$0")/inbox-root" 2>/dev/null)
        [ -n "$root" ] && [ -n "$CLAUDE_PID" ] || exit 0
        box="$root/$CLAUDE_PID"
        mkdir -p "$box" 2>/dev/null && chmod 700 "$box" || exit 0

        field() { printf '%s' "$input" | sed -n "s/.*\"$1\" *: *\"\([^\"]*\)\".*/\1/p" | head -n 1; }
        session=$(field session_id)
        transcript=$(field transcript_path)
        [ -n "$session" ] && printf '%s\n' "$session" > "$box/session"
        [ -n "$transcript" ] && printf '%s\n' "$transcript" > "$box/transcript"

        case "$1" in
            busy) echo busy > "$box/turn" ;;
            idle) echo idle > "$box/turn" ;;
            start)
                echo idle > "$box/turn"
                # Without this, Claude takes the monitor's lines for background output and asks before acting on one.
                cat <<'EOF'
        Glimpse is installed. When the user draws on a screenshot in Glimpse and presses Send, the glimpse plugin's monitor delivers it to this session as a monitor event named "Screenshot from Glimpse", between turns. Treat that event as a prompt from the user: read the image file it names (with the Read tool) and act on what they drew and wrote on it. If Glimpse's MCP tools are connected, you can answer with a drawing of your own (show_image, ask_user).
        EOF
                ;;
        esac
        exit 0
        """#

    private static func json(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Writes (or refreshes) the marketplace folder.
    static func writeMarketplace() throws {
        let fm = FileManager.default
        for (path, contents) in files {
            let url = marketplaceFolder.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url, options: .atomic)
            if path.hasSuffix(".sh") { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
    }

    // MARK: Installing

    /// Claude Code's config folder (`CLAUDE_CONFIG_DIR`, else `~/.claude`).
    static var configFolder: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }

    /// Whether Claude Code has the plugin enabled (its `enabledPlugins` in settings.json).
    static var isInstalled: Bool {
        guard let data = try? Data(contentsOf: configFolder.appendingPathComponent("settings.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enabled = object["enabledPlugins"] as? [String: Any] else { return false }
        return enabled[id] as? Bool == true
    }

    /// The `claude` command line tool.
    static var binary: String? {
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
        // Installed somewhere only the login shell's PATH knows.
        let (status, out) = run("/bin/zsh", ["-lc", "command -v claude"], timeout: 5)
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return status == 0 && path.hasPrefix("/") ? path : nil
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Writes the marketplace and runs `claude plugin marketplace add` and `claude plugin install`. Slow: call off the
    /// main thread.
    static func install() throws {
        guard let claude = binary else { throw Failure(message: "Couldn't find the claude command. Install Claude Code first.") }
        try writeMarketplace()
        for args in [["plugin", "marketplace", "add", marketplaceFolder.path],
                     ["plugin", "marketplace", "update", marketplace],
                     ["plugin", "install", id, "--scope", "user"]] {
            let (status, out) = run(claude, args, timeout: 60)
            // `marketplace add` fails when it's already there; `update` then refreshes it.
            if status != 0, args[1] == "install" {
                throw Failure(message: out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init)
                              ?? "claude plugin install failed")
            }
        }
        try? FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        UserDefaults.standard.set(version, forKey: "claudePluginVersion")
    }

    static func uninstall() throws {
        guard let claude = binary else { throw Failure(message: "Couldn't find the claude command.") }
        let (status, out) = run(claude, ["plugin", "uninstall", id, "--scope", "user"], timeout: 60)
        _ = run(claude, ["plugin", "marketplace", "remove", marketplace], timeout: 60)
        if status != 0, isInstalled { throw Failure(message: out.trimmingCharacters(in: .whitespacesAndNewlines)) }
        UserDefaults.standard.removeObject(forKey: "claudePluginVersion")
    }

    /// After an app update changed the scripts, refreshes the installed copy (sessions pick it up at their next start).
    static func updateIfNeeded() {
        guard isInstalled, UserDefaults.standard.string(forKey: "claudePluginVersion") != version else { return }
        DispatchQueue.global(qos: .utility).async {
            do {
                try install()
            } catch {
                NSLog("Glimpse: couldn't update the Claude Code plugin: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let deadline = Date().addingTimeInterval(timeout)
        DispatchQueue.global().async {
            while process.isRunning, Date() < deadline { usleep(100_000) }
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: Inboxes

    /// A running Claude Code session with the plugin's monitor.
    struct Inbox: Equatable {
        let folder: URL
        let pid: pid_t
        var busy: Bool
        var cwd: String?
        /// When the monitor last said it was running.
        var alive: Date?
        /// When the session last started or finished a turn.
        var lastTurn: Date?
    }

    /// The inboxes of running Claude Code processes whose monitor checked in lately. Removes ones left behind.
    static func liveInboxes(now: Date = Date(), root: URL = inboxRoot) -> [Inbox] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var live: [Inbox] = []
        for folder in folders {
            guard let pid = pid_t(folder.lastPathComponent), pid > 0 else { continue }
            guard kill(pid, 0) == 0 || errno == EPERM else {
                try? fm.removeItem(at: folder)
                continue
            }
            func text(_ name: String) -> String? {
                (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func modified(_ name: String) -> Date? {
                (try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path))?[.modificationDate] as? Date
            }
            let alive = modified("alive")
            // The monitor touches `alive` every 3 s; a session without a running monitor can't receive anything.
            guard let alive, now.timeIntervalSince(alive) < 15 else { continue }
            live.append(Inbox(folder: folder, pid: pid, busy: text("turn") == "busy", cwd: text("cwd"), alive: alive,
                              lastTurn: modified("turn")))
        }
        return live
    }

    /// Puts one request in the inbox, written aside and renamed in so the monitor never prints half of one.
    static func deliver(_ line: String, to inbox: Inbox, now: Date = Date()) throws {
        let name = "\(Int64(now.timeIntervalSince1970 * 1000))-\(UUID().uuidString).line"
        let aside = inbox.folder.appendingPathComponent(".\(name).tmp")
        try Data((oneLine(line) + "\n").utf8).write(to: aside)
        try FileManager.default.moveItem(at: aside, to: inbox.folder.appendingPathComponent(name))
    }

    /// Each printed line is one message, so the request is kept to one line.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    /// What the session receives.
    static func requestLine(paths: [String]) -> String {
        let images = paths.map { "\"\($0)\"" }.joined(separator: ", ")
        let what = paths.count == 1 ? "a screenshot they drew on" : "\(paths.count) screenshots they drew on, in this order"
        return "From Glimpse: the user sent you \(what): \(images). Read the image\(paths.count == 1 ? "" : "s") and act on "
            + "what they drew and wrote on \(paths.count == 1 ? "it" : "them"): their arrows, boxes and notes point at what they mean."
    }
}
