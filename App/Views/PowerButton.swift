import AppKit
import SwiftUI

/// Hold for a second to put the TV to sleep, or to wake it. A ring fills while held, so an
/// accidental click does nothing. After the hold, the ring pulses until the TV reports its
/// new state, then fades with a small bounce; if the TV doesn't confirm, it shakes.
struct PowerButton: View {
    let model: RemoteViewModel
    @Environment(\.remoteTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var progress: CGFloat = 0
    @State private var pulse = false
    @State private var bounce = false
    @State private var shakes: CGFloat = 0

    private static let holdDuration = 1.0

    var body: some View {
        Image(systemName: "power")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(iconColor)
            .scaleEffect(bounce ? 1.18 : 1)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
            .modifier(PowerButtonBackground(theme: theme))
            .overlay {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(1)
                    .opacity(pulse ? 0.35 : 1)
            }
            .modifier(Shake(shakes: shakes))
            .opacity(isEnabled ? 1 : 0.4)
            .onLongPressGesture(minimumDuration: Self.holdDuration) {
                model.togglePower()
            } onPressingChanged: { pressing in
                if pressing {
                    withAnimation(.linear(duration: Self.holdDuration)) { progress = 1 }
                } else if !model.powerChangePending {
                    // Let go too early: nothing happens.
                    withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
                }
            }
            .onChange(of: model.powerChangePending) { _, pending in
                if pending {
                    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true }
                } else {
                    withAnimation(.easeOut(duration: 0.3)) {
                        pulse = false
                        progress = 0
                    }
                }
            }
            .onChange(of: model.powerConfirmations) {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { bounce = true }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6).delay(0.15)) { bounce = false }
            }
            .onChange(of: model.powerFailures) {
                withAnimation(.linear(duration: 0.4)) { shakes += 1 }
            }
            .accessibilityElement()
            .accessibilityLabel("Power")
            .accessibilityValue(model.isAsleep ? "Asleep" : "Awake")
            .accessibilityHint(model.isAsleep ? "Wakes the Apple TV" : "Puts the Apple TV to sleep")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.togglePower() }
    }

    /// Dimmed while the TV sleeps.
    private var iconColor: Color {
        let base = theme.isGlass ? theme.primaryText : theme.secondaryText
        return model.isAsleep ? base.opacity(0.45) : base
    }
}

/// Same look as the TV switcher: a glass circle, or flat in the fallback design.
private struct PowerButtonBackground: ViewModifier {
    let theme: RemoteTheme

    func body(content: Content) -> some View {
        if theme.isGlass, #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
        }
    }
}

/// Side-to-side shake; each increment of `shakes` plays one.
private struct Shake: GeometryEffect {
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 4 * sin(shakes * .pi * 6), y: 0))
    }
}
