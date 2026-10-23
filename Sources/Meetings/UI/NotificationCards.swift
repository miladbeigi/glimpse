import SwiftUI

/// Stage chip labels mapped from pipeline progress text.
enum ProcessingStage: String {
    case preparing = "Preparing"
    case transcribing = "Transcribing"
    case identifying = "Identifying speakers"
    case saving = "Saving transcript"

    var icon: String {
        switch self {
        case .preparing: return "hourglass"
        case .transcribing: return "text.bubble"
        case .identifying: return "waveform.path.ecg"
        case .saving: return "square.and.arrow.down"
        }
    }

    static func from(step: String) -> ProcessingStage {
        let s = step.lowercased()
        if s.contains("saving transcript") || s.contains("generating") || s.contains("writing") { return .saving }
        if s.contains("speaker") || s.contains("diariz") || s.contains("voice") || s.contains("identif") { return .identifying }
        if s.contains("transcrib") { return .transcribing }
        return .preparing
    }
}

enum CardKind: Equatable {
    case meetingDetectedAdHoc(signals: String)
    case meetingDetectedCalendar(title: String, minutes: Int, attendees: [String])
    case recordingStarted(title: String, attendees: [String])
    case processing(title: String, status: String, fraction: Double)
    case ready(title: String, minutes: Int, transcript: URL?)
    case message(title: String, body: String, isError: Bool)
    /// Auto-recording is off and a calendar meeting just started: offer to record it.
    case recordPrompt(title: String, attendees: [String])

    var isPersistent: Bool {
        if case .processing = self { return true }
        return false
    }
}

/// Observable card model; the manager mutates `kind` in place to replace a card (e.g.
/// processing → ready).
final class CardModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var kind: CardKind
    @Published var hovering = false
    var onCancelRecording: (() -> Void)?
    var onOpenTranscript: ((URL) -> Void)?
    var onClose: (() -> Void)?
    var onRecord: (() -> Void)?

    init(kind: CardKind) { self.kind = kind }
}

struct NotificationCardView: View {
    @ObservedObject var model: CardModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
                .padding(18)
                .background(GlassBackground())
                .padding(10)
            if model.hovering {
                HoverCloseButton { model.onClose?() }
                    .padding(.leading, 2)
                    .padding(.top, 2)
                    .transition(.opacity)
            }
        }
        .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { model.hovering = h } }
    }

    @ViewBuilder private var content: some View {
        switch model.kind {
        case .meetingDetectedAdHoc(let signals):
            VStack(alignment: .leading, spacing: 14) {
                header(title: "Meeting Detected", subtitle: "Recording started automatically", accent: UITheme.orange) { RecordingGlyph() }
                Divider().background(UITheme.hairline)
                HStack(alignment: .center, spacing: 14) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08))
                        .overlay(Image(systemName: "waveform").font(.system(size: 20, weight: .semibold)).foregroundColor(UITheme.red))
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Ad-hoc meeting").font(.system(size: 15, weight: .semibold)).foregroundColor(UITheme.link)
                        Text(signals).font(.system(size: 12)).foregroundColor(UITheme.secondaryText).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    cancelButton
                }
            }

        case .meetingDetectedCalendar(let title, let minutes, let attendees):
            VStack(alignment: .leading, spacing: 14) {
                header(title: "Meeting Detected", subtitle: "Recording started automatically", accent: UITheme.orange) { RecordingGlyph() }
                Divider().background(UITheme.hairline)
                calendarRow(title: title, detail: "Google Calendar matched · \(minutes) min", attendees: attendees)
            }

        case .recordingStarted(let title, let attendees):
            VStack(alignment: .leading, spacing: 14) {
                header(title: "Recording Started", subtitle: "Glimpse is recording this meeting", accent: UITheme.orange) { RecordingGlyph() }
                Divider().background(UITheme.hairline)
                calendarRow(title: title, detail: attendees.isEmpty ? "Manual recording" : "\(attendees.count) attendee\(attendees.count == 1 ? "" : "s")", attendees: attendees)
            }

        case .processing(let title, let status, let fraction):
            let stage = ProcessingStage.from(step: status)
            VStack(alignment: .leading, spacing: 14) {
                header(title: "Meeting Ended", subtitle: "Processing transcript…", accent: UITheme.green, check: true) {
                    ProgressRing(fraction: max(0.04, fraction)) {
                        Image(systemName: "doc.text").font(.system(size: 16, weight: .medium)).foregroundColor(.white)
                    }
                    .frame(width: 44, height: 44)
                }
                Divider().background(UITheme.hairline)
                HStack(spacing: 12) {
                    MeetingChip(title: title)
                    Chip(text: stage.rawValue) {
                        Image(systemName: stage.icon).font(.system(size: 12)).foregroundColor(UITheme.secondaryText)
                    }
                    .fixedSize()
                }
                Text(status).font(.system(size: 12.5)).foregroundColor(UITheme.secondaryText).lineLimit(1)
                GradientProgressBar(fraction: fraction)
            }

        case .ready(let title, let minutes, let transcript):
            VStack(alignment: .leading, spacing: 14) {
                header(title: "Transcript Ready", subtitle: "Your transcript is saved", accent: UITheme.green, check: true) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08))
                        .overlay(Image(systemName: "doc.text.fill").font(.system(size: 18)).foregroundColor(.white))
                        .frame(width: 40, height: 40)
                }
                Divider().background(UITheme.hairline)
                HStack(alignment: .center, spacing: 12) {
                    MeetingChip(title: title)
                    if let transcript {
                        Button("Open Transcript") { model.onOpenTranscript?(transcript) }
                            .buttonStyle(OverlayButtonStyle(kind: .primary, height: 38))
                            .frame(width: 160)
                    }
                }
                Text("Transcript complete · \(minutes) min recording").font(.system(size: 12.5)).foregroundColor(UITheme.secondaryText)
                GradientProgressBar(fraction: 1)
            }

        case .recordPrompt(let title, let attendees):
            VStack(alignment: .leading, spacing: 14) {
                header(title: "Meeting Started", subtitle: "Not recording", accent: UITheme.orange) { EmptyView() }
                Divider().background(UITheme.hairline)
                calendarRow(title: title, detail: attendees.isEmpty ? "Google Calendar" : "\(attendees.count) attendee\(attendees.count == 1 ? "" : "s")", attendees: attendees, cancellable: false)
                HStack(spacing: 10) {
                    Button("Not Now") { model.onClose?() }
                        .buttonStyle(OverlayButtonStyle(kind: .secondary, height: 38))
                    Button("Record") { model.onRecord?() }
                        .buttonStyle(OverlayButtonStyle(kind: .primary, height: 38))
                }
            }

        case .message(let title, let body, let isError):
            HStack(alignment: .top, spacing: 14) {
                AppBadge(accent: isError ? UITheme.orange : UITheme.green)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Glimpse").font(.system(size: 12.5)).foregroundColor(UITheme.secondaryText)
                        Spacer()
                        Text("Now").font(.system(size: 12.5)).foregroundColor(UITheme.secondaryText)
                    }
                    HStack(spacing: 6) {
                        if isError { Text("⚠️").font(.system(size: 17)) }
                        Text(title).font(.system(size: 19, weight: .bold)).foregroundColor(.white)
                    }
                    Text(body).font(.system(size: 13)).foregroundColor(UITheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var cancelButton: some View {
        Button("Cancel Recording") { model.onCancelRecording?() }
            .buttonStyle(OverlayButtonStyle(kind: .destructive, height: 40))
            .frame(width: 160)
    }

    private func calendarRow(title: String, detail: String, attendees: [String], cancellable: Bool = true) -> some View {
        HStack(alignment: .center, spacing: 14) {
            CalendarGlyph().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(UITheme.link).lineLimit(1)
                Text(detail).font(.system(size: 12)).foregroundColor(UITheme.secondaryText).lineLimit(1)
                if !attendees.isEmpty { AvatarStack(names: attendees).padding(.top, 2) }
            }
            Spacer(minLength: 8)
            if cancellable { cancelButton }
        }
    }

    private func header<Trailing: View>(title: String, subtitle: String, accent: Color, check: Bool = false, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: 14) {
            AppBadge(accent: accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Glimpse").font(.system(size: 12.5)).foregroundColor(UITheme.secondaryText)
                HStack(spacing: 8) {
                    if check {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(UITheme.green)
                            .overlay(Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(.white))
                            .frame(width: 20, height: 20)
                    }
                    Text(title).font(.system(size: 19, weight: .bold)).foregroundColor(.white)
                }
                Text(subtitle).font(.system(size: 13)).foregroundColor(UITheme.secondaryText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Text("Now").font(.system(size: 12.5)).foregroundColor(UITheme.secondaryText)
                trailing()
            }
        }
    }
}

/// Google-Calendar-like "31" tile.
struct CalendarGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            RoundedRectangle(cornerRadius: w * 0.2, style: .continuous).fill(Color.white)
                .overlay(alignment: .top) {
                    Rectangle().fill(UITheme.blue).frame(height: w * 0.2).padding(.horizontal, w * 0.12).padding(.top, w * 0.18)
                }
                .overlay {
                    Text("\(Calendar.current.component(.day, from: Date()))")
                        .font(.system(size: w * 0.36, weight: .bold)).foregroundColor(UITheme.blue).offset(y: w * 0.12)
                }
        }
    }
}
