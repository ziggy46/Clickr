import SwiftUI

/// Hold for a second to put the TV to sleep, or to wake it. A ring fills while held so an
/// accidental click does nothing.
struct PowerButton: View {
    let model: RemoteViewModel
    @Environment(\.remoteTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var progress: CGFloat = 0

    private static let holdDuration = 1.0

    var body: some View {
        Image(systemName: "power")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(theme.isGlass ? theme.primaryText : theme.secondaryText)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
            .modifier(PowerButtonBackground(theme: theme))
            .overlay {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(1)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .onLongPressGesture(minimumDuration: Self.holdDuration) {
                model.togglePower()
            } onPressingChanged: { pressing in
                withAnimation(pressing ? .linear(duration: Self.holdDuration) : .easeOut(duration: 0.2)) {
                    progress = pressing ? 1 : 0
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Power")
            .accessibilityHint(model.isAsleep ? "Wakes the Apple TV" : "Puts the Apple TV to sleep")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.togglePower() }
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
