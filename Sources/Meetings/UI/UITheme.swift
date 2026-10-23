import AppKit
import SwiftUI

/// Shared palette and components for the overlay UI.
enum UITheme {
    static let tint = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let stroke = Color.white.opacity(0.14)
    static let hairline = Color.white.opacity(0.10)
    static let chipFill = Color.white.opacity(0.06)
    static let chipStroke = Color.white.opacity(0.10)
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.45)

    static let red = Color(red: 0.89, green: 0.30, blue: 0.24)
    static let redButton = Color(red: 0.66, green: 0.20, blue: 0.18)
    static let green = Color(red: 0.43, green: 0.80, blue: 0.36)
    static let yellow = Color(red: 0.98, green: 0.84, blue: 0.25)
    static let orange = Color(red: 0.96, green: 0.66, blue: 0.23)
    static let blue = Color(red: 0.36, green: 0.58, blue: 0.96)
    static let link = Color(red: 0.42, green: 0.62, blue: 0.98)

    static let progressGradient = LinearGradient(colors: [green, yellow], startPoint: .leading, endPoint: .trailing)
    static let cornerRadius: CGFloat = 20
}

/// Blur + 86% dark tint, 20pt radius, hairline stroke.
struct GlassBackground: View {
    var cornerRadius: CGFloat = UITheme.cornerRadius

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
            UITheme.tint.opacity(0.86)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(UITheme.stroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// Small static waveform glyph (the bars beside the mic in the app badge).
struct WaveGlyph: View {
    var color: Color
    var heights: [CGFloat] = [0.35, 0.7, 1.0, 0.55, 0.85, 0.4]
    var barWidth: CGFloat = 1.6
    var spacing: CGFloat = 1.4
    var height: CGFloat = 12

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(heights.indices, id: \.self) { i in
                Capsule().fill(color).frame(width: barWidth, height: max(2, heights[i] * height))
            }
        }
    }
}

/// App badge: black rounded square, mic glyph with waveform on both sides.
struct AppBadge: View {
    var accent: Color = UITheme.orange
    var size: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(Color.black)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .overlay(
                HStack(spacing: size * 0.05) {
                    WaveGlyph(color: accent, heights: [0.35, 0.75, 1.0, 0.55, 0.8], barWidth: size * 0.028, spacing: size * 0.025, height: size * 0.26)
                    Image(systemName: "mic").font(.system(size: size * 0.36, weight: .medium)).foregroundColor(.white)
                    WaveGlyph(color: accent, heights: [0.8, 0.55, 1.0, 0.75, 0.35], barWidth: size * 0.028, spacing: size * 0.025, height: size * 0.26)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .frame(width: size, height: size)
    }
}

/// Rounded "chip" with optional leading icon.
struct Chip<Leading: View>: View {
    var text: String
    var expand = false
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        HStack(spacing: 8) {
            leading()
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundColor(UITheme.primaryText).lineLimit(1).truncationMode(.tail)
            if expand { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(UITheme.chipFill))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(UITheme.chipStroke, lineWidth: 1))
    }
}

extension Chip where Leading == EmptyView {
    init(text: String, expand: Bool = false) {
        self.init(text: text, expand: expand, leading: { EmptyView() })
    }
}

/// Meeting chip with the green calendar glyph.
struct MeetingChip: View {
    var title: String
    var expand = true
    var body: some View {
        Chip(text: title, expand: expand) {
            Image(systemName: "calendar").font(.system(size: 12, weight: .semibold)).foregroundColor(UITheme.green)
        }
    }
}

enum OverlayButtonStyleKind { case destructive, primary, secondary, secondaryDestructive }

struct OverlayButtonStyle: ButtonStyle {
    var kind: OverlayButtonStyleKind
    var height: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        let (fill, text): (AnyShapeStyle, Color) = {
            switch kind {
            case .destructive: return (AnyShapeStyle(LinearGradient(colors: [UITheme.redButton.opacity(1.0), UITheme.redButton.opacity(0.85)], startPoint: .top, endPoint: .bottom)), .white)
            case .primary: return (AnyShapeStyle(LinearGradient(colors: [Color(red: 0.42, green: 0.64, blue: 0.98), UITheme.blue], startPoint: .top, endPoint: .bottom)), .white)
            case .secondary: return (AnyShapeStyle(UITheme.chipFill), .white)
            case .secondaryDestructive: return (AnyShapeStyle(UITheme.chipFill), UITheme.red)
            }
        }()
        return configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(text)
            .frame(maxWidth: .infinity, minHeight: height)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

/// Circular initials avatar with deterministic color.
struct AvatarView: View {
    var name: String
    var size: CGFloat = 24

    static let palette: [Color] = [
        Color(red: 0.36, green: 0.42, blue: 0.75), Color(red: 0.66, green: 0.42, blue: 0.33),
        Color(red: 0.33, green: 0.55, blue: 0.36), Color(red: 0.55, green: 0.36, blue: 0.62),
        Color(red: 0.30, green: 0.55, blue: 0.62), Color(red: 0.70, green: 0.55, blue: 0.25),
    ]

    var initials: String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" }).prefix(2)
        let s = parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
        return s.isEmpty ? "?" : s
    }

    var color: Color {
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return Self.palette[hash % Self.palette.count]
    }

    var body: some View {
        Circle().fill(color)
            .overlay(Text(initials).font(.system(size: size * 0.42, weight: .semibold)).foregroundColor(.white))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1.5))
            .frame(width: size, height: size)
    }
}

/// Overlapping attendee avatars with a "+N" overflow bubble.
struct AvatarStack: View {
    var names: [String]
    var maxVisible = 2
    var size: CGFloat = 24

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(names.prefix(maxVisible).enumerated()), id: \.offset) { _, n in
                AvatarView(name: n, size: size)
            }
            if names.count > maxVisible {
                Circle().fill(Color(red: 0.33, green: 0.55, blue: 0.36))
                    .overlay(Text("+\(names.count - maxVisible)").font(.system(size: size * 0.4, weight: .semibold)).foregroundColor(.white))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1.5))
                    .frame(width: size, height: size)
            }
        }
    }
}

/// Gradient progress bar (green → yellow).
struct GradientProgressBar: View {
    var fraction: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule().fill(UITheme.progressGradient)
                    .frame(width: max(height, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
                    .animation(.easeInOut(duration: 0.4), value: fraction)
            }
        }
        .frame(height: height)
    }
}

/// Progress ring around a glyph.
struct ProgressRing<Content: View>: View {
    var fraction: Double
    var lineWidth: CGFloat = 5
    var colors: [Color] = [UITheme.yellow, UITheme.green]
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.10), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                .stroke(AngularGradient(colors: colors, center: .center), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: fraction)
            content()
        }
    }
}

/// Live-ish red waveform glyph used in the Meeting Detected header.
struct RecordingGlyph: View {
    @State private var phase = false
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(UITheme.red).frame(width: 10, height: 10)
            WaveGlyph(color: UITheme.red, heights: phase ? [0.4, 0.8, 1.0, 0.6, 0.9, 0.5, 0.3] : [0.6, 0.5, 0.8, 1.0, 0.5, 0.7, 0.45], barWidth: 1.8, spacing: 2, height: 18)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { phase.toggle() }
        }
    }
}

/// Native-looking circular close button shown on hover.
struct HoverCloseButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color(white: 0.28)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
