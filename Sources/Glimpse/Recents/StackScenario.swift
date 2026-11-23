#if DEBUG
import AppKit

/// DEBUG-only: `GLIMPSE_DEBUG_SCENARIO=stack GLIMPSE_DEBUG_IMAGES=a.png:b.png:… GLIMPSE_SNAPSHOT_DIR=…` fills the
/// recent screenshots stack (in memory only), renders the stack, a stitched image, a curved arrow with a note and an
/// agent's question to PNGs, and quits.
@MainActor
enum StackScenario {
    static func run() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["GLIMPSE_SNAPSHOT_DIR"], let list = env["GLIMPSE_DEBUG_IMAGES"] else { return }
        let out = URL(fileURLWithPath: dir)
        let images = list.split(separator: ":").compactMap { ImageUtil.load(url: URL(fileURLWithPath: String($0))) }
        guard images.count >= 3 else { NSLog("Glimpse stack scenario: need 3 images"); NSApp.terminate(nil); return }
        RecentStore.shared.inMemoryOnly = true

        Task { @MainActor in
            func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
            let captures = images.map { Capture(image: $0.0, scale: $0.1) }
            for c in captures { RecentStore.shared.add(c) }

            // An agent's card with its own marks.
            let shown = Capture(image: images[0].0, scale: images[0].1)
            shown.author = "Claude"
            shown.label = "warm tint"
            let size = CGSize(width: CGFloat(images[0].0.width) / images[0].1, height: CGFloat(images[0].0.height) / images[0].1)
            let marks: [[String: Any]] = [
                ["type": "box", "x": Double(images[0].0.width) * 0.15, "y": Double(images[0].0.height) * 0.2,
                 "width": Double(images[0].0.width) * 0.3, "height": Double(images[0].0.height) * 0.25, "label": "this card"],
                ["type": "arrow", "points": [[0.8, 0.8], [0.75, 0.6], [0.62, 0.5], [0.5, 0.45]].map {
                    [$0[0] * Double(images[0].0.width), $0[1] * Double(images[0].0.height)] }, "label": "warmer"],
                ["type": "number", "at": [Double(images[0].0.width) * 0.12, Double(images[0].0.height) * 0.17]],
            ]
            var state = EditorDocumentState(annotations: [], cropRect: CGRect(origin: .zero, size: size), outputScale: 1)
            state.annotations = (try? AgentMarks.annotations(marks, mapping: .init(origin: .zero, pointsPerUnit: 1 / images[0].1),
                                                             color: AgentColors.rgba(for: "Claude"), imageSize: size)) ?? []
            shown.apply(state)
            RecentStore.shared.add(shown)

            let stack = RecentStackController.shared
            stack.show()
            await sleep(0.8)
            stack.toggleSelection(captures[0].id)
            stack.toggleSelection(captures[1].id)
            stack.toggleSelection(captures[2].id)
            await sleep(0.5)
            for w in NSApp.windows where w is StackPanel { DebugScenario.snapshot(w, to: out.appendingPathComponent("stack.png")) }

            if let stitched = Collage.stitch(Array(captures.prefix(3))) {
                try? ImageExporter.write(stitched.image, scale: 1, to: out.appendingPathComponent("stitched.png"))
            }
            await sleep(0.6)
            for w in NSApp.windows where w is StackPanel { DebugScenario.snapshot(w, to: out.appendingPathComponent("stack-after-stitch.png")) }
            stack.hide(animated: false)

            // Editor: a curved arrow with a note past its tail, and an agent's question.
            EditorWindowController.open(capture: captures[1], context: EditorContext(
                agentPrompt: EditorAgentPrompt(author: "Claude", text: "Which of these day cards needs more personality?",
                                               color: AgentColors.rgba(for: "Claude"))))
            await sleep(0.8)
            if let editor = EditorWindowController.openEditors.first {
                let m = editor.model
                let s = m.imageSize
                let pts = (0...40).map { i -> CGPoint in
                    let t = CGFloat(i) / 40
                    return CGPoint(x: s.width * (0.75 - 0.4 * t), y: s.height * (0.8 - 0.45 * t) + sin(t * .pi) * s.height * 0.15)
                }
                let arrow = Annotation(kind: .arrow, start: pts[0], end: pts[pts.count - 1], points: pts, color: .defaultRed, lineWidth: 6)
                m.add(arrow)
                let (note, _) = NotePlacement.note("make this pop", beside: arrow, imageSize: s, color: .defaultRed,
                                                   fontSize: 28, style: .background)
                m.add(note)
                let box = Annotation(kind: .rectangle, start: CGPoint(x: s.width * 0.08, y: s.height * 0.1),
                                     end: CGPoint(x: s.width * 0.3, y: s.height * 0.3), color: RGBA.presets[4], lineWidth: 4)
                m.add(box)
                let (boxNote, _) = NotePlacement.note("too tight", beside: box, imageSize: s, color: RGBA.presets[4],
                                                      fontSize: 24, style: .outline)
                m.add(boxNote)
                m.tool = .select
                await sleep(0.6)
                if let w = editor.window { DebugScenario.snapshot(w, to: out.appendingPathComponent("editor-agent.png")) }
                editor.window?.performClose(nil)
            }
            await sleep(0.4)
            let sessions = AgentHandoff.findSessions().map { "\($0.kind.rawValue) pid \($0.pid) in \($0.host.localizedName ?? "?")" }
            try? sessions.joined(separator: "\n").write(to: out.appendingPathComponent("sessions.txt"), atomically: true, encoding: .utf8)
            NSLog("Glimpse stack scenario finished")
            NSApp.terminate(nil)
        }
    }
}
#endif

#if DEBUG
/// DEBUG-only: `GLIMPSE_DEBUG_SCENARIO=send GLIMPSE_DEBUG_IMAGES=a.png` finds agent sessions as Send does, sends the image
/// to the chosen one (once you press ↩ in the message box), prints what happened and quits.
@MainActor
enum SendScenario {
    static func run() {
        guard let path = ProcessInfo.processInfo.environment["GLIMPSE_DEBUG_IMAGES"],
              let (image, scale) = ImageUtil.load(url: URL(fileURLWithPath: path)) else { NSApp.terminate(nil); return }
        for s in AgentHandoff.findSessions() {
            print("session: \(s.kind.rawValue) pid \(s.pid) host \(s.host.localizedName ?? "?") inbox \(s.inbox != nil) busy \(s.inbox?.busy ?? false)")
        }
        print("picked: \(AgentHandoff.currentSession().map { "\($0.kind.rawValue) pid \($0.pid)" } ?? "none")")
        AgentHandoff.send([Capture(image: image, scale: scale)]) {
            print("sent")
            NSApp.terminate(nil)
        }
    }
}
#endif
