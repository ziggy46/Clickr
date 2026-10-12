import SwiftUI

/// Which of the two designs to draw, plus the accessibility tweaks from Section 5.7.
struct RemoteTheme {
    enum Design {
        /// macOS 26 and later (Section 5.2).
        case glass
        /// macOS 14 and 15, or Reduce Transparency on 26 (Section 5.3).
        case fallback
    }

    var design: Design
    /// Increase Contrast turns every border to white 50%.
    var increasedContrast: Bool

    var isGlass: Bool { design == .glass }

    // Container
    var width: CGFloat { isGlass ? 308 : 300 }
    var padding: CGFloat { isGlass ? 18 : 16 }
    var cornerRadius: CGFloat { isGlass ? 28 : 14 }
    let spacing: CGFloat = 14

    // Text
    var primaryText: Color { isGlass ? .white : Color(hex: 0xF5F5F7) }
    var secondaryText: Color { isGlass ? .white.opacity(0.78) : Color(hex: 0xA1A1A6) }
    var deviceNameSize: CGFloat { isGlass ? 16 : 15 }

    func border(_ opacity: Double) -> Color {
        .white.opacity(increasedContrast ? 0.5 : opacity)
    }

    // Fallback fills
    static let fallbackBackground = Color(hex: 0x2B2B30)
    static let fallbackControl = Color(hex: 0x3A3A3F)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// The system accent color lightened for text on the dark remote, the way the original
    /// light blue (#A9D2FF) sat on blue. Mixing needs macOS 15; before that it's the plain
    /// accent color.
    static var accentText: Color {
        if #available(macOS 15, *) {
            Color.accentColor.mix(with: .white, by: 0.6)
        } else {
            Color.accentColor
        }
    }

    static let statusConnected = Color(hex: 0x30D158)
    static let statusConnecting = Color(hex: 0x8E8E93)
    static let statusDisconnected = Color(hex: 0xFF453A)
}

private struct RemoteThemeKey: EnvironmentKey {
    static let defaultValue = RemoteTheme(design: .fallback, increasedContrast: false)
}

extension EnvironmentValues {
    var remoteTheme: RemoteTheme {
        get { self[RemoteThemeKey.self] }
        set { self[RemoteThemeKey.self] = newValue }
    }
}

extension View {
    /// A surface that is system glass in the glass design and a flat fill in the fallback.
    /// `glassTint` is the white opacity layered into the glass.
    @ViewBuilder
    func surface(
        _ theme: RemoteTheme,
        in shape: some Shape,
        glassTint: Double,
        fallbackFill: Color,
        edge: Double?
    ) -> some View {
        let bordered = overlay {
            if let edge {
                shape.stroke(theme.border(edge), lineWidth: 1)
            }
        }
        if theme.isGlass, #available(macOS 26, *) {
            bordered.glassEffect(.regular.tint(.white.opacity(glassTint)), in: shape)
        } else {
            bordered.background(fallbackFill, in: shape)
        }
    }

    /// `.glass` button style in the glass design, a flat filled button in the fallback.
    /// A nil radius means fully rounded (circle or capsule).
    @ViewBuilder
    func controlButtonStyle(_ theme: RemoteTheme, radius: CGFloat?, fallbackFill: Color) -> some View {
        if theme.isGlass, #available(macOS 26, *) {
            buttonStyle(GlassControlStyle(radius: radius))
        } else {
            buttonStyle(FilledButtonStyle(fill: fallbackFill, radius: radius))
        }
    }
}

/// Flat button for the fallback design: a fill that dims slightly while pressed.
struct FilledButtonStyle: ButtonStyle {
    var fill: Color
    /// nil means fully rounded.
    var radius: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        // A radius larger than half the height just rounds the ends fully.
        let shape = RoundedRectangle(cornerRadius: radius ?? 1000, style: .continuous)
        configuration.label
            .background(fill.opacity(configuration.isPressed ? 0.7 : 1), in: shape)
            .contentShape(shape)
            .modifier(DimWhenDisabled())
    }
}

/// Custom button styles don't dim themselves when disabled, so do it here.
struct DimWhenDisabled: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.opacity(isEnabled ? 1 : 0.45)
    }
}

/// System glass sized exactly to the label. `.buttonStyle(.glass)` adds about 4 pt of padding
/// on every side, which would make the Section 5 sizes come out wrong (an 88 pt OK button
/// renders at 96), so the glass is applied directly instead.
@available(macOS 26, *)
struct GlassControlStyle: ButtonStyle {
    /// nil means fully rounded (circle or capsule).
    var radius: CGFloat?
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? 1000, style: .continuous)
        configuration.label
            .contentShape(shape)
            .glassEffect(.regular.tint(tint).interactive(), in: shape)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .modifier(DimWhenDisabled())
    }
}
