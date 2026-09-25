import Foundation

/// Serves tool calls from `Glimpse mcp` bridges: one JSON request per line (`{"name", "arguments"}`), answered with
/// one MCP tool result per line. The socket is only accessible to the current user.
final class AgentServer {
    static let shared = AgentServer()

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    func start() {
        guard acceptSource == nil else { return }
        let path = AgentSocket.path
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        unlink(path)
        guard var addr = AgentSocket.address(path), let fd = AgentSocket.makeSocket() else {
            NSLog("Glimpse: agent socket path is too long: \(path)")
            return
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            NSLog("Glimpse: could not open the agent socket: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.resume()
        acceptSource = source
    }

    private func acceptConnection() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        Thread.detachNewThread { Self.serve(client) }
    }

    private final class Box: @unchecked Sendable { var value: [String: Any] = [:] }

    /// Requests on one connection are answered in order; the bridge sends one at a time.
    private static func serve(_ fd: Int32) {
        let reader = LineReader(fd: fd)
        while let line = reader.next() {
            let response: [String: Any]
            if let request = AgentIO.object(line), let name = request["name"] as? String {
                let args = request["arguments"] as? [String: Any] ?? [:]
                let box = Box()
                let done = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    box.value = await AgentToolRunner.call(name, args)
                    done.signal()
                }
                done.wait()
                response = box.value
            } else {
                response = AgentTools.error("Malformed request.")
            }
            guard AgentIO.writeAll(fd, AgentIO.line(response)) else { break }
        }
        close(fd)
    }
}
