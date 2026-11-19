import AppKit
import Carbon.HIToolbox
import Combine

/// The recent screenshots as a column of cards at the edge of the screen, newest at the bottom. It opens without
/// taking focus from the app you're in; close it (Esc, or double-tap right Shift again) and you're where you were.
///
/// Click a card to draw on it. ⌘-click or ⇧-click (or Space) selects several, then: Copy ⌘C, Draw ↩ (one after
/// another), Stitch ⌘S, Send ⌘↩, Remove ⌘⌫. Drag cards into any app.
@MainActor
final class RecentStackController: NSObject, NSWindowDelegate {
    static let shared = RecentStackController()

    private var panel: StackPanel?
    private var content: StackContentView?
    private var storeObserver: AnyCancellable?
    private var hiding = false

    /// Selected cards in the order they were picked (that's their number in Stitch).
    private(set) var selection: [UUID] = []
    private(set) var focusedID: UUID?
    /// The app that was in front before the editor opened from the stack, to go back to afterwards.
    private var previousApp: NSRunningApplication?
    /// While true (a drag, a menu) the stack stays open when it loses focus.
    var holdOpen = false

    var isVisible: Bool { panel?.isVisible == true && !hiding }

    var captures: [Capture] { RecentStore.shared.captures }

    func toggle() { isVisible ? dismiss() : show() }

    /// Closing on purpose (Esc, the shortcut): also turns down an agent's open question.
    func dismiss() {
        AgentRequests.shared.dismissChoice()
        hide()
    }

    /// An agent's question appeared or was answered.
    func requestsChanged() {
        guard isVisible else { return }
        content?.reload()
        if let panel, let screen = panel.screen { panel.setFrame(frame(on: screen), display: true, animate: false) }
    }

    func show(focus: UUID? = nil) {
        RecentStore.shared.load()
        guard !captures.isEmpty else {
            HUD.show("No recent screenshots yet", symbol: "square.stack")
            return
        }
        observeStore()
        selection = selection.filter { id in captures.contains { $0.id == id } }
        if let focus, captures.contains(where: { $0.id == focus }) {
            focusedID = focus
        } else if focusedID == nil || !captures.contains(where: { $0.id == focusedID }) || !isVisible {
            focusedID = captures.last?.id
        }
        let screen = (panel?.isVisible == true ? panel?.screen : nil) ?? NSScreen.withMouse
        let panel = self.panel ?? makePanel()
        hiding = false
        content?.reload()
        let target = frame(on: screen)
        if !panel.isVisible || panel.alphaValue < 1 {
            var start = target
            start.origin.x = screen.visibleFrame.maxX + 8
            if !panel.isVisible { panel.setFrame(start, display: false) }
            panel.orderFrontRegardless()
            panel.makeKey()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.setFrame(target, display: true, animate: false)
            panel.makeKey()
        }
        content?.scrollToFocus(animated: false)
    }

    func hide(animated: Bool = true) {
        guard let panel, panel.isVisible, !hiding else { return }
        hiding = true
        guard animated, let screen = panel.screen else {
            panel.orderOut(nil)
            hiding = false
            return
        }
        var end = panel.frame
        end.origin.x = screen.visibleFrame.maxX + 8
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.9, 0.6)
            panel.animator().setFrame(end, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                // A show() during the animation wins.
                guard self.hiding else { return }
                panel.orderOut(nil)
                self.hiding = false
            }
        })
    }

    private func observeStore() {
        guard storeObserver == nil else { return }
        storeObserver = RecentStore.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.storeChanged() }
            }
    }

    private func storeChanged() {
        let ids = Set(captures.map(\.id))
        selection.removeAll { !ids.contains($0) }
        if let f = focusedID, !ids.contains(f) { focusedID = captures.last?.id }
        guard isVisible else { return }
        if captures.isEmpty { hide(); return }
        content?.reload()
        if let panel, let screen = panel.screen { panel.setFrame(frame(on: screen), display: true, animate: false) }
    }

    // MARK: Panel

    static let cardWidth: CGFloat = 236
    static let padding: CGFloat = 14
    static let barHeight: CGFloat = 52

    private func makePanel() -> StackPanel {
        let panel = StackPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.delegate = self
        let content = StackContentView(controller: self)
        panel.contentView = content
        panel.keyHandler = { [weak content] event in content?.handleKey(event) ?? false }
        self.panel = panel
        self.content = content
        return panel
    }

    private func frame(on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let width = Self.cardWidth + Self.padding * 2
        let wanted = (content?.preferredHeight ?? 400)
        let height = min(wanted, vf.height - 24)
        return NSRect(x: vf.maxX - width - 6, y: vf.minY + 12, width: width, height: height)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking into another app closes the stack, unless something of ours is still going on.
        DispatchQueue.main.async { [self] in
            guard isVisible, !holdOpen, panel?.isKeyWindow == false,
                  AgentRequests.shared.pendingChoice == nil else { return }
            hide()
        }
    }

    // MARK: Selection

    func focus(_ id: UUID) {
        focusedID = id
        content?.refreshCards()
        content?.scrollToFocus(animated: true)
    }

    func toggleSelection(_ id: UUID) {
        if let i = selection.firstIndex(of: id) { selection.remove(at: i) } else { selection.append(id) }
        focusedID = id
        content?.refreshCards()
    }

    /// ⇧-click / ⇧-arrow: selects everything between the focused card and `id`.
    func extendSelection(to id: UUID) {
        let ids = captures.map(\.id)
        guard let from = focusedID.flatMap({ ids.firstIndex(of: $0) }), let to = ids.firstIndex(of: id) else {
            return toggleSelection(id)
        }
        if !selection.contains(ids[from]) { selection.append(ids[from]) }
        let range = from < to ? Array(ids[from...to]) : Array(ids[to...from].reversed())
        for r in range where !selection.contains(r) { selection.append(r) }
        focusedID = id
        content?.refreshCards()
        content?.scrollToFocus(animated: true)
    }

    func selectAll() {
        selection = captures.map(\.id)
        content?.refreshCards()
    }

    func clearSelection() {
        selection = []
        content?.refreshCards()
    }

    /// What the actions work on: the selection in picking order, else the focused card.
    var targets: [Capture] {
        let picked = selection.compactMap { id in captures.first { $0.id == id } }
        if !picked.isEmpty { return picked }
        return focusedID.flatMap { id in captures.first { $0.id == id } }.map { [$0] } ?? []
    }

    /// Cards a drag that starts on `capture` carries.
    func dragTargets(startingAt capture: Capture) -> [Capture] {
        selection.contains(capture.id) ? targets : [capture]
    }

    // MARK: Actions

    func copyTargets() {
        let items = targets
        guard !items.isEmpty else { return }
        if items.count == 1 {
            Clipboard.copy(items[0].image, scale: items[0].scale)
        } else {
            Clipboard.copy(images: items.map { ($0.image, $0.scale) })
        }
        content?.flash(items.map(\.id), text: "Copied")
        HUD.show(items.count == 1 ? "Copied to clipboard" : "Copied \(items.count) screenshots", symbol: "doc.on.doc.fill")
    }

    /// Opens the editor on the targets, one after another (Copy or Send in the editor moves to the next).
    func draw() {
        let items = targets
        guard let first = items.first else { return }
        rememberPreviousApp()
        hide(animated: false)
        EditorWindowController.open(capture: first, context: EditorContext(fromStack: true, queue: Array(items.dropFirst()),
                                                                          batchIndex: items.count > 1 ? 1 : nil,
                                                                          batchCount: items.count))
    }

    func open(_ capture: Capture) {
        focusedID = capture.id
        rememberPreviousApp()
        hide(animated: false)
        EditorWindowController.open(capture: capture, context: EditorContext(fromStack: true))
    }

    func stitch() {
        let items = targets
        guard let stitched = Collage.stitch(items) else { return }
        selection = []
        focusedID = stitched.id
        content?.reload()
        content?.scrollToFocus(animated: true)
    }

    func send() {
        let items = targets
        guard !items.isEmpty else { return }
        // With several sessions running, the stack stays up while you pick one (and if you close the menu instead).
        // The menu is over by the time send returns; the choice lands just after.
        holdOpen = true
        AgentHandoff.send(items, close: { [weak self] in
            self?.holdOpen = false
            self?.hide(animated: true)
            self?.selection = []
        })
        DispatchQueue.main.async { [weak self] in self?.holdOpen = false }
    }

    func remove() {
        let items = targets
        guard !items.isEmpty else { return }
        let ids = Set(items.map(\.id))
        // Focus the card that takes the place of the first removed one.
        let all = captures.map(\.id)
        let firstIndex = all.firstIndex { ids.contains($0) } ?? 0
        let remaining = all.filter { !ids.contains($0) }
        focusedID = remaining.isEmpty ? nil : remaining[min(firstIndex, remaining.count - 1)]
        selection = []
        RecentStore.shared.remove(ids)
    }

    /// Every card except ones an agent is waiting for you to choose from, once you confirm: their files are deleted.
    var removableAll: Set<UUID> {
        Set(captures.map(\.id)).subtracting(AgentRequests.shared.pendingChoice?.captureIDs ?? [])
    }

    /// Empties the stack (keeping cards an agent is waiting on), after asking: it can't be undone.
    func removeAll() {
        let ids = removableAll
        guard !ids.isEmpty else { return }
        // The alert takes the keyboard from the stack's panel, which would otherwise close.
        holdOpen = true
        defer { DispatchQueue.main.async { [weak self] in self?.holdOpen = false } }
        let alert = NSAlert()
        alert.messageText = ids.count == 1 ? "Remove the screenshot from Recent?" : "Remove all \(ids.count) screenshots from Recent?"
        alert.informativeText = "They're deleted from Glimpse and can't be brought back. Copies you saved or pasted elsewhere stay."
        let remove = alert.addButton(withTitle: ids.count == 1 ? "Remove" : "Remove All")
        remove.hasDestructiveAction = true
        // Nothing to undo: ↩ doesn't confirm, a click does (Esc cancels).
        remove.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel")
        // The stack's panel doesn't activate Glimpse: the app you were in is still in front, and gets it back after.
        let previous = NSWorkspace.shared.frontmostApplication.flatMap { $0 == NSRunningApplication.current ? nil : $0 }
        NSApp.activate(ignoringOtherApps: true)
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if confirmed {
            selection = []
            focusedID = captures.first { !ids.contains($0.id) }?.id
            RecentStore.shared.remove(ids)
        }
        // Emptied, the stack hides itself. Still up (cancelled, or cards an agent is waiting on remain): keep using
        // it from the keyboard.
        if captures.isEmpty {
            previous?.activate()
        } else {
            panel?.makeKey()
        }
    }

    func pin() {
        for c in targets { PinWindowController.pin(capture: c) }
    }

    func save() {
        var last: URL?
        for c in targets { last = try? c.saveToDefaultLocation() }
        if let last { HUD.show("Saved to \(last.deletingLastPathComponent().lastPathComponent)", symbol: "square.and.arrow.down.fill") }
    }

    func reveal() {
        let urls = targets.compactMap(\.savedURL)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    // MARK: Editor round trip

    private func rememberPreviousApp() {
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
    }

    /// The editor opened from the stack closed without sending: go back to the app and the stack.
    func editorDidClose(_ capture: Capture) {
        if let app = previousApp, !app.isTerminated { app.activate() }
        previousApp = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            self.show(focus: capture.id)
        }
    }

    func forgetPreviousApp() { previousApp = nil }
}

/// The stack's window. Gets keys without activating Glimpse.
final class StackPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { RecentStackController.shared.dismiss() }
    }
}

// MARK: - Content

/// Optional banner (an agent's question), the scrolling cards, and the action bar.
final class StackContentView: NSView {
    private unowned let controller: RecentStackController
    private let scrollView = NSScrollView()
    private let cardsView = FlippedView()
    private let bar = StackActionBar()
    private let banner = StackBanner()
    private var cards: [UUID: StackCardView] = [:]

    private let spacing: CGFloat = 10

    @MainActor
    init(controller: RecentStackController) {
        self.controller = controller
        super.init(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.documentView = cardsView
        scrollView.contentView.drawsBackground = false
        addSubview(scrollView)
        addSubview(bar)
        addSubview(banner)
        bar.onAction = { action in
            let c = RecentStackController.shared
            switch action {
            case .copy: c.copyTargets()
            case .draw: c.draw()
            case .stitch: c.stitch()
            case .send: c.send()
            case .remove: c.remove()
            case .removeAll: c.removeAll()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    private var cardWidth: CGFloat { RecentStackController.cardWidth }
    private var pad: CGFloat { RecentStackController.padding }

    @MainActor
    var preferredHeight: CGFloat {
        let cardsHeight = controller.captures.reduce(0) { $0 + StackCardView.height(for: $1, width: cardWidth) + spacing }
        return cardsHeight + RecentStackController.barHeight + pad + bannerHeight + 8
    }

    @MainActor
    private var bannerHeight: CGFloat {
        AgentRequests.shared.pendingChoice == nil ? 0 : banner.height(forWidth: cardWidth) + spacing
    }

    @MainActor
    func reload() {
        let captures = controller.captures
        let ids = Set(captures.map(\.id))
        for (id, card) in cards where !ids.contains(id) {
            card.removeFromSuperview()
            cards[id] = nil
        }
        for c in captures where cards[c.id] == nil {
            let card = StackCardView(capture: c)
            cards[c.id] = card
            cardsView.addSubview(card)
        }
        if let choice = AgentRequests.shared.pendingChoice {
            banner.set(author: choice.author, text: choice.question, color: choice.color)
            banner.isHidden = false
        } else {
            banner.isHidden = true
        }
        refreshCards()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    @MainActor
    func refreshCards() {
        let selection = controller.selection
        let choiceIDs = AgentRequests.shared.pendingChoice?.captureIDs ?? []
        for c in controller.captures {
            guard let card = cards[c.id] else { continue }
            card.thumbnail = RecentStore.shared.thumbnails[c.id]
            card.selectionNumber = selection.firstIndex(of: c.id).map { $0 + 1 }
            card.isFocused = controller.focusedID == c.id
            card.isChoice = choiceIDs.contains(c.id)
            card.refresh()
        }
        bar.update(selected: selection.count, hasFocus: controller.focusedID != nil,
                   sendTitle: AgentHandoff.sendTitle(for: controller.targets), removableAll: controller.removableAll.count)
    }

    @MainActor
    override func layout() {
        super.layout()
        let b = bounds
        bar.frame = NSRect(x: pad, y: 0, width: cardWidth, height: RecentStackController.barHeight)
        var top = b.height
        if !banner.isHidden {
            let h = banner.height(forWidth: cardWidth)
            banner.frame = NSRect(x: pad, y: top - h - 4, width: cardWidth, height: h)
            top -= h + spacing + 4
        }
        let scrollBottom = RecentStackController.barHeight + 8
        scrollView.frame = NSRect(x: 0, y: scrollBottom, width: b.width, height: max(0, top - scrollBottom))

        let captures = controller.captures
        let total = captures.reduce(0) { $0 + StackCardView.height(for: $1, width: cardWidth) + spacing }
        let docHeight = max(total, scrollView.frame.height)
        cardsView.frame = NSRect(x: 0, y: 0, width: b.width, height: docHeight)
        // Newest at the bottom: start from the bottom edge of the document.
        var y = docHeight - total
        for c in captures {
            let h = StackCardView.height(for: c, width: cardWidth)
            cards[c.id]?.frame = NSRect(x: pad, y: y, width: cardWidth, height: h)
            y += h + spacing
        }
    }

    @MainActor
    func scrollToFocus(animated: Bool) {
        layoutSubtreeIfNeeded()
        guard let id = controller.focusedID, let card = cards[id] else { return }
        let visible = scrollView.contentView.bounds
        let f = card.frame.insetBy(dx: 0, dy: -8)
        guard !visible.contains(f) else { return }
        var origin = visible.origin
        origin.y = f.maxY > visible.maxY ? f.maxY - visible.height : f.minY
        origin.y = max(0, min(origin.y, cardsView.frame.height - visible.height))
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                scrollView.contentView.animator().setBoundsOrigin(origin)
            }
        } else {
            scrollView.contentView.setBoundsOrigin(origin)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @MainActor
    func flash(_ ids: [UUID], text: String) {
        for id in ids { cards[id]?.flash(text) }
    }

    // MARK: Keys

    @MainActor
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let c = controller
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = Int(event.keyCode)
        let ids = c.captures.map(\.id)
        let index = c.focusedID.flatMap { ids.firstIndex(of: $0) }

        switch (code, mods) {
        case (kVK_Escape, _):
            if !c.selection.isEmpty { c.clearSelection() } else { c.dismiss() }
        case (kVK_UpArrow, []), (kVK_UpArrow, .shift):
            guard let i = index, i > 0 else { return true }
            mods == .shift ? c.extendSelection(to: ids[i - 1]) : c.focus(ids[i - 1])
        case (kVK_DownArrow, []), (kVK_DownArrow, .shift):
            guard let i = index, i < ids.count - 1 else { return true }
            mods == .shift ? c.extendSelection(to: ids[i + 1]) : c.focus(ids[i + 1])
        case (kVK_Space, []):
            if let id = c.focusedID { c.toggleSelection(id) }
        case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []):
            c.draw()
        case (kVK_Return, .command), (kVK_ANSI_KeypadEnter, .command):
            c.send()
        case (kVK_ANSI_C, .command):
            c.copyTargets()
        case (kVK_ANSI_S, .command):
            c.stitch()
        case (kVK_ANSI_A, .command):
            c.selectAll()
        case (kVK_Delete, .command), (kVK_ForwardDelete, []), (kVK_Delete, []):
            c.remove()
        case (kVK_Delete, [.command, .shift]):
            c.removeAll()
        case (kVK_ANSI_P, .command):
            c.pin()
        case (kVK_ANSI_W, .command):
            c.dismiss()
        default:
            return false
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if !MainActor.assumeIsolated({ handleKey(event) }) { super.keyDown(with: event) }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Card

final class StackCardView: NSView, NSDraggingSource {
    let capture: Capture
    var thumbnail: CGImage?
    var selectionNumber: Int?
    var isFocused = false
    var isChoice = false

    private let imageLayer = CALayer()
    private let ringLayer = CALayer()
    private let badge = NSTextField(labelWithString: "")
    private let caption = PillLabel()
    private let checkCircle = NSImageView()
    private let flashLabel = PillLabel()
    private var isHovered = false
    private var downEvent: NSEvent?
    private var dragged = false

    @MainActor
    static func height(for capture: Capture, width: CGFloat) -> CGFloat {
        let s = capture.pointSize
        let aspect = s.height / max(s.width, 1)
        return min(max(width * aspect, width * 0.42), width * 1.3).rounded()
    }

    @MainActor
    init(capture: Capture) {
        self.capture = capture
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        imageLayer.contentsGravity = .resizeAspect
        imageLayer.cornerRadius = 11
        imageLayer.masksToBounds = true
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)

        ringLayer.cornerRadius = 11
        ringLayer.borderWidth = 0.5
        ringLayer.borderColor = NSColor(white: 1, alpha: 0.22).cgColor
        layer?.addSublayer(ringLayer)

        badge.font = .systemFont(ofSize: 12, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        badge.layer?.cornerRadius = 11
        badge.isHidden = true
        addSubview(badge)

        checkCircle.image = NSImage(systemSymbolName: "circle", accessibilityDescription: "Select")?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
        checkCircle.contentTintColor = .white
        checkCircle.shadow = {
            let s = NSShadow(); s.shadowBlurRadius = 3; s.shadowColor = NSColor(white: 0, alpha: 0.6); return s
        }()
        checkCircle.alphaValue = 0
        addSubview(checkCircle)

        addSubview(caption)
        flashLabel.alphaValue = 0
        addSubview(flashLabel)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        toolTip = Self.dateFormatter.string(from: capture.date)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    @MainActor
    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = thumbnail ?? capture.image
        CATransaction.commit()

        let accent = NSColor.controlAccentColor.cgColor
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        if selectionNumber != nil {
            ringLayer.borderWidth = 3
            ringLayer.borderColor = accent
        } else if isFocused {
            ringLayer.borderWidth = 2
            ringLayer.borderColor = NSColor(white: 1, alpha: 0.9).cgColor
        } else if isChoice {
            ringLayer.borderWidth = 2
            ringLayer.borderColor = (AgentRequests.shared.pendingChoice?.color.cgColor) ?? accent
        } else {
            ringLayer.borderWidth = 0.5
            ringLayer.borderColor = NSColor(white: 1, alpha: 0.22).cgColor
        }
        CATransaction.commit()

        if let n = selectionNumber {
            badge.stringValue = "\(n)"
            badge.isHidden = false
        } else {
            badge.isHidden = true
        }
        checkCircle.alphaValue = (isHovered && selectionNumber == nil) ? 1 : 0

        if let author = capture.author {
            caption.set(text: capture.label.map { "\(author) · \($0)" } ?? "From \(author)",
                        dot: AgentColors.color(for: author))
            caption.isHidden = false
        } else if let label = capture.label {
            caption.set(text: label, dot: nil)
            caption.isHidden = false
        } else {
            caption.isHidden = true
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        ringLayer.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 11, cornerHeight: 11, transform: nil)
        CATransaction.commit()
        badge.frame = NSRect(x: bounds.maxX - 30, y: bounds.maxY - 30, width: 22, height: 22)
        // Vertically centre the number in its circle.
        badge.cell?.title = badge.stringValue
        checkCircle.frame = NSRect(x: 8, y: bounds.maxY - 30, width: 22, height: 22)
        let cs = caption.fittingSize
        caption.frame = NSRect(x: 8, y: 8, width: min(cs.width, bounds.width - 16), height: cs.height)
        let fs = flashLabel.fittingSize
        flashLabel.frame = NSRect(x: bounds.midX - fs.width / 2, y: bounds.midY - fs.height / 2, width: fs.width, height: fs.height)
    }

    @MainActor
    func flash(_ text: String) {
        flashLabel.set(text: text, dot: nil)
        needsLayout = true
        layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            flashLabel.animator().alphaValue = 1
        }, completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    self.flashLabel.animator().alphaValue = 0
                }
            }
        })
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            checkCircle.animator().alphaValue = selectionNumber == nil ? 1 : 0
        }
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            checkCircle.animator().alphaValue = 0
        }
        NSCursor.arrow.set()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, !dragged else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 4 else { return }
        dragged = true
        MainActor.assumeIsolated { beginDrag(event) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { downEvent = nil }
        guard downEvent != nil, !dragged else { return }
        MainActor.assumeIsolated {
            let c = RecentStackController.shared
            let p = convert(event.locationInWindow, from: nil)
            if event.modifierFlags.contains(.command) || checkCircle.frame.insetBy(dx: -4, dy: -4).contains(p) || badge.frame.contains(p) {
                c.toggleSelection(capture.id)
            } else if event.modifierFlags.contains(.shift) {
                c.extendSelection(to: capture.id)
            } else {
                c.open(capture)
            }
        }
    }

    @MainActor
    private func beginDrag(_ event: NSEvent) {
        let c = RecentStackController.shared
        let items = c.dragTargets(startingAt: capture)
        var dragItems: [NSDraggingItem] = []
        for (i, item) in items.enumerated() {
            guard let url = item.fileForDragging() else { continue }
            let d = NSDraggingItem(pasteboardWriter: url as NSURL)
            let preview = NSImage(cgImage: RecentStore.shared.thumbnails[item.id] ?? item.image, size: bounds.size)
            d.setDraggingFrame(bounds.offsetBy(dx: CGFloat(i) * 6, dy: CGFloat(-i) * 6), contents: preview)
            dragItems.append(d)
        }
        guard !dragItems.isEmpty else { return }
        c.holdOpen = true
        let session = beginDraggingSession(with: dragItems, event: event, source: self)
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated {
            RecentStackController.shared.holdOpen = false
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        do {
            let c = RecentStackController.shared
            if !c.selection.contains(capture.id) { c.focus(capture.id) }
            let menu = NSMenu()
            func add(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = [], _ action: @escaping @MainActor () -> Void) {
                let item = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
                item.keyEquivalentModifierMask = mods
                menu.addItem(item)
            }
            let n = c.targets.count
            add(n > 1 ? "Copy \(n)" : "Copy", "c", .command) { c.copyTargets() }
            add(n > 1 ? "Draw on \(n), One by One" : "Draw", "\r", []) { c.draw() }
            if n > 1 { add("Stitch \(n)", "s", .command) { c.stitch() } }
            add(AgentHandoff.sendTitle(for: c.targets), "\r", .command) { c.send() }
            menu.addItem(.separator())
            add("Pin to Screen") { c.pin() }
            add("Save") { c.save() }
            if c.targets.contains(where: { $0.savedURL != nil }) { add("Show in Finder") { c.reveal() } }
            menu.addItem(.separator())
            add(n > 1 ? "Remove \(n) from Recent" : "Remove from Recent", "\u{8}", .command) { c.remove() }
            // Only when it would remove more than "Remove" above does.
            if c.removableAll.count > 1, !c.removableAll.subtracting(c.targets.map(\.id)).isEmpty {
                add("Remove All from Recent…", "\u{8}", [.command, .shift]) { c.removeAll() }
            }
            c.holdOpen = true
            DispatchQueue.main.async { c.holdOpen = false }
            return menu
        }
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, keyEquivalent: String = "", action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { MainActor.assumeIsolated { handler() } }
}

/// Small dark rounded label, optionally with a coloured dot.
final class PillLabel: NSView {
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.82).cgColor
        layer?.cornerRadius = 9
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        addSubview(dot)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(text: String, dot color: NSColor?) {
        label.stringValue = text
        dot.isHidden = color == nil
        dot.layer?.backgroundColor = color?.cgColor
        needsLayout = true
    }

    override var fittingSize: NSSize {
        let s = label.fittingSize
        return NSSize(width: s.width + 16 + (dot.isHidden ? 0 : 11), height: 18)
    }

    override func layout() {
        super.layout()
        let s = label.fittingSize
        var x: CGFloat = 8
        if !dot.isHidden {
            dot.frame = NSRect(x: 8, y: (bounds.height - 7) / 2, width: 7, height: 7)
            x += 11
        }
        label.frame = NSRect(x: x, y: (bounds.height - s.height) / 2, width: bounds.width - x - 8, height: s.height)
    }
}

// MARK: - Banner (an agent's question)

final class StackBanner: NSView {
    private let title = NSTextField(labelWithString: "")
    private let text = NSTextField(wrappingLabelWithString: "")
    private let dot = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = NSColor(white: 1, alpha: 0.7)
        text.font = .systemFont(ofSize: 13, weight: .medium)
        text.textColor = .white
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        [title, text, dot].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(author: String, text value: String, color: NSColor) {
        title.stringValue = "\(author) asks · pick one, draw on it, ⌘↩ to send"
        text.stringValue = value
        dot.layer?.backgroundColor = color.cgColor
        needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        text.preferredMaxLayoutWidth = width - 24
        return 12 + 15 + 4 + text.fittingSize.height + 12
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        text.preferredMaxLayoutWidth = w - 24
        let th = text.fittingSize.height
        dot.frame = NSRect(x: 12, y: bounds.height - 12 - 11, width: 8, height: 8)
        title.frame = NSRect(x: 25, y: bounds.height - 12 - 15, width: w - 37, height: 15)
        text.frame = NSRect(x: 12, y: 12, width: w - 24, height: th)
    }
}

// MARK: - Action bar

final class StackActionBar: NSView {
    enum Action: CaseIterable { case copy, draw, stitch, send, remove, removeAll }

    var onAction: ((Action) -> Void)?
    private var buttons: [Action: StackBarButton] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 10
        let specs: [(Action, String, String, String)] = [
            (.copy, "doc.on.doc", "Copy", "⌘C"),
            (.draw, "pencil.tip", "Draw", "↩"),
            (.stitch, "square.grid.2x2", "Stitch", "⌘S"),
            (.send, "paperplane", "Send", "⌘↩"),
            (.remove, "trash", "Remove", "⌘⌫"),
            (.removeAll, "xmark.bin", "Remove All", "⌘⇧⌫"),
        ]
        for (action, symbol, title, key) in specs {
            let b = StackBarButton(symbol: symbol, shortcut: key)
            b.toolTip = "\(title) (\(key))"
            b.onClick = { [weak self] in self?.onAction?(action) }
            buttons[action] = b
            addSubview(b)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(selected: Int, hasFocus: Bool, sendTitle: String, removableAll: Int) {
        buttons[.stitch]?.isEnabled = selected >= 2
        buttons[.removeAll]?.isEnabled = removableAll > 0
        buttons[.removeAll]?.toolTip = removableAll > 0 ? "Remove all \(removableAll) from Recent… (⌘⇧⌫)" : "Remove All (⌘⇧⌫)"
        for a in [Action.copy, .draw, .send, .remove] { buttons[a]?.isEnabled = hasFocus || selected > 0 }
        buttons[.send]?.toolTip = "\(sendTitle) (⌘↩)"
        buttons[.draw]?.toolTip = selected > 1 ? "Draw on \(selected), one after another (↩)" : "Draw (↩)"
    }

    override func layout() {
        super.layout()
        let order = Action.allCases
        let w = (bounds.width - 8) / CGFloat(order.count)
        for (i, a) in order.enumerated() {
            buttons[a]?.frame = NSRect(x: 4 + CGFloat(i) * w, y: 4, width: w, height: bounds.height - 8)
        }
    }
}

final class StackBarButton: NSView {
    var onClick: (() -> Void)?
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.35 } }
    private let icon = NSImageView()
    private let key = NSTextField(labelWithString: "")
    private var hovering = false

    init(symbol: String, shortcut: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        icon.contentTintColor = .white
        key.stringValue = shortcut
        key.font = .systemFont(ofSize: 10, weight: .medium)
        key.textColor = NSColor(white: 1, alpha: 0.55)
        key.alignment = .center
        addSubview(icon)
        addSubview(key)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 0, y: bounds.height - 24, width: bounds.width, height: 18)
        key.frame = NSRect(x: 0, y: 3, width: bounds.width, height: 13)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        layer?.backgroundColor = isEnabled ? NSColor(white: 1, alpha: 0.12).cgColor : nil
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        layer?.backgroundColor = nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.22).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = hovering && isEnabled ? NSColor(white: 1, alpha: 0.12).cgColor : nil
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
}
