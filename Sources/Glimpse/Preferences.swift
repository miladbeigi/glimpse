import AppKit
import Combine

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg
    var id: String { rawValue }
    var fileExtension: String { self == .png ? "png" : "jpg" }
    var title: String { self == .png ? "PNG" : "JPEG" }
}

enum OverlayCorner: String, CaseIterable, Identifiable {
    case bottomRight, bottomLeft, topRight, topLeft
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bottomRight: return "Bottom Right"
        case .bottomLeft: return "Bottom Left"
        case .topRight: return "Top Right"
        case .topLeft: return "Top Left"
        }
    }
    var isLeft: Bool { self == .bottomLeft || self == .topLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }
}

enum OverlaySize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var width: CGFloat {
        switch self {
        case .small: return 180
        case .medium: return 230
        case .large: return 300
        }
    }
}

/// UserDefaults-backed settings. Every property writes through on change.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    @Published var saveDirectory: URL { didSet { defaults.set(saveDirectory.path, forKey: Keys.saveDirectory) } }
    @Published var imageFormat: ImageFormat { didSet { defaults.set(imageFormat.rawValue, forKey: Keys.imageFormat) } }
    @Published var jpegQuality: Double { didSet { defaults.set(jpegQuality, forKey: Keys.jpegQuality) } }
    @Published var saveAt1x: Bool { didSet { defaults.set(saveAt1x, forKey: Keys.saveAt1x) } }

    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: Keys.playSound) } }
    @Published var copyToClipboard: Bool { didSet { defaults.set(copyToClipboard, forKey: Keys.copyToClipboard) } }
    @Published var autoSave: Bool { didSet { defaults.set(autoSave, forKey: Keys.autoSave) } }
    @Published var showOverlay: Bool { didSet { defaults.set(showOverlay, forKey: Keys.showOverlay) } }
    @Published var openEditorAfterCapture: Bool { didSet { defaults.set(openEditorAfterCapture, forKey: Keys.openEditor) } }

    @Published var overlayCorner: OverlayCorner { didSet { defaults.set(overlayCorner.rawValue, forKey: Keys.overlayCorner) } }
    @Published var overlaySize: OverlaySize { didSet { defaults.set(overlaySize.rawValue, forKey: Keys.overlaySize) } }
    /// 0 = never auto-close.
    @Published var overlayAutoClose: Int { didSet { defaults.set(overlayAutoClose, forKey: Keys.overlayAutoClose) } }
    @Published var closeOverlayAfterDrag: Bool { didSet { defaults.set(closeOverlayAfterDrag, forKey: Keys.closeAfterDrag) } }

    @Published var showCrosshair: Bool { didSet { defaults.set(showCrosshair, forKey: Keys.showCrosshair) } }
    @Published var showMagnifier: Bool { didSet { defaults.set(showMagnifier, forKey: Keys.showMagnifier) } }
    @Published var windowShadow: Bool { didSet { defaults.set(windowShadow, forKey: Keys.windowShadow) } }
    @Published var selfTimerSeconds: Int { didSet { defaults.set(selfTimerSeconds, forKey: Keys.selfTimer) } }
    /// Lets connected MCP clients (`Glimpse mcp`) take screenshots. Off until the user opts in.
    @Published var agentAccess: Bool { didSet { defaults.set(agentAccess, forKey: Keys.agentAccess) } }

    @Published private(set) var shortcuts: [HotkeyAction: KeyCombo]

    private enum Keys {
        static let saveDirectory = "saveDirectory"
        static let imageFormat = "imageFormat"
        static let jpegQuality = "jpegQuality"
        static let saveAt1x = "saveAt1x"
        static let playSound = "playSound"
        static let copyToClipboard = "copyToClipboard"
        static let autoSave = "autoSave"
        static let showOverlay = "showOverlay"
        static let openEditor = "openEditorAfterCapture"
        static let overlayCorner = "overlayCorner"
        static let overlaySize = "overlaySize"
        static let overlayAutoClose = "overlayAutoClose"
        static let closeAfterDrag = "closeOverlayAfterDrag"
        static let showCrosshair = "showCrosshair"
        static let showMagnifier = "showMagnifier"
        static let windowShadow = "windowShadow"
        static let selfTimer = "selfTimerSeconds"
        static let agentAccess = "agentAccess"
        static let shortcuts = "shortcuts"
        static let editorColor = "editorColor"
        static let editorLineWidth = "editorLineWidth"
        static let editorFontSize = "editorFontSize"
        static let editorTextStyle = "editorTextStyle"
    }

    private init() {
        let d = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) == nil ? fallback : d.bool(forKey: key) }

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        if let path = d.string(forKey: Keys.saveDirectory) {
            saveDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            saveDirectory = desktop
        }
        imageFormat = ImageFormat(rawValue: d.string(forKey: Keys.imageFormat) ?? "") ?? .png
        jpegQuality = d.object(forKey: Keys.jpegQuality) == nil ? 0.9 : d.double(forKey: Keys.jpegQuality)
        saveAt1x = bool(Keys.saveAt1x, false)
        playSound = bool(Keys.playSound, true)
        copyToClipboard = bool(Keys.copyToClipboard, true)
        autoSave = bool(Keys.autoSave, false)
        showOverlay = bool(Keys.showOverlay, true)
        openEditorAfterCapture = bool(Keys.openEditor, false)
        overlayCorner = OverlayCorner(rawValue: d.string(forKey: Keys.overlayCorner) ?? "") ?? .bottomRight
        overlaySize = OverlaySize(rawValue: d.string(forKey: Keys.overlaySize) ?? "") ?? .medium
        overlayAutoClose = d.integer(forKey: Keys.overlayAutoClose)
        closeOverlayAfterDrag = bool(Keys.closeAfterDrag, true)
        showCrosshair = bool(Keys.showCrosshair, true)
        showMagnifier = bool(Keys.showMagnifier, true)
        windowShadow = bool(Keys.windowShadow, true)
        agentAccess = bool(Keys.agentAccess, false)
        selfTimerSeconds = d.object(forKey: Keys.selfTimer) == nil ? 5 : d.integer(forKey: Keys.selfTimer)

        var map: [HotkeyAction: KeyCombo] = [:]
        if let data = d.data(forKey: Keys.shortcuts),
           let stored = try? JSONDecoder().decode([String: KeyCombo?].self, from: data) {
            for action in HotkeyAction.allCases {
                if let entry = stored[action.rawValue] {
                    if let combo = entry { map[action] = combo }
                } else if let def = action.defaultCombo {
                    map[action] = def
                }
            }
        } else {
            for action in HotkeyAction.allCases { map[action] = action.defaultCombo }
        }
        shortcuts = map
    }

    func setShortcut(_ combo: KeyCombo?, for action: HotkeyAction) {
        shortcuts[action] = combo
        var stored: [String: KeyCombo?] = [:]
        for a in HotkeyAction.allCases { stored[a.rawValue] = shortcuts[a] }
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Keys.shortcuts) }
        HotkeyManager.shared.registerAll()
    }

    func resetShortcuts() {
        for action in HotkeyAction.allCases { shortcuts[action] = action.defaultCombo }
        defaults.removeObject(forKey: Keys.shortcuts)
        HotkeyManager.shared.registerAll()
    }

    // MARK: Editor style memory

    var editorColor: RGBA {
        get {
            guard let data = defaults.data(forKey: Keys.editorColor),
                  let c = try? JSONDecoder().decode(RGBA.self, from: data) else { return .defaultRed }
            return c
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Keys.editorColor) }
    }
    var editorLineWidth: CGFloat {
        get { let v = defaults.double(forKey: Keys.editorLineWidth); return v > 0 ? v : 4 }
        set { defaults.set(Double(newValue), forKey: Keys.editorLineWidth) }
    }
    var editorFontSize: CGFloat {
        get { let v = defaults.double(forKey: Keys.editorFontSize); return v > 0 ? v : 24 }
        set { defaults.set(Double(newValue), forKey: Keys.editorFontSize) }
    }
    var editorTextStyle: TextStyle {
        get { TextStyle(rawValue: defaults.string(forKey: Keys.editorTextStyle) ?? "") ?? .outline }
        set { defaults.set(newValue.rawValue, forKey: Keys.editorTextStyle) }
    }
}
