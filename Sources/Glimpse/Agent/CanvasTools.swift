import AppKit

/// Agent-side drawing: an agent can show you a screenshot with its own marks (in its own colour), ask you to draw your
/// answer on one and send it back, or offer a few images and ask which you prefer. It can also read the recent
/// screenshots stack.
enum CanvasTools {
    static let defaultTimeout = 600
    static let maxTimeout = 3600

    private static let marksSchema: [String: Any] = [
        "type": "array",
        "description": "Marks to draw, in the agent's colour. Coordinates are pixels of the image, origin top-left (or of an image "
            + "`image_width` pixels wide, if given). Each mark has a `type`: "
            + "\"arrow\" {from:[x,y], to:[x,y]} or {points:[[x,y],…]} for a curved one; \"line\" {from, to}; "
            + "\"box\" / \"ellipse\" {x, y, width, height}; \"text\" {at:[x,y] (top-left), text}; "
            + "\"number\" {at:[x,y] (centre)}, numbered 1, 2, 3… in order; \"pen\" / \"highlight\" {points}; "
            + "\"spotlight\" / \"blur\" {x, y, width, height}. Arrows and boxes take an optional `label`, written beside "
            + "them (past an arrow's tail). Optional on any mark: `color` (\"#RRGGBB\") and `size` (stroke width, or font size for text).",
        "items": ["type": "object"],
    ]

    private static let source: [String: Any] = [
        "path": ["type": "string", "description": "Absolute path of an image file (PNG, JPEG, …)."],
        "screenshot_id": ["type": "string", "description": "Id of a screenshot from list_screenshots, or \"latest\". Your marks go on a copy; the user's original stays as it is."],
        "image_width": ["type": "integer", "description": "Width in pixels of the image your coordinates refer to, when it isn't the full-size one (e.g. a downscaled copy you looked at)."],
    ]

    static var definitions: [[String: Any]] {
        [
            [
                "name": "list_screenshots",
                "description": "Lists the user's recent screenshots (the stack Glimpse shows on a double-tap of right Shift), newest first: "
                    + "id, time, size in pixels, who made it, label and how many marks it has.",
                "inputSchema": ["type": "object", "properties": [
                    "limit": ["type": "integer", "description": "How many (default 10, at most 30)."],
                ]],
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "get_screenshot",
                "description": "Returns one of the user's recent screenshots as they marked it up, with its marks as data (in pixels of the returned image) "
                    + "and the path of a full-resolution file.",
                "inputSchema": ["type": "object", "properties": [
                    "screenshot_id": ["type": "string", "description": "Id from list_screenshots, or \"latest\" (default)."],
                    "max_size": ["type": "integer", "description": "Longest edge of the returned image in pixels (default \(AgentTools.defaultMaxSize)); 0 returns full resolution."],
                ]],
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "show_image",
                "description": "Shows the user an image with your marks drawn on it, as a card in their recent screenshots stack "
                    + "(or opened in the editor). Use it to point at something: \"this button\", \"these two are misaligned\". "
                    + "The user can draw on it and send it back to you. Returns its screenshot id.",
                "inputSchema": ["type": "object", "properties": source.merging([
                    "marks": marksSchema,
                    "label": ["type": "string", "description": "Short caption for the card."],
                    "open": ["type": "string", "enum": ["stack", "editor", "none"], "description": "Where to show it (default stack)."],
                ]) { a, _ in a }],
                "annotations": ["readOnlyHint": false, "destructiveHint": false],
            ],
            [
                "name": "ask_user",
                "description": "Opens an image (with your marks) in Glimpse's editor with your question above it, and waits until the user "
                    + "draws their answer on it and sends it (⌘↩), or closes it. Returns the image as they marked it, plus their marks as data. "
                    + "Good for \"circle the part you mean\" or \"which of these should change?\".",
                "inputSchema": ["type": "object", "properties": source.merging([
                    "question": ["type": "string", "description": "What to ask, in a sentence."],
                    "marks": marksSchema,
                    "timeout_seconds": ["type": "integer", "description": "Give up after this long (default \(defaultTimeout), at most \(maxTimeout))."],
                    "max_size": ["type": "integer", "description": "Longest edge of the returned image (default \(AgentTools.defaultMaxSize))."],
                ]) { a, _ in a }, "required": ["question"]],
                "annotations": ["readOnlyHint": false, "destructiveHint": false],
            ],
            [
                "name": "ask_user_to_choose",
                "description": "Shows two or more images as cards in the user's screenshots stack with your question, and waits until the "
                    + "user picks one (they can draw on it first) and sends it, or dismisses the stack. Returns the chosen option's "
                    + "number and label, and the image if they drew on it. Good for \"which of these three versions do you prefer?\".",
                "inputSchema": ["type": "object", "properties": [
                    "question": ["type": "string", "description": "What to ask, in a sentence."],
                    "options": [
                        "type": "array",
                        "description": "The images to choose from, each {path or screenshot_id, label, marks, image_width}.",
                        "items": ["type": "object"],
                    ],
                    "timeout_seconds": ["type": "integer", "description": "Give up after this long (default \(defaultTimeout), at most \(maxTimeout))."],
                    "max_size": ["type": "integer", "description": "Longest edge of a returned image (default \(AgentTools.defaultMaxSize))."],
                ], "required": ["question", "options"]],
                "annotations": ["readOnlyHint": false, "destructiveHint": false],
            ],
        ]
    }

    private struct Failure: Error { let message: String }

    @MainActor
    static func call(_ name: String, _ args: [String: Any]) async -> [String: Any]? {
        let author = AgentColors.name(forClient: args["_client"] as? String)
        do {
            switch name {
            case "list_screenshots": return listScreenshots(args)
            case "get_screenshot": return try getScreenshot(args)
            case "show_image": return try showImage(args, author: author)
            case "ask_user": return try await askUser(args, author: author)
            case "ask_user_to_choose": return try await askToChoose(args, author: author)
            default: return nil
            }
        } catch let failure as Failure {
            return AgentTools.error(failure.message)
        } catch {
            return AgentTools.error(error.localizedDescription)
        }
    }

    // MARK: Reading the stack

    @MainActor
    private static func listScreenshots(_ args: [String: Any]) -> [String: Any] {
        RecentStore.shared.load()
        let limit = min(max(int(args["limit"]) ?? 10, 1), RecentStore.limit)
        let items: [[String: Any]] = RecentStore.shared.captures.reversed().prefix(limit).map { c in
            var item: [String: Any] = [
                "screenshot_id": c.id.uuidString,
                "time": ISO8601DateFormatter.string(from: c.date, timeZone: .current, formatOptions: [.withInternetDateTime]),
                "width": c.image.width, "height": c.image.height,
                "marks": c.document?.annotations.count ?? 0,
                "by": c.author ?? "user",
            ]
            if let label = c.label { item["label"] = label }
            return item
        }
        return AgentTools.text(json(["screenshots": items]))
    }

    @MainActor
    private static func stored(_ idArg: Any?) throws -> Capture {
        RecentStore.shared.load()
        let id = (idArg as? String) ?? "latest"
        if id == "latest", let last = RecentStore.shared.captures.last { return last }
        guard let uuid = UUID(uuidString: id), let c = RecentStore.shared.capture(id: uuid) else {
            throw Failure(message: "No screenshot with id \(id). Use list_screenshots to see the recent ones.")
        }
        return c
    }

    @MainActor
    private static func getScreenshot(_ args: [String: Any]) throws -> [String: Any] {
        let c = try stored(args["screenshot_id"])
        return try result(for: c, args: args, summary: ["screenshot_id": c.id.uuidString], marksKey: "marks", only: nil)
    }

    // MARK: Showing and asking

    @MainActor
    private static func makeCapture(_ args: [String: Any], author: String) throws -> Capture {
        let capture: Capture
        if let path = args["path"] as? String {
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw Failure(message: "path must be absolute.") }
            guard let (image, scale) = ImageUtil.load(url: URL(fileURLWithPath: expanded)) else {
                throw Failure(message: "Couldn't open an image at \(path).")
            }
            capture = Capture(image: image, scale: scale)
        } else if args["screenshot_id"] != nil {
            let original = try stored(args["screenshot_id"])
            capture = Capture(base: original.baseImage, rendered: original.image, scale: original.scale,
                              document: original.document, id: UUID(), date: Date())
        } else {
            throw Failure(message: "Give a path or a screenshot_id.")
        }
        capture.author = author
        if let label = args["label"] as? String, !label.isEmpty { capture.label = label }

        let marks = args["marks"] as? [[String: Any]] ?? []
        guard marks.count <= 200 else { throw Failure(message: "At most 200 marks.") }
        if !marks.isEmpty {
            let full = CGRect(origin: .zero, size: CGSize(width: CGFloat(capture.baseImage.width) / capture.scale,
                                                          height: CGFloat(capture.baseImage.height) / capture.scale))
            var state = capture.document ?? EditorDocumentState(annotations: [], cropRect: full, outputScale: 1)
            let width = CGFloat(int(args["image_width"]) ?? capture.image.width)
            guard width > 0 else { throw Failure(message: "image_width must be positive.") }
            let mapping = AgentMarks.Mapping(origin: state.cropRect.origin, pointsPerUnit: state.cropRect.width / width)
            do {
                state.annotations += try AgentMarks.annotations(marks, mapping: mapping, color: AgentColors.rgba(for: author),
                                                                imageSize: full.size)
            } catch let error as AgentMarks.Invalid {
                throw Failure(message: error.message)
            }
            capture.apply(state)
        }
        return capture
    }

    @MainActor
    private static func showImage(_ args: [String: Any], author: String) throws -> [String: Any] {
        let capture = try makeCapture(args, author: author)
        RecentStore.shared.add(capture)
        switch args["open"] as? String ?? "stack" {
        case "editor": EditorWindowController.open(capture: capture, context: EditorContext(fromStack: true))
        case "none": break
        default: RecentStackController.shared.show(focus: capture.id)
        }
        return AgentTools.text(json(["screenshot_id": capture.id.uuidString,
                                     "shown": args["open"] as? String ?? "stack",
                                     "note": "The user sees it now. If they draw on it and send it, it arrives in your session as an image."]))
    }

    @MainActor
    private static func askUser(_ args: [String: Any], author: String) async throws -> [String: Any] {
        guard let question = (args["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty else {
            throw Failure(message: "Give a question.")
        }
        let capture = try makeCapture(args, author: author)
        RecentStore.shared.add(capture)
        let agentMarkIDs = Set(capture.document?.annotations.map(\.id) ?? [])
        let color = AgentColors.rgba(for: author)
        let answer = await AgentRequests.shared.wait(author: author, question: question, captures: [capture], isChoice: false,
                                                     timeout: timeout(args)) {
            EditorWindowController.open(capture: capture, context: EditorContext(
                fromStack: false, agentPrompt: EditorAgentPrompt(author: author, text: question, color: color)))
        }
        switch answer {
        case .sent(let c, _):
            return try result(for: c, args: args, summary: ["answered": true, "screenshot_id": c.id.uuidString],
                              marksKey: "user_marks", only: { !agentMarkIDs.contains($0.id) })
        case .closed: return AgentTools.text(json(["answered": false, "reason": "The user closed it without sending."]))
        case .timedOut: return AgentTools.text(json(["answered": false, "reason": "No answer in time."]))
        }
    }

    @MainActor
    private static func askToChoose(_ args: [String: Any], author: String) async throws -> [String: Any] {
        guard let question = (args["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty else {
            throw Failure(message: "Give a question.")
        }
        guard let options = args["options"] as? [[String: Any]], options.count >= 2 else {
            throw Failure(message: "Give at least two options.")
        }
        guard options.count <= 8 else { throw Failure(message: "At most 8 options.") }
        var captures: [Capture] = []
        for (i, option) in options.enumerated() {
            var o = option
            if o["label"] == nil { o["label"] = "Option \(i + 1)" }
            captures.append(try makeCapture(o, author: author))
        }
        for c in captures { RecentStore.shared.add(c) }
        let agentMarkIDs = Set(captures.flatMap { $0.document?.annotations.map(\.id) ?? [] })
        let answer = await AgentRequests.shared.wait(author: author, question: question, captures: captures, isChoice: true,
                                                     timeout: timeout(args)) {
            RecentStackController.shared.show(focus: captures[0].id)
        }
        switch answer {
        case .sent(let c, let index):
            var summary: [String: Any] = ["answered": true, "choice": index + 1, "screenshot_id": c.id.uuidString]
            if let label = c.label { summary["label"] = label }
            let userMarks = (c.document?.annotations ?? []).filter { !agentMarkIDs.contains($0.id) }
            if userMarks.isEmpty { return AgentTools.text(json(summary)) }
            return try result(for: c, args: args, summary: summary, marksKey: "user_marks", only: { !agentMarkIDs.contains($0.id) })
        case .closed: return AgentTools.text(json(["answered": false, "reason": "The user dismissed the choice."]))
        case .timedOut: return AgentTools.text(json(["answered": false, "reason": "No answer in time."]))
        }
    }

    // MARK: Results

    /// The image (scaled to max_size) plus a JSON summary with its marks in the returned image's pixels.
    @MainActor
    private static func result(for c: Capture, args: [String: Any], summary: [String: Any], marksKey: String,
                               only filter: ((Annotation) -> Bool)?) throws -> [String: Any] {
        let full = c.image
        var image = full
        let maxSize = int(args["max_size"]) ?? AgentTools.defaultMaxSize
        let longest = max(image.width, image.height)
        if maxSize > 0, longest > maxSize {
            let f = CGFloat(max(maxSize, 64)) / CGFloat(longest)
            image = ImageUtil.resized(image, toPixelWidth: max(1, Int((CGFloat(image.width) * f).rounded())),
                                      height: max(1, Int((CGFloat(image.height) * f).rounded())))
        }
        let url = try AgentHandoff.writeForSending(c)
        guard let data = ImageExporter.encode(image, scale: 1, format: .png) else { throw Failure(message: "Could not encode the image.") }
        var s = summary
        s["path"] = url.path
        s["image_size"] = ["width": image.width, "height": image.height]
        if let doc = c.document {
            let crop = doc.cropRect
            let mapping = AgentMarks.Mapping(origin: crop.origin, pointsPerUnit: crop.width / CGFloat(image.width))
            let annotations = doc.annotations.filter { filter?($0) ?? true }
            s[marksKey] = AgentMarks.describe(annotations, mapping: mapping)
        } else {
            s[marksKey] = [Any]()
        }
        return ["content": [
            ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"],
            ["type": "text", "text": json(s)],
        ]]
    }

    private static func timeout(_ args: [String: Any]) -> Int {
        min(max(int(args["timeout_seconds"]) ?? defaultTimeout, 5), maxTimeout)
    }

    private static func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Marks <-> annotations

/// Turns an agent's marks into editor annotations, and annotations back into marks.
enum AgentMarks {
    struct Invalid: Error { let message: String }

    /// Agent coordinates (pixels of the image it saw) to editor points: point = origin + unit * pointsPerUnit.
    struct Mapping {
        var origin: CGPoint
        var pointsPerUnit: CGFloat

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * pointsPerUnit, y: origin.y + y * pointsPerUnit)
        }

        func unit(_ p: CGPoint) -> [Double] {
            [Double(((p.x - origin.x) / pointsPerUnit).rounded()), Double(((p.y - origin.y) / pointsPerUnit).rounded())]
        }
    }

    static func annotations(_ marks: [[String: Any]], mapping m: Mapping, color: RGBA, imageSize: CGSize) throws -> [Annotation] {
        var out: [Annotation] = []
        let defaultWidth = max(3, min(8, imageSize.width / 360))
        let defaultFont = max(16, min(32, imageSize.width / 48))

        func number(_ v: Any?) -> CGFloat? {
            if let d = v as? Double { return CGFloat(d) }
            if let i = v as? Int { return CGFloat(i) }
            if let s = v as? String, let d = Double(s) { return CGFloat(d) }
            return nil
        }
        func pair(_ v: Any?) -> CGPoint? {
            guard let a = v as? [Any], a.count == 2, let x = number(a[0]), let y = number(a[1]) else { return nil }
            return m.point(x, y)
        }
        func points(_ v: Any?) -> [CGPoint]? {
            guard let a = v as? [Any] else { return nil }
            let pts = a.compactMap(pair)
            return pts.count == a.count && pts.count >= 2 ? pts : nil
        }
        func rect(_ mark: [String: Any]) -> CGRect? {
            if let x = number(mark["x"]), let y = number(mark["y"]), let w = number(mark["width"]), let h = number(mark["height"]) {
                let o = m.point(x, y)
                return CGRect(x: o.x, y: o.y, width: w * m.pointsPerUnit, height: h * m.pointsPerUnit)
            }
            return nil
        }

        for (i, mark) in marks.enumerated() {
            let type = (mark["type"] as? String ?? "").lowercased()
            let c = (mark["color"] as? String).flatMap(RGBA.init(hex:)) ?? color
            let size = number(mark["size"])
            let width = size ?? defaultWidth
            func bad(_ why: String) -> Invalid { Invalid(message: "Mark \(i + 1) (\(type.isEmpty ? "no type" : type)): \(why)") }

            var anchor: Annotation?
            switch type {
            case "arrow", "line":
                let kind: AnnotationKind = type == "arrow" ? .arrow : .line
                if let pts = points(mark["points"]), kind == .arrow {
                    anchor = Annotation(kind: .arrow, start: pts[0], end: pts[pts.count - 1],
                                        points: pts.count >= 3 ? pts : [], color: c, lineWidth: width)
                } else if let from = pair(mark["from"]), let to = pair(mark["to"]) {
                    anchor = Annotation(kind: kind, start: from, end: to, color: c, lineWidth: width)
                } else {
                    throw bad("needs from and to (or points)")
                }
            case "box", "rectangle", "rect", "ellipse", "circle", "oval":
                guard let r = rect(mark) else { throw bad("needs x, y, width and height") }
                let kind: AnnotationKind = ["ellipse", "circle", "oval"].contains(type) ? .ellipse : .rectangle
                anchor = Annotation(kind: kind, start: r.origin, end: CGPoint(x: r.maxX, y: r.maxY), color: c, lineWidth: width)
            case "spotlight", "blur", "pixelate":
                guard let r = rect(mark) else { throw bad("needs x, y, width and height") }
                let kind: AnnotationKind = type == "spotlight" ? .spotlight : (type == "blur" ? .blur : .pixelate)
                out.append(Annotation(kind: kind, start: r.origin, end: CGPoint(x: r.maxX, y: r.maxY), color: c, lineWidth: width))
            case "text", "note", "label":
                guard let at = pair(mark["at"]) ?? pair(mark["from"]), let text = mark["text"] as? String, !text.isEmpty else {
                    throw bad("needs at and text")
                }
                out.append(Annotation(kind: .text, start: at, end: at, color: c, lineWidth: width, text: text,
                                      fontSize: size ?? defaultFont, textStyle: .background))
            case "number", "counter", "step":
                guard let at = pair(mark["at"]) else { throw bad("needs at") }
                out.append(Annotation(kind: .counter, start: at, end: at, color: c, lineWidth: size ?? defaultWidth))
            case "pen", "freehand", "draw", "highlight", "highlighter":
                guard let pts = points(mark["points"]) else { throw bad("needs points (two or more [x, y])") }
                let kind: AnnotationKind = type.hasPrefix("highlight") ? .highlighter : .pen
                out.append(Annotation(kind: kind, start: pts[0], end: pts[pts.count - 1], points: pts, color: c, lineWidth: width))
            default:
                throw bad("unknown type; use arrow, line, box, ellipse, text, number, pen, highlight, spotlight or blur")
            }
            if let a = anchor {
                out.append(a)
                if let label = mark["label"] as? String, !label.isEmpty {
                    let (note, _) = NotePlacement.note(label, beside: a, imageSize: imageSize, color: c,
                                                       fontSize: defaultFont, style: .background)
                    out.append(note)
                }
            }
        }
        return out
    }

    /// Annotations as marks (the inverse of `annotations`), for telling an agent what the user drew.
    static func describe(_ annotations: [Annotation], mapping m: Mapping) -> [[String: Any]] {
        var counter = 0
        return annotations.compactMap { a in
            var d: [String: Any] = ["color": a.color.hex]
            func box() {
                let r = a.rect
                let o = m.unit(r.origin)
                d["x"] = o[0]; d["y"] = o[1]
                d["width"] = Double((r.width / m.pointsPerUnit).rounded())
                d["height"] = Double((r.height / m.pointsPerUnit).rounded())
            }
            switch a.kind {
            case .arrow where a.isCurvedArrow:
                d["type"] = "arrow"
                d["points"] = stride(from: 0, to: a.points.count, by: max(1, a.points.count / 24)).map { m.unit(a.points[$0]) }
                    + [m.unit(a.points[a.points.count - 1])]
                d["to"] = m.unit(a.end)
            case .arrow, .line:
                d["type"] = a.kind == .arrow ? "arrow" : "line"
                d["from"] = m.unit(a.start)
                d["to"] = m.unit(a.end)
            case .rectangle, .filledRectangle: d["type"] = "box"; box()
            case .ellipse: d["type"] = "ellipse"; box()
            case .spotlight: d["type"] = "spotlight"; box()
            case .blur, .pixelate: d["type"] = "blur"; box()
            case .text:
                d["type"] = "text"
                d["at"] = m.unit(a.start)
                d["text"] = a.text
            case .counter:
                counter += 1
                d["type"] = "number"
                d["at"] = m.unit(a.start)
                d["number"] = counter
            case .pen, .highlighter:
                d["type"] = a.kind == .pen ? "pen" : "highlight"
                d["points"] = stride(from: 0, to: a.points.count, by: max(1, a.points.count / 24)).map { m.unit(a.points[$0]) }
            }
            return d
        }
    }
}

extension RGBA {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: CGFloat((v >> 16) & 0xFF) / 255, g: CGFloat((v >> 8) & 0xFF) / 255, b: CGFloat(v & 0xFF) / 255)
    }

    var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

// MARK: - Who's asking

enum AgentColors {
    /// A friendly name for the MCP client (`clientInfo.name`).
    static func name(forClient client: String?) -> String {
        let c = (client ?? "").lowercased()
        if c.contains("claude") { return "Claude" }
        if c.contains("codex") { return "Codex" }
        if c.contains("cursor") { return "Cursor" }
        if c.contains("gemini") { return "Gemini" }
        if c.isEmpty { return "Agent" }
        return client!.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Agent"
    }

    /// Each agent draws in its own colour, so its marks stand apart from yours.
    static func rgba(for author: String) -> RGBA {
        switch author {
        case "Claude": return RGBA(r: 0.85, g: 0.47, b: 0.34) // terracotta
        case "Codex": return RGBA(r: 0.06, g: 0.64, b: 0.50)
        case "Cursor": return RGBA(r: 0.35, g: 0.45, b: 0.95)
        default: return RGBA(r: 0.62, g: 0.36, b: 0.95)
        }
    }

    static func color(for author: String) -> NSColor { rgba(for: author).nsColor }
}

// MARK: - Waiting for the user

/// Agent questions waiting for the user to send an answer.
@MainActor
final class AgentRequests {
    static let shared = AgentRequests()
    static var lastAnsweredAuthor: String?

    enum Answer {
        case sent(Capture, index: Int)
        case closed
        case timedOut
    }

    struct Request {
        let id = UUID()
        let author: String
        let color: NSColor
        let question: String
        let captureIDs: [UUID]
        let isChoice: Bool
        let resume: (Answer) -> Void
    }

    private(set) var requests: [Request] = []

    /// The open ask_user_to_choose, shown as a banner over the stack.
    var pendingChoice: Request? { requests.last { $0.isChoice } }

    func request(for capture: Capture) -> Request? {
        requests.last { $0.captureIDs.contains(capture.id) }
    }

    func wait(author: String, question: String, captures: [Capture], isChoice: Bool, timeout: Int,
              present: @escaping () -> Void) async -> Answer {
        await withCheckedContinuation { (continuation: CheckedContinuation<Answer, Never>) in
            var done = false
            let request = Request(author: author, color: AgentColors.color(for: author), question: question,
                                  captureIDs: captures.map(\.id), isChoice: isChoice) { answer in
                guard !done else { return }
                done = true
                continuation.resume(returning: answer)
            }
            // A newer choice replaces an older one still showing.
            if isChoice, let old = pendingChoice { finish(old, .closed) }
            requests.append(request)
            present()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                if self.requests.contains(where: { $0.id == request.id }) { self.finish(request, .timedOut) }
            }
        }
    }

    private func finish(_ request: Request, _ answer: Answer) {
        requests.removeAll { $0.id == request.id }
        request.resume(answer)
        if request.isChoice { RecentStackController.shared.requestsChanged() }
    }

    /// Send on a screenshot an agent is waiting for: answers it. False when nobody is waiting for this one.
    func answer(with capture: Capture) -> Bool {
        guard let request = request(for: capture), let index = request.captureIDs.firstIndex(of: capture.id) else { return false }
        Self.lastAnsweredAuthor = request.author
        finish(request, .sent(capture, index: index))
        return true
    }

    /// The editor for an ask_user closed without sending.
    func closedWithoutSending(_ capture: Capture) {
        for r in requests where !r.isChoice && r.captureIDs.contains(capture.id) { finish(r, .closed) }
    }

    /// The stack was dismissed while it showed a choice.
    func dismissChoice() {
        if let choice = pendingChoice { finish(choice, .closed) }
    }
}
