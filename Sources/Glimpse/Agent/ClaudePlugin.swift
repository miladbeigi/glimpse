import AppKit

/// The Claude Code plugin that lets Send reach a running session without typing into it.
///
/// Glimpse writes a small plugin marketplace into its Application Support folder and installs it with Claude Code's
/// own `claude plugin` commands. Each Claude Code session gets an inbox folder named by its Claude Code process. Send
/// writes one line into the inbox and `scripts/inbox.sh` hands it to the session as a message, between turns:
/// - in the terminal, the plugin's monitor runs `inbox.sh` for the whole session and prints the line;
/// - where Claude Code runs no plugin monitors (the Claude desktop app and other SDK hosts run it headless), hooks run
///   `inbox.sh wait` in the background (asyncRewake): it waits for a line, prints it and exits 2, which wakes Claude
///   with it. The hooks start it again when a turn starts and ends.
/// Hooks (`turn.sh`) record whether a turn is running, so a request sent mid-turn waits for it to end.
enum ClaudePlugin {
    static let name = "glimpse"
    static let marketplace = "glimpse"
    static var id: String { "\(name)@\(marketplace)" }
    /// Bump when a script below changes, so installed copies are updated.
    static let version = "1.1.0"

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
                "SessionStart": [["hooks": [turnHook("start"), waitHook]]],
                "UserPromptSubmit": [["hooks": [turnHook("busy"), waitHook]]],
                "Stop": [["hooks": [turnHook("idle"), waitHook]]],
                "StopFailure": [["hooks": [turnHook("idle"), waitHook]]],
                "SessionEnd": [["hooks": [turnHook("end")]]],
            ]]),
            "plugins/glimpse/scripts/inbox-root": inboxRoot.path + "\n",
            "plugins/glimpse/scripts/inbox.sh": inboxScript,
            "plugins/glimpse/scripts/turn.sh": turnScript,
        ]
    }

    /// The heading Claude sees on a request delivered by `inbox.sh wait` (the monitor's description plays that part).
    static let wakeHeading = "Screenshot from Glimpse:"

    private static func turnHook(_ state: String) -> [String: Any] {
        ["type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/turn.sh \(state)"]
    }

    /// Runs in the background for as long as it waits (a day at most; the next turn starts another).
    private static var waitHook: [String: Any] {
        ["type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/inbox.sh wait", "asyncRewake": true,
         "timeout": 86400, "rewakeMessage": wakeHeading, "rewakeSummary": monitorDescription]
    }

    static let inboxScript = #"""
        #!/bin/sh
        # Glimpse: delivers screenshots sent with Send to this Claude Code session, between turns. Two ways, because
        # Claude Code runs plugin monitors only in its terminal UI:
        # - `inbox.sh` is the plugin's monitor: it runs for the whole session and each line it prints reaches Claude.
        # - `inbox.sh wait` runs as an asyncRewake hook where no monitor runs (the Claude desktop app, SDK hosts): it
        #   waits for requests, prints them to stderr and exits 2, which wakes Claude with them. The hooks start it again
        #   when a turn starts and ends.
        # The inbox is named by the Claude Code process, which keeps it across /clear and /resume.
        mode=${1:-monitor}
        [ "$mode" = wait ] && cat > /dev/null # the hook's input
        root=$(cat "$(dirname "$0")/inbox-root" 2>/dev/null)
        [ -n "$root" ] && [ -n "$CLAUDE_PID" ] || exit 0
        box="$root/$CLAUDE_PID"

        # Only the Claude desktop app's sessions take a waiter: it keeps them open and runs Claude Code headless (stream-json
        # input) from inside its app bundle. Claude Code waits for asyncRewake hooks before it exits (`claude -p` until
        # they end, other hosts about 30 s), so a waiter would hold up one-shot runs and SDK scripts. In the terminal
        # the monitor delivers. GLIMPSE_INBOX_ANY_HOST lets tests stand in for the app.
        in_claude_app() {
            [ -n "$GLIMPSE_INBOX_ANY_HOST" ] && return 0
            ancestor=$CLAUDE_PID
            for _ in 1 2; do
                ancestor=$(ps -o ppid= -p "$ancestor" 2>/dev/null | tr -d ' ')
                [ -n "$ancestor" ] && [ "$ancestor" -gt 1 ] || return 1
                ps -o comm= -p "$ancestor" 2>/dev/null | grep -q '/Claude\.app/Contents/' && return 0
            done
            return 1
        }
        if [ "$mode" = wait ]; then
            ps -o args= -p "$CLAUDE_PID" 2>/dev/null | grep -Eq -- '--input-format[= ]stream-json' && in_claude_app || exit 0
        fi
        mkdir -p "$box" 2>/dev/null && chmod 700 "$box" || exit 0

        # Whether another process holds the role in $1 (monitor or waiter).
        held() {
            owner=$(cat "$box/$1" 2>/dev/null)
            [ -n "$owner" ] && [ "$owner" != "$$" ] && kill -0 "$owner" 2>/dev/null
        }
        # Whether this process holds it.
        mine() { [ "$(cat "$box/$1" 2>/dev/null)" = "$$" ]; }
        # Takes the role in $1 unless a live process holds it. The file is created exclusively (noclobber), so two
        # hooks starting together can't both take it; one left by a dead process is replaced.
        claim() {
            ( set -C; echo $$ > "$box/$1" ) 2>/dev/null && return 0
            held "$1" && return 1
            rm -f "$box/$1"
            ( set -C; echo $$ > "$box/$1" ) 2>/dev/null
        }
        # One monitor per session (a plugin reload can start a second), and one waiter. A monitor makes waiters
        # unnecessary: it delivers on its own.
        if [ "$mode" = wait ]; then
            held monitor && exit 0
            claim waiter || exit 0
            echo wait > "$box/via"
            rm -f "$box/woke"
        else
            claim monitor || exit 0
            echo monitor > "$box/via"
        fi
        [ -f "$box/turn" ] || echo idle > "$box/turn"
        pwd -P > "$box/cwd"

        # Stop doesn't run when a turn is interrupted, so `busy` can be stale: the conversation then ends with the
        # interrupt marker. Other entries (a new title, a mode change) can follow it, so look at the last message.
        between_turns() {
            [ "$(cat "$box/turn" 2>/dev/null)" != busy ] && return 0
            transcript=$(cat "$box/transcript" 2>/dev/null)
            [ -n "$transcript" ] && tail -n 50 "$transcript" 2>/dev/null | grep -E '"type":"(user|assistant)"' \
                | tail -n 1 | grep -qF '"text":"[Request interrupted by user'
        }

        # Prints the waiting requests, oldest first: files are named by the time they were written. Each is claimed
        # by renaming it to <name>.<pid>, so a monitor and a waiter never both deliver one; one claimed by a process
        # that died before printing it goes back in line. Fails when there was none.
        deliver() {
            for taken in "$box"/*.line.*; do
                [ -f "$taken" ] || continue
                kill -0 "${taken##*.}" 2>/dev/null || mv "$taken" "${taken%.*}" 2>/dev/null
            done
            delivered=1
            for request in "$box"/*.line; do
                [ -f "$request" ] && mv "$request" "$request.$$" 2>/dev/null || continue
                cat "$request.$$" && rm -f "$request.$$" && delivered=0
            done
            return $delivered
        }

        ticks=0
        while kill -0 "$CLAUDE_PID" 2>/dev/null; do
            if [ "$mode" = wait ]; then
                # Another waiter took over (or the session ended and removed it), or a monitor runs: leave it to them.
                mine waiter || exit 0
                if held monitor; then rm -f "$box/waiter"; exit 0; fi
            fi
            if between_turns; then
                if [ "$mode" = wait ]; then
                    if deliver >&2; then
                        # Waking Claude starts a turn; its Stop starts the next waiter. Until then, `woke` tells Glimpse
                        # the session can still take requests.
                        echo busy > "$box/turn"
                        touch "$box/woke"
                        rm -f "$box/waiter"
                        exit 2
                    fi
                else
                    deliver
                fi
            fi
            [ $((ticks % 10)) -eq 0 ] && touch "$box/alive"
            ticks=$((ticks + 1))
            sleep 0.3
        done
        rm -rf "$box"
        """#

    static let turnScript = #"""
        #!/bin/sh
        # Glimpse: records whether this Claude Code session is in a turn and which transcript is its, for inbox.sh and
        # for naming the session in Glimpse's Send menu. $1 is start (SessionStart), busy (UserPromptSubmit), idle (Stop,
        # StopFailure) or end (SessionEnd). The hook's input is one line of JSON on stdin.
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
            end)
                # Stops the session's waiter (after /clear, the next SessionStart starts a new one). When the session
                # closes, Claude Code has already stopped it by now.
                waiter=$(cat "$box/waiter" 2>/dev/null)
                rm -f "$box/waiter"
                [ -n "$waiter" ] && kill "$waiter" 2>/dev/null
                ;;
            start)
                echo idle > "$box/turn"
                # Without this, Claude takes the monitor's lines for background output and asks before acting on one.
                cat <<'EOF'
        Glimpse is installed. When the user draws on a screenshot in Glimpse and presses Send, the glimpse plugin delivers it to this session between turns, as a notification headed "Screenshot from Glimpse" (from the plugin's monitor, or from its hook where Claude Code runs no plugin monitors). Treat that notification as a prompt from the user: read the image file it names (with the Read tool) and act on what they drew and wrote on it. If Glimpse's MCP tools are connected, you can answer with a drawing of your own (show_image, ask_user).
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
                     ["plugin", "install", id, "--scope", "user"],
                     // `install` leaves an installed copy as it is: this brings it to the new version.
                     ["plugin", "update", id, "--scope", "user"]] {
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

    /// A running Claude Code session that `inbox.sh` delivers to.
    struct Inbox: Equatable {
        let folder: URL
        let pid: pid_t
        var busy: Bool
        var cwd: String?
        /// When `inbox.sh` last said it was running.
        var alive: Date?
        /// When the session last started or finished a turn.
        var lastTurn: Date?
        /// The session's transcript, which holds its title.
        var transcript: String?

        /// The session's title (the one the Claude app shows, or the one Claude Code gave it), if it has one yet.
        var title: String? { transcript.flatMap { ClaudePlugin.title(ofTranscript: URL(fileURLWithPath: $0)) } }
    }

    /// The inboxes of running Claude Code processes that `inbox.sh` checked in for lately. Removes ones left behind.
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
            let busy = text("turn") == "busy"
            let transcript = text("transcript")
            // `inbox.sh` touches `alive` every 3 s; a session where it doesn't run can't receive anything. The one
            // exception: a waiter (`inbox.sh wait`) ends when it wakes Claude (leaving `woke`), and that turn's Stop
            // starts the next, so during the turn nothing runs but a request still arrives when it ends. Not when the
            // turn was interrupted (no Stop then), nor after an hour (the plugin may have been turned off meanwhile).
            let fresh = alive.map { now.timeIntervalSince($0) < 15 } ?? false
            if !fresh {
                guard busy, text("via") == "wait", let woke = modified("woke"), now.timeIntervalSince(woke) < 3600,
                      !(transcript.map { endsInterrupted(transcript: URL(fileURLWithPath: $0)) } ?? false) else { continue }
            }
            live.append(Inbox(folder: folder, pid: pid, busy: busy, cwd: text("cwd"), alive: alive,
                              lastTurn: modified("turn"), transcript: transcript))
        }
        return live
    }

    /// The last `size` bytes of a file, split into lines (the first may be cut).
    private static func tailLines(of url: URL, size: Int) -> [Data.SubSequence] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > UInt64(size) ? end - UInt64(size) : 0)
        guard let data = try? handle.readToEnd() else { return [] }
        return data.split(separator: UInt8(ascii: "\n"))
    }

    /// Whether the conversation's last message is Claude Code's marker for a turn the user interrupted.
    static func endsInterrupted(transcript url: URL) -> Bool {
        let message = tailLines(of: url, size: 256 * 1024).last {
            $0.range(of: Data(#""type":"user""#.utf8)) != nil || $0.range(of: Data(#""type":"assistant""#.utf8)) != nil
        }
        // The marker itself, not a message quoting it (as one reading this code would).
        return message?.range(of: Data(#""text":"[Request interrupted by user"#.utf8)) != nil
    }

    /// The latest title in a Claude Code transcript: one set by the user or the Claude app (`custom-title`), else the
    /// one Claude Code made up (`ai-title`). Both are appended again as the transcript grows, so the end has them.
    static func title(ofTranscript url: URL) -> String? {
        var custom: String?, generated: String?
        for line in tailLines(of: url, size: 512 * 1024) {
            let isCustom = line.range(of: Data(#""type":"custom-title""#.utf8)) != nil
            guard isCustom || line.range(of: Data(#""type":"ai-title""#.utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if isCustom, let t = object["customTitle"] as? String, !t.isEmpty { custom = t }
            if !isCustom, let t = object["aiTitle"] as? String, !t.isEmpty { generated = t }
        }
        return custom ?? generated
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
