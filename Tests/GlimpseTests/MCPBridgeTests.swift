import XCTest
@testable import Glimpse

final class MCPBridgeTests: XCTestCase {
    private func handle(_ message: [String: Any], tool: (String, [String: Any]) -> [String: Any] = { _, _ in [:] }) -> [String: Any]? {
        MCPBridge.handle(message, callTool: tool)
    }

    func testInitializeNegotiatesVersion() throws {
        let known = try XCTUnwrap(handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26"]]))
        let result = try XCTUnwrap(known["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "glimpse")

        let unknown = try XCTUnwrap(handle(["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]]))
        XCTAssertEqual((unknown["result"] as? [String: Any])?["protocolVersion"] as? String, MCPBridge.supportedProtocolVersions.last)
    }

    func testNotificationsGetNoReply() {
        XCTAssertNil(handle(["jsonrpc": "2.0", "method": "notifications/initialized"]))
    }

    func testListsTools() throws {
        let response = try XCTUnwrap(handle(["jsonrpc": "2.0", "id": "a", "method": "tools/list"]))
        XCTAssertEqual(response["id"] as? String, "a")
        let tools = try XCTUnwrap((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names), ["list_windows", "list_displays", "screenshot_screen", "screenshot_window", "screenshot_region", "read_text"])
        for tool in tools {
            XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object", "\(tool["name"] ?? "")")
            XCTAssertTrue(JSONSerialization.isValidJSONObject(tool))
        }
    }

    func testForwardsToolCalls() throws {
        var received: (String, [String: Any])?
        let response = try XCTUnwrap(handle(
            ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "screenshot_window", "arguments": ["app": "Safari"]]],
            tool: { name, args in received = (name, args); return AgentTools.text("ok") }))
        XCTAssertEqual(received?.0, "screenshot_window")
        XCTAssertEqual(received?.1["app"] as? String, "Safari")
        XCTAssertEqual(response["id"] as? Int, 7)
        let content = try XCTUnwrap((response["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "ok")
    }

    func testErrors() throws {
        let unknownMethod = try XCTUnwrap(handle(["jsonrpc": "2.0", "id": 1, "method": "resources/list"]))
        XCTAssertEqual((unknownMethod["error"] as? [String: Any])?["code"] as? Int, -32601)

        var called = false
        let unknownTool = try XCTUnwrap(handle(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "rm_rf"]],
                                               tool: { _, _ in called = true; return [:] }))
        XCTAssertEqual((unknownTool["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertFalse(called)
    }

    func testLineFramingRoundTrips() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let message: [String: Any] = ["text": "two\nlines", "n": 1]
        XCTAssertTrue(AgentIO.writeAll(fds[1], AgentIO.line(message) + AgentIO.line(["n": 2])))
        close(fds[1])
        let reader = LineReader(fd: fds[0])
        XCTAssertEqual(AgentIO.object(try XCTUnwrap(reader.next()))?["text"] as? String, "two\nlines")
        XCTAssertEqual(AgentIO.object(try XCTUnwrap(reader.next()))?["n"] as? Int, 2)
        XCTAssertNil(reader.next())
        close(fds[0])
    }

    func testSocketPathMustFit() {
        XCTAssertNotNil(AgentSocket.address("/tmp/glimpse.sock"))
        XCTAssertNil(AgentSocket.address("/" + String(repeating: "a", count: 200)))
    }
}
