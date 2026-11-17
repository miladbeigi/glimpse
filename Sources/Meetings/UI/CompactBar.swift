import AppKit
import SwiftUI

// The pieces of Glimpse's floating control bars (screen recording, meeting recording, mute badge): a translucent
// capsule with a drag grip, small icon buttons and a red Stop button. Host them in a panel with a dark appearance.

public extension View {
    /// Wraps a bar's contents in the shared capsule. The whole bar drags its window.
    func compactBar(alert: Bool = false) -> some View {
        padding(.leading, 4)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().fill(UITheme.red.opacity(alert ? 0.12 : 0)).allowsHitTesting(false))
            .overlay(Capsule().strokeBorder(alert ? UITheme.red.opacity(0.55) : Color.white.opacity(0.12)))
            .contentShape(Capsule())
            .movesWindowOnDrag()
            .fixedSize()
    }
}

/// A handle at a bar's leading edge that shows it can be dragged.
public struct BarGrip: View {
    public init() {}

    public var body: some View {
        Image(systemName: "line.3.horizontal")
            .rotationEffect(.degrees(90))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 14, height: 28)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
            .help("Drag to move")
    }
}

/// A square icon button that lights up on hover.
public struct BarButton: View {
    let symbol: String
    var active = true
    var tint: Color?
    let help: String
    let action: () -> Void
    @State private var hovered = false

    public init(symbol: String, active: Bool = true, tint: Color? = nil, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.active = active
        self.tint = tint
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint.map { AnyShapeStyle($0) }
                    ?? (active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(hovered ? 0.14 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// The red "Stop" button.
public struct BarStopButton: View {
    let help: String
    let action: () -> Void

    public init(help: String = "Stop and save", action: @escaping () -> Void) {
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 9, height: 9)
                Text("Stop").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(Color.red))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A pulsing red dot (or an orange pause glyph) and the elapsed time.
public struct BarTimer: View {
    let elapsed: String
    let paused: Bool

    public init(elapsed: String, paused: Bool) {
        self.elapsed = elapsed
        self.paused = paused
    }

    public var body: some View {
        HStack(spacing: 7) {
            if paused {
                Image(systemName: "pause.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.orange)
            } else {
                BarRecordingDot()
            }
            Text(elapsed)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .frame(minWidth: 38, alignment: .leading)
        }
        .padding(.leading, 6)
    }
}

struct BarRecordingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 10, height: 10)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// Five bars that light up with the microphone level (0–1).
public struct BarLevelMeter: View {
    let level: Float

    public init(level: Float) { self.level = level }

    public var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5) { i in
                let on = level > Float(i) / 5 + 0.02
                RoundedRectangle(cornerRadius: 1)
                    .fill(on ? Color.green : Color.white.opacity(0.2))
                    .frame(width: 3, height: 6 + CGFloat(i) * 2.5)
            }
        }
        .frame(height: 18)
        .animation(.linear(duration: 0.1), value: level)
        .help("Microphone level")
    }
}

/// A short vertical separator between groups of controls.
public struct BarDivider: View {
    public init() {}

    public var body: some View {
        Divider().frame(height: 22).padding(.horizontal, 2)
    }
}
