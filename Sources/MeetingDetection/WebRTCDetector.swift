import Foundation

/// Detects WebRTC meeting traffic by inspecting UDP sockets with `lsof` and the system-wide
/// UDP packet counter from `netstat`.
public final class WebRTCDetector: @unchecked Sendable {
    public struct Service: Sendable {
        public let name: String
        public let ports: [ClosedRange<Int>]
    }

    /// Confirmed services by STUN/TURN port. Several services share 3478-3481/50000-50003, so
    /// the table is ordered by specificity: service-unique ports first, shared STUN ports fall
    /// through to "Generic WebRTC". First match wins.
    public static let services: [Service] = [
        Service(name: "Google Meet", ports: [19302...19309]),
        Service(name: "Zoom", ports: [8801...8810]),
        Service(name: "Microsoft Teams", ports: [3480...3481, 50003...50003]),
        Service(name: "Slack Huddles", ports: [22466...22466]),
        Service(name: "FaceTime", ports: [16384...16400]),
        Service(name: "Discord", ports: [50000...50002]),
        Service(name: "Generic WebRTC", ports: [3478...3479, 5349...5349]),
    ]

    static let browserProcesses = [
        "Google Chrome", "Google Chrom", "Chrome", "Safari", "com.apple.WebKit", "Arc", "Brave",
        "Microsoft Edge", "Microsoft", "firefox", "Firefox", "Opera", "Vivaldi", "Dia",
    ]

    /// Google's IPv4 blocks commonly used by Meet media relays.
    static let googlePrefixes = [
        "142.250.", "142.251.", "172.217.", "172.253.", "216.58.", "216.239.", "74.125.",
        "64.233.", "66.102.", "66.249.", "108.177.", "173.194.", "209.85.", "35.190.",
        "2001:4860:", "2607:f8b0:", "2a00:1450:",
    ]

    public var lowThreshold: Double
    public var highThreshold: Double

    private var rateWindow = PacketRateWindow(windowSeconds: 8)
    private var flapGuard = WebRTCFlapGuard()
    private let lock = NSLock()

    public init(lowThreshold: Double = 20, highThreshold: Double = 50) {
        self.lowThreshold = lowThreshold
        self.highThreshold = highThreshold
    }

    public struct Reading: Sendable {
        public var state: SignalState
        public var packetRate: Double
        public var services: [String]
    }

    public func check(now: Date = Date()) -> Reading {
        let packets = Self.udpPacketCounter()
        let connections = Self.udpConnections()

        lock.lock()
        defer { lock.unlock() }

        let rate: Double
        if let packets {
            rate = rateWindow.add(count: packets, at: now)
        } else {
            rate = rateWindow.rate
        }

        guard let connections else {
            return Reading(state: .unknown, packetRate: rate, services: [])
        }

        var confirmed: [String] = []
        var probable = false
        for conn in connections {
            if let name = Self.serviceName(forRemotePort: conn.remotePort) {
                if !confirmed.contains(name) { confirmed.append(name) }
            } else if conn.remotePort == 443, Self.isBrowser(conn.process), Self.isGoogle(conn.remoteHost) {
                probable = true
            }
        }
        let probableActive = probable && rate >= lowThreshold
        let confirmedActive = !confirmed.isEmpty && (rate >= lowThreshold || packets == nil)

        let active = flapGuard.evaluate(
            confirmed: confirmedActive, probable: probableActive, rate: rate,
            highThreshold: highThreshold, now: now)

        var services = confirmedActive ? confirmed : []
        if active && services.isEmpty && probableActive { services = ["Google Meet (probable)"] }
        return Reading(state: active ? .active : .inactive, packetRate: rate, services: services)
    }

    // MARK: - Helpers

    public static func serviceName(forRemotePort port: Int) -> String? {
        for service in services where service.ports.contains(where: { $0.contains(port) }) {
            return service.name
        }
        return nil
    }

    static func isBrowser(_ process: String) -> Bool {
        browserProcesses.contains { process.hasPrefix($0) }
    }

    static func isGoogle(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return googlePrefixes.contains { h.hasPrefix($0) } || h.hasSuffix("1e100.net") || h.contains("google")
    }

    struct Connection {
        var process: String
        var remoteHost: String
        var remotePort: Int
    }

    /// Parse `lsof -nP -iUDP` output: `COMMAND PID USER FD TYPE DEVICE SIZE NODE NAME`,
    /// NAME looks like `10.0.0.2:5353->142.250.1.1:19305`.
    static func udpConnections() -> [Connection]? {
        guard let output = Shell.run("/usr/sbin/lsof", ["-nP", "-iUDP", "-FcnT"], timeout: 3) else { return nil }
        return parseLsofFieldOutput(output)
    }

    static func parseLsofFieldOutput(_ output: String) -> [Connection] {
        var result: [Connection] = []
        var command = ""
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "c": command = value
            case "n":
                guard let arrow = value.range(of: "->") else { continue }
                let remote = String(value[arrow.upperBound...])
                guard let colon = remote.lastIndex(of: ":"), let port = Int(remote[remote.index(after: colon)...]) else { continue }
                let host = String(remote[..<colon])
                result.append(Connection(process: command.replacingOccurrences(of: "\\x20", with: " "), remoteHost: host, remotePort: port))
            default: break
            }
        }
        return result
    }

    /// System-wide UDP datagrams received + sent, from `netstat -s -p udp`.
    static func udpPacketCounter() -> UInt64? {
        guard let output = Shell.run("/usr/sbin/netstat", ["-s", "-p", "udp"], timeout: 3) else { return nil }
        return parseNetstatUDP(output)
    }

    static func parseNetstatUDP(_ output: String) -> UInt64? {
        var total: UInt64 = 0
        var found = false
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("datagrams received") || line.hasSuffix("datagrams output") {
                if let n = UInt64(line.split(separator: " ").first ?? "") {
                    total += n
                    found = true
                }
            }
        }
        return found ? total : nil
    }
}

/// Minimal synchronous process runner with a timeout.
enum Shell {
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let deadline = DispatchTime.now() + timeout
        let group = DispatchGroup()
        var data = Data()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
