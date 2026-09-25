import Foundation

/// `Glimpse mcp`: a stdio MCP server (newline-delimited JSON-RPC 2.0) for AI agents. It answers the protocol itself and
/// forwards tool calls to the running Glimpse app, launching it if needed, so captures use the app's Screen Recording
/// permission rather than the agent's.
enum MCPBridge {
    static let supportedProtocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]

    static let instructions = """
        Glimpse takes screenshots of this Mac for you. Use list_windows to find a window, then screenshot_window; \
        screenshot_screen and screenshot_region for displays and areas; read_text to get text via OCR instead of an image. \
        Every screenshot is also saved as a full-resolution file whose path is in the result.
        """

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let input = LineReader(fd: STDIN_FILENO)
        let app = AppConnection()
        while let line = input.next() {
            guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) else { continue }
            let response: [String: Any]?
            if let message = AgentIO.object(line) {
                response = handle(message) { name, args in app.call(name, args) }
            } else {
                response = errorResponse(id: NSNull(), code: -32700, message: "Parse error")
            }
            if let response { AgentIO.writeAll(STDOUT_FILENO, AgentIO.line(response)) }
        }
        exit(0)
    }

    /// Handles one JSON-RPC message; nil for notifications and anything else that takes no reply.
    static func handle(_ message: [String: Any], callTool: (String, [String: Any]) -> [String: Any]) -> [String: Any]? {
        guard let method = message["method"] as? String, let id = message["id"], !(id is NSNull) else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let version = requested.flatMap { supportedProtocolVersions.contains($0) ? $0 : nil } ?? supportedProtocolVersions.last!
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            result = [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "glimpse", "title": "Glimpse", "version": appVersion],
                "instructions": instructions,
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": AgentTools.definitions]
        case "tools/call":
            guard let name = params["name"] as? String else {
                return errorResponse(id: id, code: -32602, message: "tools/call needs a tool name")
            }
            guard AgentTools.definitions.contains(where: { $0["name"] as? String == name }) else {
                return errorResponse(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            result = callTool(name, params["arguments"] as? [String: Any] ?? [:])
        default:
            return errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
}

/// The bridge's connection to the app, reconnecting (and launching the app) when needed.
private final class AppConnection {
    private var fd: Int32 = -1
    private var reader: LineReader?

    func call(_ name: String, _ args: [String: Any]) -> [String: Any] {
        // Two attempts: the app may have quit or restarted since the last call.
        for _ in 0..<2 {
            guard ensureConnected() else {
                return AgentTools.error("Couldn't reach the Glimpse app. Make sure Glimpse \(minimumVersion) or later is installed and can open.")
            }
            if AgentIO.writeAll(fd, AgentIO.line(["name": name, "arguments": args])),
               let line = reader?.next(), let result = AgentIO.object(line) {
                return result
            }
            disconnect()
        }
        return AgentTools.error("Lost the connection to the Glimpse app.")
    }

    private let minimumVersion = "1.2.0"

    private func ensureConnected() -> Bool {
        if fd >= 0 { return true }
        if connect() { return true }
        launchApp()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            usleep(250_000)
            if connect() { return true }
        }
        return false
    }

    private func connect() -> Bool {
        guard let socket = AgentSocket.connect() else { return false }
        fd = socket
        reader = LineReader(fd: socket)
        return true
    }

    private func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1
        reader = nil
    }

    /// Opens the app this executable belongs to, in the background (or the installed one when run outside a bundle).
    private func launchApp() {
        let bundle = Bundle.main.bundleURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = bundle.pathExtension == "app" ? ["-g", bundle.path] : ["-g", "-b", "com.milad.glimpse"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
