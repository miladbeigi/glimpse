import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var records: [TranscriptionRecord] = []
    @Published var selectedId: Int64?
    @Published var reprocessingId: Int64?
    private var observer: NSObjectProtocol?

    let store = TranscriptionHistoryStore.shared

    init() {
        reload()
        observer = NotificationCenter.default.addObserver(forName: .transcriptionHistoryChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        records = store.all()
        if selectedId == nil || !records.contains(where: { $0.id == selectedId }) {
            selectedId = records.first?.id
        }
    }

    var selected: TranscriptionRecord? { records.first { $0.id == selectedId } }

    /// Failed recordings that never produced a transcript (e.g. "No speech was detected").
    var emptyRecords: [TranscriptionRecord] { records.filter { $0.status == .failed && $0.markdownFilePath == nil } }

    static func canDelete(_ record: TranscriptionRecord) -> Bool {
        record.status == .completed || record.status == .failed
    }

    /// Delete records and move their WAV and transcript to the Trash (recoverable from there).
    /// In-progress records are skipped.
    func delete(_ targets: [TranscriptionRecord]) {
        let targets = targets.filter(Self.canDelete)
        guard !targets.isEmpty else { return }
        for record in targets {
            for path in [record.wavFilePath, record.markdownFilePath].compactMap({ $0 }) where FileManager.default.fileExists(atPath: path) {
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                } catch {
                    log("⚠️ Could not move \(Paths.display(URL(fileURLWithPath: path))) to Trash: \(error.localizedDescription)")
                }
            }
        }
        store.delete(targets.map(\.id))
        log("🗑️ Deleted \(targets.count) transcription(s) from history")
        reload()
    }

    func knownSpeakers() -> [String] {
        let profiles = VoiceProfileStore(directory: AppSettings.shared.data.speakersURL).names()
        return Array(Set(profiles + store.knownAttendees())).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func reprocess(_ record: TranscriptionRecord) {
        reprocessingId = record.id
        Task {
            _ = await AppState.shared.reprocess(record)
            reprocessingId = nil
            reload()
            // Point the view at the regenerated transcript.
            selectedId = record.id
        }
    }
}

struct HistoryView: View {
    @StateObject private var model: HistoryViewModel

    init(model: HistoryViewModel? = nil) {
        _model = StateObject(wrappedValue: model ?? HistoryViewModel())
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Transcription History").font(.system(size: 13, weight: .bold))
                    Spacer()
                    if !model.emptyRecords.isEmpty {
                        Button { confirmDeleteEmpty = true } label: {
                            Label("Delete Empty (\(model.emptyRecords.count))", systemImage: "trash").font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .help("Delete failed recordings that have no transcript")
                    }
                    Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                List(selection: $model.selectedId) {
                    ForEach(model.records) { record in
                        HistoryRow(record: record).tag(record.id)
                            .contextMenu {
                                Button(role: .destructive) { pendingDelete = record } label: { Label("Delete…", systemImage: "trash") }
                                    .disabled(!HistoryViewModel.canDelete(record))
                            }
                    }
                }
                .listStyle(.sidebar)
                .onDeleteCommand {
                    if let record = model.selected, HistoryViewModel.canDelete(record) { pendingDelete = record }
                }
            }
            .frame(minWidth: 380, idealWidth: 500, maxWidth: 600)

            Group {
                if let record = model.selected {
                    HistoryDetailView(record: record, model: model)
                        .id(record.id)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform").font(.system(size: 36)).foregroundColor(.secondary)
                        Text("No transcriptions yet").foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 560)
        .confirmationDialog(pendingDelete.map { "Delete “\($0.meetingTitle)”?" } ?? "",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let record = pendingDelete { model.delete([record]) }
                pendingDelete = nil
            }
        } message: {
            Text("The recording and transcript are moved to the Trash.")
        }
        .confirmationDialog("Delete \(model.emptyRecords.count) empty recording(s)?", isPresented: $confirmDeleteEmpty) {
            Button("Delete", role: .destructive) { model.delete(model.emptyRecords) }
        } message: {
            Text("Failed recordings with no transcript are removed from history and their audio is moved to the Trash.")
        }
        .environment(\.requestDelete) { pendingDelete = $0 }
    }

    @State private var pendingDelete: TranscriptionRecord?
    @State private var confirmDeleteEmpty = false
}

/// Lets the detail view ask HistoryView to confirm a delete.
private struct RequestDeleteKey: EnvironmentKey {
    static let defaultValue: (TranscriptionRecord) -> Void = { _ in }
}

extension EnvironmentValues {
    var requestDelete: (TranscriptionRecord) -> Void {
        get { self[RequestDeleteKey.self] }
        set { self[RequestDeleteKey.self] = newValue }
    }
}

struct StatusIcon: View {
    var status: TranscriptionStatus
    var body: some View {
        switch status {
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundColor(.red)
        case .processing: ProgressView().controlSize(.mini)
        case .pending: Image(systemName: "clock").foregroundColor(.orange)
        }
    }
}

struct HistoryRow: View {
    var record: TranscriptionRecord

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd, h:mm a"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.meetingTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                StatusIcon(status: record.status).font(.system(size: 11))
            }
            Label(Self.df.string(from: record.meetingDate), systemImage: "calendar").font(.system(size: 11)).foregroundColor(.secondary)
            if !record.attendees.isEmpty {
                Label(record.attendees.joined(separator: ", "), systemImage: "person.2").font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

struct HistoryDetailView: View {
    let record: TranscriptionRecord
    @ObservedObject var model: HistoryViewModel
    @State private var newAttendee = ""
    @State private var showWrongMeeting = false
    @Environment(\.requestDelete) private var requestDelete

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header
                HStack(alignment: .top) {
                    Text(record.meetingTitle).font(.system(size: 20, weight: .bold))
                    Spacer()
                    StatusBadge(status: record.status)
                }
                HStack {
                    Label(Self.df.string(from: record.meetingDate), systemImage: "calendar")
                    Spacer()
                    if let d = record.durationSeconds { Label(formatDuration(d), systemImage: "clock") }
                }
                .font(.system(size: 12)).foregroundColor(.secondary)
                if let n = record.segmentCount { Text("\(n) segments").font(.system(size: 11)).foregroundColor(.secondary) }
                if record.status == .failed, let err = record.currentStep {
                    Text(err).font(.system(size: 12)).foregroundColor(.red).textSelection(.enabled)
                } else if record.status == .processing || record.status == .pending, let step = record.currentStep {
                    Text(step).font(.system(size: 12)).foregroundColor(.secondary)
                }

                Divider()

                // Attendees
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Attendees").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Button { showWrongMeeting = true } label: {
                            Label("Wrong meeting?", systemImage: "calendar.badge.exclamationmark").font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .popover(isPresented: $showWrongMeeting, arrowEdge: .bottom) {
                            WrongMeetingPicker(record: record) { meeting in
                                showWrongMeeting = false
                                model.store.updateMeetingAssignment(record.id, meetingId: meeting.id, title: meeting.title, attendees: meeting.attendees)
                                if let updated = model.store.record(record.id) { model.reprocess(updated) }
                            }
                        }
                    }
                    FlowLayout(spacing: 6) {
                        ForEach(record.attendees, id: \.self) { name in
                            TagView(text: name, color: .accentColor) {
                                model.store.updateAttendees(record.id, attendees: record.attendees.filter { $0 != name })
                            }
                        }
                        AttendeeAdder(text: $newAttendee, suggestions: model.knownSpeakers().filter { !record.attendees.contains($0) }) { name in
                            let v = name.trimmingCharacters(in: .whitespaces)
                            guard !v.isEmpty, !record.attendees.contains(v) else { return }
                            model.store.updateAttendees(record.id, attendees: record.attendees + [v])
                        }
                    }
                }


                if !record.createdEmbeddings.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Created Voice Profiles").font(.system(size: 14, weight: .semibold))
                        FlowLayout(spacing: 6) {
                            ForEach(record.createdEmbeddings, id: \.self) { name in
                                TagView(text: name, color: .green) {
                                    VoiceProfileStore(directory: AppSettings.shared.data.speakersURL).delete(name)
                                    model.store.removeCreatedEmbedding(record.id, name: name)
                                }
                            }
                        }
                        Text("Removing a tag deletes the voice profile learned during this transcription.").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }

                Divider()

                // Timings
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pipeline Timings").font(.system(size: 13, weight: .semibold))
                    Text("Steps").font(.system(size: 11)).foregroundColor(.secondary)
                    timingRow("Transcription", record.timings.transcription)
                    timingRow("Diarization", record.timings.diarization)
                    timingRow("File Saving", record.timings.fileSaving)
                    Divider().padding(.vertical, 2)
                    HStack {
                        Text("Total End-to-End").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(record.timings.totalEndToEnd.map { String(format: "%.1fs", $0) } ?? "-").font(.system(size: 13, weight: .semibold)).foregroundColor(.blue)
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))

                Divider()

                // Files
                VStack(alignment: .leading, spacing: 10) {
                    Text("Files").font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 10) {
                        Button { downloadWAV() } label: { Label("Download WAV", systemImage: "waveform") }
                            .disabled(!fileExists(record.wavFilePath))
                        Button { if let p = record.markdownFilePath { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } } label: { Label("Open Transcript", systemImage: "doc.text") }
                            .disabled(!fileExists(record.markdownFilePath))
                        Button { showInFinder() } label: { Label("Show in Finder", systemImage: "folder") }
                            .disabled(!fileExists(record.markdownFilePath) && !fileExists(record.wavFilePath))
                    }
                }
                Divider()
                HStack {
                    Button { model.reprocess(record) } label: { Label("Reprocess Transcription", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(!fileExists(record.wavFilePath) || model.reprocessingId != nil)
                    if model.reprocessingId == record.id { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(role: .destructive) { requestDelete(record) } label: { Label("Delete", systemImage: "trash") }
                        .disabled(!HistoryViewModel.canDelete(record) || model.reprocessingId == record.id)
                        .help("Remove from history and move the recording and transcript to the Trash")
                }
            }
            .padding(24)
        }
    }

    private func timingRow(_ label: String, _ value: Double?) -> some View {
        HStack {
            Text(label).font(.system(size: 12))
            Spacer()
            Text(value.map { String(format: "%.1fs", $0) } ?? "-").font(.system(size: 12))
        }
    }

    private func fileExists(_ path: String?) -> Bool {
        guard let path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private func downloadWAV() {
        guard let path = record.wavFilePath else { return }
        let src = URL(fileURLWithPath: path)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = src.lastPathComponent
        panel.allowedContentTypes = [.wav]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.copyItem(at: src, to: dest) } catch { log("❌ WAV export failed: \(error.localizedDescription)") }
        }
    }

    private func showInFinder() {
        let paths = [record.markdownFilePath, record.wavFilePath].compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0) }
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }
}

struct StatusBadge: View {
    var status: TranscriptionStatus
    var body: some View {
        let (text, color): (String, Color) = {
            switch status {
            case .completed: return ("Completed", .green)
            case .failed: return ("Failed", .red)
            case .processing: return ("Processing", .orange)
            case .pending: return ("Pending", .orange)
            }
        }()
        return HStack(spacing: 5) {
            StatusIcon(status: status).font(.system(size: 10))
            Text(text).font(.system(size: 11, weight: .medium)).foregroundColor(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.18)))
    }
}

struct TagView: View {
    var text: String
    var color: Color
    var onRemove: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 12))
            Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.2)))
        .overlay(Capsule().strokeBorder(color.opacity(0.4)))
    }
}

/// "+" button that expands into a text field with autocomplete.
struct AttendeeAdder: View {
    @Binding var text: String
    var suggestions: [String]
    var onAdd: (String) -> Void
    @State private var editing = false

    var filtered: [String] {
        guard !text.isEmpty else { return [] }
        return suggestions.filter { $0.localizedCaseInsensitiveContains(text) }.prefix(6).map { $0 }
    }

    var body: some View {
        if editing {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit { commit(text) }
                    .onExitCommand { editing = false; text = "" }
                ForEach(filtered, id: \.self) { s in
                    Button(s) { commit(s) }.buttonStyle(.borderless).font(.system(size: 11))
                }
            }
        } else {
            Button { editing = true } label: {
                Image(systemName: "plus.circle.fill").font(.system(size: 17)).foregroundColor(.accentColor)
            }
            .buttonStyle(.borderless)
            .help("Add attendee")
        }
    }

    private func commit(_ value: String) {
        onAdd(value)
        text = ""
        editing = false
    }
}

/// Calendar events overlapping the recording (−90 … +150 min around its date).
struct WrongMeetingPicker: View {
    let record: TranscriptionRecord
    var onPick: (Meeting) -> Void
    @State private var meetings: [Meeting] = []
    @State private var loading = true
    @State private var error: String?

    private static let tf: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Assign to a different meeting").font(.system(size: 13, weight: .semibold))
            if loading {
                ProgressView().controlSize(.small)
            } else if let error {
                Text(error).font(.system(size: 11)).foregroundColor(.red)
            } else if meetings.isEmpty {
                Text("No calendar events around this recording.").font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                ForEach(meetings) { m in
                    Button { onPick(m) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.title).font(.system(size: 12, weight: .medium))
                            Text("\(Self.tf.string(from: m.start)) – \(Self.tf.string(from: m.end)) · \(m.attendees.joined(separator: ", "))")
                                .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(m.id == record.meetingId ? Color.accentColor.opacity(0.15) : Color.clear))
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .task {
            do {
                meetings = try await CalendarService.shared.getMeetings(
                    from: record.meetingDate.addingTimeInterval(-90 * 60), to: record.meetingDate.addingTimeInterval(150 * 60))
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

/// Simple wrapping layout for tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x)
        }
        return CGSize(width: min(width, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
