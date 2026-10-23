import Combine
import Foundation
import MeetingDetection

enum DiarizationProviderChoice: String, Codable, CaseIterable, Identifiable {
    case fluidAudio = "FluidAudio"
    case disabled = "Disabled"
    var id: String { rawValue }
}

/// Persisted settings, stored as JSON in Application Support.
struct SettingsData: Codable, Equatable {
    var diarizationProvider: DiarizationProviderChoice = .fluidAudio
    var language: String = "auto"
    var calendars: [String] = ["primary"]
    var calendarRefreshMinutes: Int = 60
    var calendarEarlyStartTolerance: Int = 2
    var calendarOverrunTolerance: Int = 20
    var primaryUserNames: [String] = []
    var primaryUserHasProfile: Bool = false
    var autoDetectionEnabled: Bool = false
    var endDetectionQuietPeriod: Double = 10
    var endPromptTimeout: Double = 20
    var signalPollInterval: Double = 2
    var vadSensitivity: Double = 0.5

    static let languages = ["auto", "en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh", "ru", "ar", "hi", "nl", "pl", "tr"]

    init() {}

    /// Tolerant decoding: missing keys fall back to defaults so old settings files load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SettingsData()
        diarizationProvider = (try? c.decode(DiarizationProviderChoice.self, forKey: .diarizationProvider)) ?? d.diarizationProvider
        language = (try? c.decode(String.self, forKey: .language)) ?? d.language
        calendars = (try? c.decode([String].self, forKey: .calendars)) ?? d.calendars
        calendarRefreshMinutes = (try? c.decode(Int.self, forKey: .calendarRefreshMinutes)) ?? d.calendarRefreshMinutes
        calendarEarlyStartTolerance = (try? c.decode(Int.self, forKey: .calendarEarlyStartTolerance)) ?? d.calendarEarlyStartTolerance
        calendarOverrunTolerance = (try? c.decode(Int.self, forKey: .calendarOverrunTolerance)) ?? d.calendarOverrunTolerance
        primaryUserNames = (try? c.decode([String].self, forKey: .primaryUserNames)) ?? d.primaryUserNames
        primaryUserHasProfile = (try? c.decode(Bool.self, forKey: .primaryUserHasProfile)) ?? d.primaryUserHasProfile
        autoDetectionEnabled = (try? c.decode(Bool.self, forKey: .autoDetectionEnabled)) ?? d.autoDetectionEnabled
        endDetectionQuietPeriod = (try? c.decode(Double.self, forKey: .endDetectionQuietPeriod)) ?? d.endDetectionQuietPeriod
        endPromptTimeout = (try? c.decode(Double.self, forKey: .endPromptTimeout)) ?? d.endPromptTimeout
        signalPollInterval = (try? c.decode(Double.self, forKey: .signalPollInterval)) ?? d.signalPollInterval
        vadSensitivity = (try? c.decode(Double.self, forKey: .vadSensitivity)) ?? d.vadSensitivity
    }

    var detectionConfig: DetectionConfig {
        DetectionConfig(
            endDetectionQuietPeriod: endDetectionQuietPeriod,
            endPromptTimeout: endPromptTimeout,
            signalPollInterval: signalPollInterval,
            vadSensitivity: vadSensitivity
        ).validated()
    }

    var speakersURL: URL { Paths.voiceProfiles }
    var outputURL: URL { DataFolder.meetings }

    /// First configured name labels the local channel; "You" when none.
    var primaryDisplayName: String {
        primaryUserNames.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "You"
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var data: SettingsData {
        didSet {
            guard data != oldValue else { return }
            save()
        }
    }

    private init() {
        data = Self.load()
    }

    private static func load() -> SettingsData {
        guard let raw = try? Data(contentsOf: Paths.settingsFile),
              let decoded = try? JSONDecoder().decode(SettingsData.self, from: raw) else {
            return SettingsData()
        }
        return decoded
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(data).write(to: Paths.settingsFile, options: .atomic)
            log("⚙️ Settings saved")
        } catch {
            log("❌ Failed to save settings: \(error.localizedDescription)")
        }
    }
}
