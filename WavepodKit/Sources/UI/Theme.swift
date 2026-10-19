import AppKit
import Library
import SwiftUI

/// Design tokens from docs/decisions/0006-license-and-brand.md. Every colour has a light and a dark value and
/// resolves against the view's effective appearance, so snapshot tests can force either.
public enum Palette {
    public static let paper = dynamic(0xF7F4EE, 0x16181A)
    public static let surface = dynamic(0xFFFFFF, 0x1E2123)
    public static let sunken = dynamic(0xF1EDE5, 0x1A1C1E)
    public static let ink = dynamic(0x1C1B19, 0xECE8E1)
    public static let inkMuted = dynamic(0x6B665E, 0xA39E95)
    public static let rule = dynamic(0xE4DFD6, 0x2E3235)
    /// The keycap in the home greeting.
    public static let key = dynamic(0xF6C27A, 0x8A5A1C)
    public static let keyEdge = dynamic(0xC9862E, 0xC98A3E)
    /// Selected and hovered sidebar rows.
    public static let selection = dynamic(0xEAE5DC, 0x2A2E31)
    public static let accent = dynamic(0x0F5E63, 0x5FB3B3)
    public static let onAccent = dynamic(0xFFFFFF, 0x0E1A1B)
    public static let accentSoft = dynamic(0xE3EEEC, 0x1F3536)
    public static let highlight = dynamic(0xE6F0EE, 0x203A3B)
    public static let wordHighlight = dynamic(0xBFDCD7, 0x2E5A5B)

    /// Speaker chip colours, AA contrast on `surface` in both modes (checked in UITests).
    public static let speakerHex: [(light: UInt32, dark: UInt32)] = [
        (0x1F5F8B, 0x8CB8E0), (0x8A4B1F, 0xE0A57A), (0x5B4E9A, 0xB3A8E6),
        (0x2F6B3A, 0x8FCB98), (0x8C3A5A, 0xE39BB8), (0x6B5A12, 0xD1C27A),
    ]
    public static func speaker(_ index: Int) -> Color {
        let pair = speakerHex[index % speakerHex.count]
        return dynamic(pair.light, pair.dark)
    }

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Type scale. macOS has no system Dynamic Type, so wavepod has its own text-size setting (⌘+ / ⌘−) that scales every
/// style; VoiceOver and the system's accessibility text settings still apply on top.
public struct Typography: Sendable {
    public var scale: Double

    public init(scale: Double = 1) { self.scale = scale }

    func size(_ base: Double) -> CGFloat { CGFloat((base * scale).rounded()) }

    public var reading: Font { .system(size: size(15.5), design: .serif) }
    public var readingTitle: Font { .system(size: size(22), weight: .semibold, design: .serif) }
    public var paneTitle: Font { .system(size: size(13), weight: .semibold) }
    public var body: Font { .system(size: size(13)) }
    public var callout: Font { .system(size: size(12)) }
    public var caption: Font { .system(size: size(11)) }
    public var label: Font { .system(size: size(12), weight: .medium) }
    /// Page headings and large numbers use the serif, as in a printed page.
    public var display: Font { .system(size: size(28), weight: .semibold, design: .serif) }
    public var stat: Font { .system(size: size(30), design: .serif) }
    /// Small tracked capitals for date and group labels.
    public var eyebrow: Font { .system(size: size(11), weight: .semibold) }
    public var episodeTitle: Font { .system(size: size(17), weight: .semibold, design: .serif) }
    public var nav: Font { .system(size: size(14), weight: .medium) }
    public var timestamp: Font { .system(size: size(11), weight: .medium, design: .monospaced) }
    public var speaker: Font { .system(size: size(12), weight: .semibold) }

    public static let scales: [Double] = [0.85, 1, 1.15, 1.3, 1.5]
}

private struct TypographyKey: EnvironmentKey {
    static let defaultValue = Typography()
}

extension EnvironmentValues {
    public var typography: Typography {
        get { self[TypographyKey.self] }
        set { self[TypographyKey.self] = newValue }
    }
}

/// Pressed controls shrink to 0.96 over 150 ms; disabled ones and Reduce Motion keep their size.
struct PressScale: ViewModifier {
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && isEnabled && !reduceMotion ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: isPressed)
    }
}

/// A raised surface: fill plus two soft shadows instead of a border. Increase Contrast adds a visible edge back.
struct Elevated: ViewModifier {
    var cornerRadius: CGFloat = 14
    var fill: Color = Palette.surface
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .clipShape(shape)
            .background(
                shape.fill(fill)
                    .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                    .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
            )
            .overlay(shape.strokeBorder(contrast == .increased ? Palette.inkMuted : .clear))
    }
}

extension View {
    func pressScale(_ isPressed: Bool) -> some View { modifier(PressScale(isPressed: isPressed)) }
    func elevated(cornerRadius: CGFloat = 14, fill: Color = Palette.surface) -> some View {
        modifier(Elevated(cornerRadius: cornerRadius, fill: fill))
    }
}

/// An animation that becomes none under Reduce Motion.
func motion(_ animation: Animation, reduced: Bool) -> Animation? { reduced ? nil : animation }

/// A rounded pane on the paper background.
struct PaneBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.elevated(cornerRadius: 12)
    }
}

extension View {
    func pane() -> some View { modifier(PaneBackground()) }
}

/// Square icon button used in pane toolbars.
struct IconButtonStyle: ButtonStyle {
    /// Marks a toggle that is on, such as the side pane being shown.
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isActive ? Palette.accent : Palette.ink)
            .frame(width: 30, height: 28)
            .background(isActive ? Palette.accentSoft : (configuration.isPressed ? Palette.rule : Palette.sunken),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .pressScale(configuration.isPressed)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.typography) private var type
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(type.label)
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 14)
            .frame(minHeight: 30)
            .background(Palette.accent.opacity(configuration.isPressed ? 0.85 : 1),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .pressScale(configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.typography) private var type
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(type.label)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 30)
            .background(configuration.isPressed ? Palette.rule : Palette.surface,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.rule))
            .contentShape(Rectangle())
            .pressScale(configuration.isPressed)
    }
}

/// A timestamp that seeks the player.
struct TimestampPill: View {
    let time: Double
    var isActive = false
    let action: () -> Void
    @Environment(\.typography) private var type

    var body: some View {
        Button(action: action) {
            Text(Timecode.format(time))
                .font(type.timestamp)
                .monospacedDigit()
                .foregroundStyle(isActive ? Palette.onAccent : Palette.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(isActive ? Palette.accent : Palette.accentSoft, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Play from \(Timecode.format(time))")
        .accessibilityLabel("Play from \(Timecode.spoken(time))")
    }
}

/// Generated placeholder artwork until a feed's image is downloaded: a wave line over a tinted field.
struct ArtworkView: View {
    let hue: Double
    var cornerRadius: CGFloat = 10

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.42),
                                    Color(hue: hue + 0.06, saturation: 0.35, brightness: 0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            WaveShape()
                .stroke(Color(hue: hue, saturation: 0.15, brightness: 0.95).opacity(0.9),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .padding(.horizontal, cornerRadius * 1.4)
                .padding(.vertical, cornerRadius)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// The wavepod mark: one sound-wave line that settles into a straight page edge.
struct WaveShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let mid = rect.midY
        p.move(to: CGPoint(x: rect.minX, y: mid))
        let steps = 120
        for i in 0...steps {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(steps)
            let t = Double(i) / Double(steps)
            let envelope = max(0, 1 - t * 1.25)
            let y = mid - CGFloat(sin(t * .pi * 7) * envelope) * rect.height * 0.28
            p.addLine(to: CGPoint(x: x, y: y))
        }
        return p
    }
}
