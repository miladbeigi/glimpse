import Foundation

/// Serves tool calls from `Glimpse mcp` bridges: one JSON request per line (`{"name", "arguments"}`), answered with
/// one MCP tool result per line. The socket is only accessible to the current user.
final class AgentServer {
    static let shared = AgentServer()

    private let queue = DispatchQueue(label: "Glimpse.AgentServer")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    /// The socket file we bound, to notice when something deletes or replaces it (a second copy of the app did).
    private var boundFile: (dev: dev_t, ino: ino_t)?
    private var watchdog: DispatchSourceTimer?

    func start() {
        queue.async { [self] in
            guard watchdog == nil else { return }
            bindIfNeeded()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.bindIfNeeded() }
            timer.resume()
            watchdog = timer
        }
    }

    func stop() {
        queue.sync {
            watchdog?.cancel()
            watchdog = nil
            if ownsSocketFile { unlink(AgentSocket.path) }
            closeListener()
        }
    }

    private var ownsSocketFile: Bool {
        guard let boundFile, let current = Self.fileIdentity() else { return false }
        return boundFile.dev == current.dev && boundFile.ino == current.ino
    }

    private static func fileIdentity() -> (dev: dev_t, ino: ino_t)? {
        var info = stat()
        guard lstat(AgentSocket.path, &info) == 0 else { return nil }
        return (info.st_dev, info.st_ino)
    }

    /// (Re)creates the socket unless ours is still in place or another live server is answering on it.
    private func bindIfNeeded() {
        if listenFD >= 0, ownsSocketFile { return }
        if let probe = AgentSocket.connect() {
            close(probe)
            return
        }
        closeListener()
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
        boundFile = Self.fileIdentity()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { Self.acceptConnection(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    private func closeListener() {
        if let acceptSource {
            acceptSource.cancel()
        } else if listenFD >= 0 {
            close(listenFD)
        }
        acceptSource = nil
        listenFD = -1
        boundFile = nil
    }

    private static func acceptConnection(_ listenFD: Int32) {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        Thread.detachNewThread { serve(client) }
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
