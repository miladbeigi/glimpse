import CoreGraphics
import XCTest
@testable import Glimpse

final class CollageTests: XCTestCase {
    func testRowSplitsEnumerateEveryOrderedPartition() {
        XCTAssertEqual(Collage.rowSplits(1), [[1]])
        XCTAssertEqual(Set(Collage.rowSplits(3).map { $0.map(String.init).joined(separator: ",") }),
                       ["3", "1,2", "2,1", "1,1,1"])
        XCTAssertEqual(Collage.rowSplits(5).count, 16)
        // Many pieces: only even splits, each still covering every piece.
        let many = Collage.rowSplits(14)
        XCTAssertEqual(many.count, 14)
        XCTAssertTrue(many.allSatisfy { $0.reduce(0, +) == 14 })
    }

    func testWideScreenshotsStackVertically() {
        let wide = CGSize(width: 1600, height: 300)
        let layout = Collage.layout(sizes: [wide, wide, wide], gap: 16)!
        XCTAssertEqual(layout.rows, [1, 1, 1])
    }

    func testTallScreenshotsGoSideBySide() {
        let tall = CGSize(width: 300, height: 1400)
        let layout = Collage.layout(sizes: [tall, tall, tall], gap: 16)!
        XCTAssertEqual(layout.rows, [3])
    }

    func testFourSquaresMakeAGrid() {
        let square = CGSize(width: 800, height: 800)
        let layout = Collage.layout(sizes: Array(repeating: square, count: 4), gap: 16)!
        XCTAssertEqual(layout.rows, [2, 2])
    }

    func testFramesKeepOrderSizeAndDoNotOverlap() {
        let sizes = [CGSize(width: 900, height: 500), CGSize(width: 400, height: 700), CGSize(width: 1200, height: 300),
                     CGSize(width: 300, height: 300)]
        let layout = Collage.layout(sizes: sizes, gap: 20)!
        XCTAssertEqual(layout.frames.count, 4)
        for (frame, size) in zip(layout.frames, sizes) {
            XCTAssertEqual(frame.size, size)
            XCTAssertTrue(CGRect(origin: .zero, size: layout.size).contains(frame))
        }
        for i in 0..<4 {
            for j in (i + 1)..<4 { XCTAssertFalse(layout.frames[i].intersects(layout.frames[j]), "\(i) overlaps \(j)") }
        }
        XCTAssertGreaterThan(layout.downscale, 0)
        XCTAssertLessThanOrEqual(layout.downscale, 1)
    }

    func testChosenLayoutIsShrunkLeast() {
        let sizes = [CGSize(width: 1400, height: 900), CGSize(width: 700, height: 1200), CGSize(width: 1000, height: 1000)]
        let best = Collage.layout(sizes: sizes, gap: 16)!
        let limits = Collage.Limits()
        // Brute force the same rule to confirm nothing beats it.
        for rows in Collage.rowSplits(3) {
            var i = 0, width: CGFloat = 0, height: CGFloat = 16
            for count in rows {
                let items = sizes[i..<(i + count)]
                width = max(width, items.reduce(0) { $0 + $1.width } + 16 * CGFloat(count - 1))
                height += (items.map(\.height).max() ?? 0) + 16
                i += count
            }
            width += 32
            let f = min(1, limits.maxLongEdge / max(width, height), (limits.maxPixels / (width * height)).squareRoot())
            XCTAssertLessThanOrEqual(f, best.downscale + 1e-9)
        }
    }

    func testRenderDrawsEveryPiece() {
        func solid(_ w: Int, _ h: Int, _ v: CGFloat) -> CGImage {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: v, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()!
        }
        let (image, layout) = Collage.render([solid(400, 300, 1), solid(300, 300, 0.5)])!
        XCTAssertEqual(image.width, Int(layout.size.width.rounded(.up)))
        XCTAssertEqual(image.height, Int(layout.size.height.rounded(.up)))
    }
}

final class DoubleTapTests: XCTestCase {
    func testTwoQuickTapsFire() {
        var d = DoubleTapDetector()
        XCTAssertFalse(d.rightShift(down: true, clean: true, at: 0))
        XCTAssertFalse(d.rightShift(down: false, clean: true, at: 0.08))
        XCTAssertTrue(d.rightShift(down: true, clean: true, at: 0.25))
    }

    func testSlowSecondTapStartsOver() {
        var d = DoubleTapDetector()
        _ = d.rightShift(down: true, clean: true, at: 0)
        _ = d.rightShift(down: false, clean: true, at: 0.08)
        XCTAssertFalse(d.rightShift(down: true, clean: true, at: 1.0))
        _ = d.rightShift(down: false, clean: true, at: 1.05)
        XCTAssertTrue(d.rightShift(down: true, clean: true, at: 1.2))
    }

    func testHoldingShiftToTypeDoesNotCount() {
        var d = DoubleTapDetector()
        _ = d.rightShift(down: true, clean: true, at: 0)
        _ = d.rightShift(down: false, clean: true, at: 0.9) // held to type a capital
        XCTAssertFalse(d.rightShift(down: true, clean: true, at: 1.0))
    }

    func testAnotherKeyInBetweenCancels() {
        var d = DoubleTapDetector()
        _ = d.rightShift(down: true, clean: true, at: 0)
        _ = d.rightShift(down: false, clean: true, at: 0.05)
        d.reset()
        XCTAssertFalse(d.rightShift(down: true, clean: true, at: 0.2))
    }

    func testWithOtherModifiersDoesNotCount() {
        var d = DoubleTapDetector()
        _ = d.rightShift(down: true, clean: true, at: 0)
        _ = d.rightShift(down: false, clean: true, at: 0.05)
        XCTAssertFalse(d.rightShift(down: true, clean: false, at: 0.2))
    }
}

final class FreehandArrowTests: XCTestCase {
    func testStraightishStrokeIsStraight() {
        let pts = (0...20).map { CGPoint(x: CGFloat($0) * 10, y: CGFloat($0 % 2) * 1.5) }
        XCTAssertTrue(FreehandArrow.isNearlyStraight(pts))
    }

    func testCurveIsKept() {
        let pts = (0...30).map { i -> CGPoint in
            let t = CGFloat(i) / 30 * .pi
            return CGPoint(x: 100 - cos(t) * 100, y: sin(t) * 80)
        }
        XCTAssertFalse(FreehandArrow.isNearlyStraight(pts))
        XCTAssertNotNil(FreehandArrow.paths(pts, width: 4))
    }

    func testMovingTheHeadBendsTheStrokeAndKeepsTheTail() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 40), CGPoint(x: 100, y: 0)]
        let moved = FreehandArrow.moving(pts, end: true, to: CGPoint(x: 0, y: 200))
        XCTAssertEqual(moved.first!.x, 0, accuracy: 1e-9)
        XCTAssertEqual(moved.first!.y, 0, accuracy: 1e-9)
        XCTAssertEqual(moved.last!.x, 0, accuracy: 1e-6)
        XCTAssertEqual(moved.last!.y, 200, accuracy: 1e-6)
    }

    func testCurvedArrowHitTestAndBounds() {
        let pts = (0...20).map { i -> CGPoint in CGPoint(x: CGFloat(i) * 10, y: CGFloat(i * i) / 2) }
        let a = Annotation(kind: .arrow, start: pts.first!, end: pts.last!, points: pts, color: .defaultRed, lineWidth: 4)
        XCTAssertTrue(a.isCurvedArrow)
        XCTAssertTrue(a.hitTest(pts[10], strict: true))
        // The straight chord isn't on a strongly curved stroke.
        XCTAssertFalse(a.hitTest(CGPoint(x: 100, y: 100), strict: true))
        XCTAssertTrue(a.bounds.contains(CGPoint(x: 200, y: 200)))
    }

    func testAnnotationsRoundTripAsJSON() throws {
        let state = EditorDocumentState(annotations: [
            Annotation(kind: .arrow, start: .zero, end: CGPoint(x: 5, y: 5), points: [.zero, CGPoint(x: 3, y: 1), CGPoint(x: 5, y: 5)],
                       color: .defaultRed, lineWidth: 4),
            Annotation(kind: .text, start: CGPoint(x: 1, y: 2), end: CGPoint(x: 1, y: 2), color: .defaultRed, lineWidth: 4,
                       text: "hi", fontSize: 18, textStyle: .background),
        ], cropRect: CGRect(x: 0, y: 0, width: 10, height: 10), outputScale: 1)
        let decoded = try JSONDecoder().decode(EditorDocumentState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
    }
}

final class NotePlacementTests: XCTestCase {
    private let image = CGSize(width: 1000, height: 800)

    private func box(_ r: CGRect) -> Annotation {
        Annotation(kind: .rectangle, start: r.origin, end: CGPoint(x: r.maxX, y: r.maxY), color: .defaultRed, lineWidth: 4)
    }

    func testNoteGoesRightOfABox() {
        let p = NotePlacement.placement(for: box(CGRect(x: 100, y: 100, width: 200, height: 100)), imageSize: image)
        XCTAssertEqual(p.horizontal, .leading)
        XCTAssertEqual(p.anchor.x, 308)
    }

    func testNoteGoesLeftOfABoxAtTheRightEdge() {
        let p = NotePlacement.placement(for: box(CGRect(x: 800, y: 100, width: 190, height: 100)), imageSize: image)
        XCTAssertEqual(p.horizontal, .trailing)
    }

    func testNoteSitsPastAnArrowsTail() {
        // Arrow pointing right: the note goes to the left of where it starts.
        let right = Annotation(kind: .arrow, start: CGPoint(x: 300, y: 400), end: CGPoint(x: 600, y: 400), color: .defaultRed, lineWidth: 4)
        XCTAssertEqual(NotePlacement.placement(for: right, imageSize: image).horizontal, .trailing)
        // Arrow pointing up: the note goes below its tail.
        let up = Annotation(kind: .arrow, start: CGPoint(x: 300, y: 600), end: CGPoint(x: 300, y: 200), color: .defaultRed, lineWidth: 4)
        let p = NotePlacement.placement(for: up, imageSize: image)
        XCTAssertEqual(p.vertical, .top)
        XCTAssertGreaterThan(p.anchor.y, 600)
    }

    func testOriginStaysInsideTheImage() {
        let p = NotePlacement.Placement(anchor: CGPoint(x: 990, y: 5), horizontal: .leading, vertical: .bottom)
        let o = NotePlacement.origin(p, size: CGSize(width: 120, height: 30), imageSize: image)
        XCTAssertEqual(o.x, 880)
        XCTAssertEqual(o.y, 0)
    }
}

final class AgentMarksTests: XCTestCase {
    private let mapping = AgentMarks.Mapping(origin: .zero, pointsPerUnit: 0.5) // a 2× screenshot
    private let color = RGBA(r: 0.85, g: 0.47, b: 0.34)

    func testMarksBecomeAnnotationsInPoints() throws {
        let marks: [[String: Any]] = [
            ["type": "arrow", "from": [100, 100], "to": [300, 100], "label": "this button"],
            ["type": "box", "x": 40, "y": 60, "width": 200, "height": 100],
            ["type": "number", "at": [10, 10]],
            ["type": "text", "at": [500, 500], "text": "too tight", "color": "#00FF00"],
        ]
        let a = try AgentMarks.annotations(marks, mapping: mapping, color: color, imageSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(a.map(\.kind), [.arrow, .text, .rectangle, .counter, .text])
        XCTAssertEqual(a[0].start, CGPoint(x: 50, y: 50))
        XCTAssertEqual(a[0].end, CGPoint(x: 150, y: 50))
        XCTAssertEqual(a[1].text, "this button")
        XCTAssertEqual(a[2].rect, CGRect(x: 20, y: 30, width: 100, height: 50))
        XCTAssertEqual(a[4].color, RGBA(r: 0, g: 1, b: 0))
        XCTAssertEqual(a[0].color, color)
    }

    func testBadMarksSayWhatsWrong() {
        XCTAssertThrowsError(try AgentMarks.annotations([["type": "box", "x": 1]], mapping: mapping, color: color,
                                                        imageSize: CGSize(width: 100, height: 100))) { error in
            XCTAssertTrue((error as? AgentMarks.Invalid)?.message.contains("Mark 1 (box)") == true)
        }
        XCTAssertThrowsError(try AgentMarks.annotations([["type": "star"]], mapping: mapping, color: color,
                                                        imageSize: CGSize(width: 100, height: 100)))
    }

    func testDescribeIsTheInverse() throws {
        let marks: [[String: Any]] = [
            ["type": "line", "from": [10, 20], "to": [30, 40]],
            ["type": "ellipse", "x": 100, "y": 50, "width": 60, "height": 40],
        ]
        let a = try AgentMarks.annotations(marks, mapping: mapping, color: color, imageSize: CGSize(width: 800, height: 600))
        let back = AgentMarks.describe(a, mapping: mapping)
        XCTAssertEqual(back[0]["type"] as? String, "line")
        XCTAssertEqual(back[0]["from"] as? [Double], [10, 20])
        XCTAssertEqual(back[0]["to"] as? [Double], [30, 40])
        XCTAssertEqual(back[1]["type"] as? String, "ellipse")
        XCTAssertEqual(back[1]["width"] as? Double, 60)
        XCTAssertEqual(back[1]["color"] as? String, color.hex)
    }

    func testHexColours() {
        XCTAssertEqual(RGBA(hex: "#FF8000")?.hex, "#FF8000")
        XCTAssertNil(RGBA(hex: "nope"))
    }

    func testClientNames() {
        XCTAssertEqual(AgentColors.name(forClient: "claude-code"), "Claude")
        XCTAssertEqual(AgentColors.name(forClient: "codex-mcp-client"), "Codex")
        XCTAssertEqual(AgentColors.name(forClient: nil), "Agent")
        XCTAssertEqual(AgentColors.name(forClient: "goose-cli"), "Goose")
    }
}

final class AgentSessionTests: XCTestCase {
    func testRecognisesInteractiveSessions() {
        XCTAssertEqual(ProcessList.classify(path: "/Users/me/.local/share/claude/versions/2.1.3", arguments: ["claude"]), .claudeCode)
        XCTAssertEqual(ProcessList.classify(path: "/opt/homebrew/bin/node",
                                            arguments: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]), .claudeCode)
        XCTAssertEqual(ProcessList.classify(path: "/opt/homebrew/bin/codex", arguments: ["codex", "--model", "gpt-5"]), .codex)
    }

    func testIgnoresHeadlessRuns() {
        XCTAssertNil(ProcessList.classify(path: "/x/claude.app/Contents/MacOS/claude",
                                          arguments: ["claude", "--output-format", "stream-json", "--input-format", "stream-json"]))
        XCTAssertNil(ProcessList.classify(path: "/usr/local/bin/claude", arguments: ["claude", "-p", "hi"]))
        XCTAssertNil(ProcessList.classify(path: "/usr/local/bin/codex", arguments: ["codex", "exec", "fix it"]))
        XCTAssertNil(ProcessList.classify(path: "/usr/local/bin/codex", arguments: ["codex", "app-server"]))
        XCTAssertNil(ProcessList.classify(path: "/opt/homebrew/bin/node", arguments: ["node", "server.js"]))
    }

    func testParsesProcArgs() {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(2)) { bytes += $0 }
        bytes += Array("/usr/bin/claude".utf8) + [0, 0, 0]
        bytes += Array("claude".utf8) + [0] + Array("--resume".utf8) + [0]
        bytes += Array("HOME=/Users/me".utf8) + [0]
        XCTAssertEqual(ProcessList.parseProcArgs(bytes), ["claude", "--resume"])
    }

    func testFindsThisProcessesParent() {
        XCTAssertEqual(ProcessList.parent(of: getpid()), getppid())
        XCTAssertTrue(ProcessList.allPIDs().contains(getpid()))
        XCTAssertNotNil(ProcessList.arguments(of: getpid()))
    }
}

final class EditorContextTests: XCTestCase {
    @MainActor
    func testBatchMovesThroughTheQueue() {
        let img = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let b = Capture(image: img, scale: 1), c = Capture(image: img, scale: 1)
        let ctx = EditorContext(fromStack: true, queue: [b, c], batchIndex: 1, batchCount: 3)
        let (n1, ctx1) = ctx.next()!
        XCTAssertTrue(n1 === b)
        XCTAssertEqual(ctx1.batchIndex, 2)
        let (n2, ctx2) = ctx1.next()!
        XCTAssertTrue(n2 === c)
        XCTAssertEqual(ctx2.batchIndex, 3)
        XCTAssertNil(ctx2.next())
    }
}

final class ClaudePluginTests: XCTestCase {
    private func writePlugin(inboxRoot: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glimpse-plugin-\(UUID().uuidString)")
        for (path, contents) in ClaudePlugin.files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = path.hasSuffix("inbox-root") ? inboxRoot.path + "\n" : contents
            try Data(text.utf8).write(to: url)
            if path.hasSuffix(".sh") { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        return dir.appendingPathComponent("plugins/glimpse/scripts")
    }

    private func run(_ script: URL, _ args: [String], env: [String: String], stdin: String = "",
                     stderr: Pipe? = nil) throws -> Process {
        let p = Process()
        if let stderr { p.standardError = stderr }
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path] + args
        p.environment = env.merging(["PATH": "/usr/bin:/bin"]) { a, _ in a }
        let input = Pipe()
        p.standardInput = input
        try p.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        return p
    }

    func testRequestLineIsOneLineNamingTheImages() {
        let line = ClaudePlugin.requestLine(paths: ["/tmp/a.png", "/tmp/b.png"])
        XCTAssertFalse(line.contains("\n"))
        XCTAssertTrue(line.hasPrefix("From Glimpse:"))
        XCTAssertTrue(line.contains("\"/tmp/a.png\", \"/tmp/b.png\""))
        XCTAssertEqual(ClaudePlugin.oneLine("a\nb\n  c"), "a b c")
    }

    func testManifestsAreValidJSON() throws {
        for (path, text) in ClaudePlugin.files where path.hasSuffix(".json") {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(text.utf8)), path)
        }
    }

    /// The monitor prints a delivered request between turns, holds it during one, and the hooks flip the state.
    func testMonitorDeliversBetweenTurns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glimpse-inbox-\(UUID().uuidString)")
        let scripts = try writePlugin(inboxRoot: root)
        // A stand-in for the Claude Code process.
        let claude = Process()
        claude.executableURL = URL(fileURLWithPath: "/bin/sleep")
        claude.arguments = ["20"]
        try claude.run()
        defer { claude.terminate() }
        let env = ["CLAUDE_PID": "\(claude.processIdentifier)"]

        let start = try run(scripts.appendingPathComponent("turn.sh"), ["start"], env: env,
                            stdin: #"{"session_id":"abc","transcript_path":"/tmp/t.jsonl"}"#)
        start.waitUntilExit()
        let box = root.appendingPathComponent("\(claude.processIdentifier)")
        XCTAssertEqual(try String(contentsOf: box.appendingPathComponent("session"), encoding: .utf8), "abc\n")

        let output = Pipe()
        let monitor = Process()
        monitor.executableURL = URL(fileURLWithPath: "/bin/sh")
        monitor.arguments = [scripts.appendingPathComponent("inbox.sh").path]
        monitor.environment = env.merging(["PATH": "/usr/bin:/bin"]) { a, _ in a }
        monitor.standardOutput = output
        try monitor.run()
        defer { monitor.terminate() }
        Thread.sleep(forTimeInterval: 0.5)

        let inboxes = ClaudePlugin.liveInboxes(root: root)
        XCTAssertEqual(inboxes.map(\.pid), [claude.processIdentifier])
        XCTAssertEqual(inboxes.first?.busy, false)

        // Mid-turn: it waits.
        try run(scripts.appendingPathComponent("turn.sh"), ["busy"], env: env).waitUntilExit()
        try ClaudePlugin.deliver("hello\nthere", to: ClaudePlugin.liveInboxes(root: root)[0])
        Thread.sleep(forTimeInterval: 0.9)
        let pending = try FileManager.default.contentsOfDirectory(atPath: box.path).filter { $0.hasSuffix(".line") }
        XCTAssertEqual(pending.count, 1)

        // Turn over: printed once, as one line, and removed.
        try run(scripts.appendingPathComponent("turn.sh"), ["idle"], env: env).waitUntilExit()
        Thread.sleep(forTimeInterval: 0.9)
        monitor.terminate()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(printed, "hello there\n")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: box.path).filter { $0.hasSuffix(".line") }.isEmpty)
    }

    func testDeadSessionsAreCleanedUp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glimpse-inbox-\(UUID().uuidString)")
        let dead = root.appendingPathComponent("999999")
        try FileManager.default.createDirectory(at: dead, withIntermediateDirectories: true)
        try Data().write(to: dead.appendingPathComponent("alive"))
        XCTAssertTrue(ClaudePlugin.liveInboxes(root: root).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
    }

    /// Where no monitor runs (the Claude desktop app), `inbox.sh wait` hands requests over by exiting 2 with them on
    /// stderr, holds them during a turn, lets one waiter run at a time and steps aside for a monitor.
    func testWaiterDeliversBetweenTurnsAndStepsAsideForAMonitor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glimpse-inbox-\(UUID().uuidString)")
        let scripts = try writePlugin(inboxRoot: root)
        // A stand-in for a Claude Code process driven over stream-json, the way the Claude app runs it.
        let claude = Process()
        claude.executableURL = URL(fileURLWithPath: "/bin/sh")
        claude.arguments = ["-c", "sleep 30; :", "claude", "--output-format", "stream-json", "--input-format", "stream-json"]
        try claude.run()
        defer { claude.terminate() }
        // It isn't under Claude.app: stand in for it.
        let env = ["CLAUDE_PID": "\(claude.processIdentifier)", "GLIMPSE_INBOX_ANY_HOST": "1"]
        let box = root.appendingPathComponent("\(claude.processIdentifier)")
        let inbox = scripts.appendingPathComponent("inbox.sh")

        // Without the stand-in, a stream-json host other than the Claude app (an SDK script) gets no waiter.
        let sdk = try run(inbox, ["wait"], env: ["CLAUDE_PID": "\(claude.processIdentifier)"])
        sdk.waitUntilExit()
        XCTAssertEqual(sdk.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.path))

        try run(scripts.appendingPathComponent("turn.sh"), ["busy"], env: env).waitUntilExit()
        let errors = Pipe()
        let waiter = try run(inbox, ["wait"], env: env, stdin: #"{"session_id":"abc"}"#, stderr: errors)
        Thread.sleep(forTimeInterval: 0.5)
        // A second one (the next hook) leaves at once.
        let second = try run(inbox, ["wait"], env: env)
        second.waitUntilExit()
        XCTAssertEqual(second.terminationStatus, 0)

        // Live even before anything is sent; mid-turn the request waits.
        XCTAssertEqual(ClaudePlugin.liveInboxes(root: root).first?.busy, true)
        try ClaudePlugin.deliver("hello\nthere", to: ClaudePlugin.liveInboxes(root: root)[0])
        Thread.sleep(forTimeInterval: 0.9)
        XCTAssertTrue(waiter.isRunning)

        // Turn over: it hands the request over and ends with 2, marking the turn it starts.
        try run(scripts.appendingPathComponent("turn.sh"), ["idle"], env: env).waitUntilExit()
        waiter.waitUntilExit()
        XCTAssertEqual(waiter.terminationStatus, 2)
        XCTAssertEqual(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "hello there\n")
        XCTAssertEqual(try String(contentsOf: box.appendingPathComponent("turn"), encoding: .utf8), "busy\n")
        // Nothing runs during that turn, but the session stays reachable until Stop starts the next waiter...
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
                                              ofItemAtPath: box.appendingPathComponent("alive").path)
        XCTAssertEqual(ClaudePlugin.liveInboxes(root: root).map(\.pid), [claude.processIdentifier])
        // ...also when its last message only quotes the interrupt marker...
        let transcript = root.appendingPathComponent("t.jsonl")
        try Data((#"{"type":"assistant","message":{"content":[{"type":"text","text":"grep '[Request interrupted by user'"}]}}"#
                  + "\n").utf8).write(to: transcript)
        try Data((transcript.path + "\n").utf8).write(to: box.appendingPathComponent("transcript"))
        XCTAssertEqual(ClaudePlugin.liveInboxes(root: root).count, 1)
        // ...but not when the user interrupted that turn (no Stop comes).
        try Data((#"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"# + "\n"
                  + #"{"type":"custom-title","customTitle":"Renamed"}"# + "\n").utf8).write(to: transcript)
        try Data((transcript.path + "\n").utf8).write(to: box.appendingPathComponent("transcript"))
        XCTAssertTrue(ClaudePlugin.liveInboxes(root: root).isEmpty)
        try FileManager.default.removeItem(at: box.appendingPathComponent("transcript"))

        // SessionEnd stops the waiter, so Claude Code isn't kept from exiting.
        try run(scripts.appendingPathComponent("turn.sh"), ["idle"], env: env).waitUntilExit()
        let fourth = try run(inbox, ["wait"], env: env)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(fourth.isRunning)
        try run(scripts.appendingPathComponent("turn.sh"), ["end"], env: env).waitUntilExit()
        fourth.waitUntilExit()
        XCTAssertNotEqual(fourth.terminationStatus, 2)

        // With a monitor running, a waiter leaves it the inbox.
        let monitor = try run(inbox, [], env: env)
        defer { monitor.terminate() }
        Thread.sleep(forTimeInterval: 0.3)
        let third = try run(inbox, ["wait"], env: env)
        third.waitUntilExit()
        XCTAssertEqual(third.terminationStatus, 0)
    }

    /// `claude -p` waits for asyncRewake hooks before it exits, so a waiter must not stay with it.
    func testWaiterLeavesOneShotRunsAtOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glimpse-inbox-\(UUID().uuidString)")
        let scripts = try writePlugin(inboxRoot: root)
        let claude = Process()
        claude.executableURL = URL(fileURLWithPath: "/bin/sh")
        claude.arguments = ["-c", "sleep 30; :", "claude", "-p", "--output-format", "stream-json"]
        try claude.run()
        defer { claude.terminate() }
        let waiter = try run(scripts.appendingPathComponent("inbox.sh"), ["wait"], env: ["CLAUDE_PID": "\(claude.processIdentifier)"])
        waiter.waitUntilExit()
        XCTAssertEqual(waiter.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(claude.processIdentifier)").path))
    }

    /// A request claimed by a process that died before printing it goes back in line.
    func testRequestClaimedByADeadProcessIsDeliveredAgain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glimpse-inbox-\(UUID().uuidString)")
        let scripts = try writePlugin(inboxRoot: root)
        let claude = Process()
        claude.executableURL = URL(fileURLWithPath: "/bin/sleep")
        claude.arguments = ["20"]
        try claude.run()
        defer { claude.terminate() }
        let box = root.appendingPathComponent("\(claude.processIdentifier)")
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        try Data("lost\n".utf8).write(to: box.appendingPathComponent("1-a.line.999999"))
        let output = Pipe()
        let monitor = Process()
        monitor.executableURL = URL(fileURLWithPath: "/bin/sh")
        monitor.arguments = [scripts.appendingPathComponent("inbox.sh").path]
        monitor.environment = ["CLAUDE_PID": "\(claude.processIdentifier)", "PATH": "/usr/bin:/bin"]
        monitor.standardOutput = output
        try monitor.run()
        Thread.sleep(forTimeInterval: 0.8)
        monitor.terminate()
        monitor.waitUntilExit()
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "lost\n")
    }

    func testTitleIsTheLatestCustomTitleElseTheGeneratedOne() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        let lines = [
            #"{"type":"ai-title","aiTitle":"Made up","sessionId":"a"}"#,
            #"{"type":"user","message":{"content":"\"type\":\"custom-title\" in a message"}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        XCTAssertEqual(ClaudePlugin.title(ofTranscript: url), "Made up")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        handle.write(Data((#"{"type":"custom-title","customTitle":"Fix the \"login\" bug","sessionId":"a"}"# + "\n").utf8))
        handle.write(Data((#"{"type":"ai-title","aiTitle":"Later","sessionId":"a"}"# + "\n").utf8))
        try handle.close()
        XCTAssertEqual(ClaudePlugin.title(ofTranscript: url), "Fix the \"login\" bug")
        XCTAssertNil(ClaudePlugin.title(ofTranscript: url.appendingPathExtension("missing")))
    }

    func testHooksStartAWaiterAtEveryTurnEdge() throws {
        let text = try XCTUnwrap(ClaudePlugin.files["plugins/glimpse/hooks/hooks.json"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: [[String: Any]]])
        for event in ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure"] {
            let commands = try XCTUnwrap(hooks[event]?.first?["hooks"] as? [[String: Any]], event)
            let wait = try XCTUnwrap(commands.first { ($0["command"] as? String)?.hasSuffix("inbox.sh wait") == true }, event)
            XCTAssertEqual(wait["asyncRewake"] as? Bool, true, event)
        }
    }
}
