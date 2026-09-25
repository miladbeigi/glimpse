import AppKit

// `Glimpse mcp`: stdio MCP server for AI agents (no UI); see MCPBridge.
if CommandLine.arguments.dropFirst().first == "mcp" { MCPBridge.run() }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
