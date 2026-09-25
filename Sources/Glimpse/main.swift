import AppKit

// `Glimpse mcp`: stdio MCP server for AI agents (no UI); see MCPBridge.
if CommandLine.arguments.dropFirst().first == "mcp" { MCPBridge.run() }

// One copy at a time: a second one (another build, or the executable run directly, e.g. by an agent configured
// without `mcp`) would fight over the global shortcuts and the agent socket.
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
    FileHandle.standardError.write(Data("Glimpse is already running. AI agents should run: \(CommandLine.arguments[0]) mcp\n".utf8))
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
