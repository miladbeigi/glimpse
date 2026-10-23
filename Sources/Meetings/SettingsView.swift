import AppKit
import MeetingDetection
import SwiftUI

/// The Meetings tab of Glimpse's settings window.
public struct MeetingsSettingsView: View {
    @Binding var enabled: Bool

    public init(enabled: Binding<Bool>) {
        _enabled = enabled
    }

    public var body: some View {
        MeetingsSettingsForm(enabled: $enabled)
            .environmentObject(AppSettings.shared)
            .environmentObject(AppState.shared)
    }
}

private struct MeetingsSettingsForm: View {
    @Binding var enabled: Bool
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var appState: AppState
    @ObservedObject private var calendar = CalendarService.shared
    @StateObject private var enrollment = VoiceEnrollment()
    @State private var newCalendar = ""
    @State private var newName = ""
    @State private var profiles: [String] = []

    var body: some View {
        Form {
            Section {
                Toggle("Record meetings", isOn: $enabled)
            } footer: {
                footnote("Detects calls from the camera, call audio and meeting windows, records your microphone and the call on separate channels, and writes speaker-labelled transcripts. Transcription runs on this Mac; no audio leaves it.")
            }

            Section {
                Toggle("Start recording automatically", isOn: $settings.data.autoDetectionEnabled)
            } header: {
                Text("Recording")
            } footer: {
                footnote(settings.data.autoDetectionEnabled
                    ? "Recording starts when a call is detected and stops when it ends."
                    : "When a call is detected during a calendar meeting, a card offers to record it, once per meeting. You can also start from the menu.")
            }

            Section {
                HStack {
                    Image(systemName: calendar.isAuthenticated ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(calendar.isAuthenticated ? .green : .secondary)
                    Text(calendar.isAuthenticated ? "Signed in" : "Not signed in")
                    Spacer()
                    if calendar.isAuthenticated {
                        Button("Refresh") { Task { await calendar.refresh() } }
                        Button("Sign Out") { calendar.signOut() }
                    } else {
                        Button("Sign In…") { Task { await calendar.signIn() } }
                    }
                }
                if let err = calendar.lastError { Text(err).font(.caption).foregroundStyle(.red) }
                ForEach(settings.data.calendars, id: \.self) { id in
                    HStack {
                        Text(id).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button { settings.data.calendars.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Calendar ID", text: $newCalendar, prompt: Text("primary or name@group.calendar.google.com"))
                        .onSubmit(addCalendar)
                    Button("Add", action: addCalendar)
                }
                Stepper(value: $settings.data.calendarRefreshMinutes, in: 5...240, step: 5) {
                    LabeledContent("Refresh every", value: "\(settings.data.calendarRefreshMinutes) min")
                }
            } header: {
                Text("Google Calendar")
            } footer: {
                footnote("Titles and attendees come from your calendar. Sign-in needs an OAuth client (Desktop app) saved as \(Paths.display(Paths.calendarCredentials)).")
            }

            Section("Transcription") {
                Picker("Language", selection: $settings.data.language) {
                    ForEach(SettingsData.languages, id: \.self) { code in
                        Text(code == "auto" ? "Auto-detect" : Locale.current.localizedString(forLanguageCode: code).map { "\($0) (\(code))" } ?? code).tag(code)
                    }
                }
                Picker("Speaker separation", selection: $settings.data.diarizationProvider) {
                    ForEach(DiarizationProviderChoice.allCases) { Text($0 == .fluidAudio ? "On" : "Off").tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                ForEach(Array(settings.data.primaryUserNames.enumerated()), id: \.element) { i, name in
                    HStack {
                        Text(name)
                        if i == 0 { Text("primary").font(.caption2).foregroundStyle(.secondary) }
                        Spacer()
                        Button { settings.data.primaryUserNames.removeAll { $0 == name } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Your name", text: $newName, prompt: Text("as in calendar invites, e.g. Alice or alice.smith"))
                        .onSubmit(addName)
                    Button("Add", action: addName)
                }
                HStack {
                    Image(systemName: settings.data.primaryUserHasProfile ? "person.wave.2.fill" : "person.wave.2")
                        .foregroundStyle(settings.data.primaryUserHasProfile ? .green : .secondary)
                    Text(settings.data.primaryUserHasProfile ? "Voice profile recorded" : "No voice profile")
                    Spacer()
                    switch enrollment.phase {
                    case .recording(let remaining):
                        ProgressView(value: Double(enrollment.level)).frame(width: 80)
                        Text("Recording… \(remaining)s").monospacedDigit()
                    case .processing:
                        ProgressView().controlSize(.small)
                        Text("Creating profile…")
                    default:
                        Button(settings.data.primaryUserHasProfile ? "Re-record" : "Record…") { record() }
                        if settings.data.primaryUserHasProfile {
                            Button("Delete", role: .destructive) { deleteProfile() }
                        }
                    }
                }
                if case .recording = enrollment.phase { footnote(VoiceEnrollment.prompt) }
                if case .done(let msg) = enrollment.phase { Text(msg).font(.caption).foregroundStyle(.green) }
                if case .failed(let msg) = enrollment.phase { Text(msg).font(.caption).foregroundStyle(.red) }
                LabeledContent("Known voices", value: profiles.isEmpty ? "None yet" : profiles.joined(separator: ", "))
            } header: {
                Text("You")
            } footer: {
                footnote("Your names label your microphone channel. Other people's voices are learned from meetings.")
            }

            Section("Detection") {
                Stepper(value: $settings.data.signalPollInterval, in: DetectionConfig.pollIntervalRange, step: 1) {
                    LabeledContent("Check for calls every", value: "\(Int(settings.data.signalPollInterval)) s")
                }
                LabeledContent("Voice sensitivity") {
                    Slider(value: $settings.data.vadSensitivity, in: 0...1, step: 0.1).frame(width: 180)
                }
                Stepper(value: $settings.data.endDetectionQuietPeriod, in: DetectionConfig.quietPeriodRange, step: 5) {
                    LabeledContent("Ask if ended after", value: "\(Int(settings.data.endDetectionQuietPeriod)) s quiet")
                }
                Stepper(value: $settings.data.endPromptTimeout, in: DetectionConfig.promptTimeoutRange, step: 5) {
                    LabeledContent("Stop if no answer after", value: "\(Int(settings.data.endPromptTimeout)) s")
                }
            }

            Section {
                LabeledContent("Transcripts") {
                    HStack {
                        Text(Paths.display(DataFolder.meetings)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Show") { reveal(DataFolder.meetings) }
                    }
                }
                LabeledContent("Debug log") {
                    Button("Open") { NSWorkspace.shared.open(Log.fileURL) }
                }
            } header: {
                Text("Files")
            } footer: {
                footnote("Transcripts are Markdown files in dated folders inside the data folder (Settings › General).")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reloadProfiles)
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addCalendar() {
        let v = newCalendar.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty && !settings.data.calendars.contains(v) { settings.data.calendars.append(v) }
        newCalendar = ""
    }

    private func addName() {
        let v = newName.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty && !settings.data.primaryUserNames.contains(v) { settings.data.primaryUserNames.append(v) }
        newName = ""
    }

    private func record() {
        enrollment.reset()
        enrollment.start(names: settings.data.primaryUserNames, speakersDirectory: settings.data.speakersURL) {
            if case .done = enrollment.phase { settings.data.primaryUserHasProfile = true }
            reloadProfiles()
        }
    }

    private func deleteProfile() {
        let store = VoiceProfileStore(directory: settings.data.speakersURL)
        settings.data.primaryUserNames.forEach(store.delete)
        settings.data.primaryUserHasProfile = false
        reloadProfiles()
    }

    private func reloadProfiles() {
        profiles = VoiceProfileStore(directory: settings.data.speakersURL).names()
    }

    private func reveal(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
