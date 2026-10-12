import Session
import SwiftUI

/// Back, Home and Play/Pause (Section 5.2, item 4).
struct ButtonRow: View {
    let model: RemoteViewModel
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            tile("Back", symbol: "chevron.left", button: .menu)
            tile("Home", symbol: "tv", button: .home, holdForControlCenter: true)
            tile("Play/Pause", symbol: "playpause.fill", button: .playPause, accessibilityLabel: "Play or pause")
        }
    }

    private func tile(
        _ title: String,
        symbol: String,
        button: RemoteButton,
        holdForControlCenter: Bool = false,
        accessibilityLabel: String? = nil
    ) -> some View {
        HoldableButton {
            model.press(button)
        } holdAction: {
            // Holding Home opens Control Center on the TV; other buttons just press.
            model.press(button, hold: holdForControlCenter)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(theme.primaryText)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.isGlass ? Color.white.opacity(0.86) : Color(hex: 0xD1D1D6))
            }
            .frame(maxWidth: .infinity)
            .frame(height: theme.isGlass ? 60 : 58)
            .contentShape(Rectangle())
        }
        .controlButtonStyle(theme, radius: theme.isGlass ? 22 : 14, fallbackFill: RemoteTheme.fallbackControl)
        .accessibilityLabel(accessibilityLabel ?? title)
    }
}

/// Volume down and up around a label (Section 5.2, item 5).
struct VolumePill: View {
    let model: RemoteViewModel
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            volumeButton(symbol: "minus", button: .volumeDown, label: "Volume down")
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.1")
                    .font(.system(size: 18))
                Text("Volume")
                    .font(.system(size: 13))
            }
            .foregroundStyle(theme.isGlass ? Color.white.opacity(0.88) : theme.primaryText)
            Spacer(minLength: 0)
            volumeButton(symbol: "plus", button: .volumeUp, label: "Volume up")
        }
        .padding(.horizontal, 4)
        .frame(height: theme.isGlass ? 48 : 44)
        .surface(theme, in: RoundedRectangle(cornerRadius: theme.isGlass ? 24 : 14, style: .continuous),
                 glassTint: 0.12, fallbackFill: RemoteTheme.fallbackControl, edge: nil)
    }

    private func volumeButton(symbol: String, button: RemoteButton, label: String) -> some View {
        RepeatButton {
            model.press(button)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(theme.primaryText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}

/// "Type on the TV". Shown but disabled until text input lands (Milestone 9).
struct TypeOnTVField: View {
    @Environment(\.remoteTheme) private var theme
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Type on the TV")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)

            let shape = RoundedRectangle(cornerRadius: theme.isGlass ? 19 : 10, style: .continuous)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, theme.isGlass ? 16 : 12)
                .frame(height: theme.isGlass ? 38 : 36)
                .background(theme.isGlass ? Color.black.opacity(0.24) : Color(hex: 0x1F1F23), in: shape)
                .overlay(shape.stroke(theme.border(theme.isGlass ? 0.22 : 0.14), lineWidth: 1))
                .disabled(true)
        }
    }
}

/// The keyboard hint at the bottom (Section 5.2, item 7).
struct FooterHint: View {
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        Text("Keyboard works too: arrow keys move, Return selects, Esc goes back, Space plays or pauses.")
            .font(.system(size: 11))
            .foregroundStyle(theme.secondaryText)
            .multilineTextAlignment(.center)
            .lineSpacing(3) // 11 pt text normally sits on ~13 pt lines; 3 more gives about 1.45
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Button behaviors

/// A button with a separate action for a long press (held 0.6 s). Used for Home and Select,
/// which hold the key down on the TV.
struct HoldableButton<Label: View>: View {
    let action: () -> Void
    let holdAction: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var didHold = false

    var body: some View {
        Button {
            if didHold {
                didHold = false
            } else {
                action()
            }
        } label: {
            label()
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.6).onEnded { _ in
                didHold = true
                holdAction()
            }
        )
    }
}

/// Fires once when pressed, then every 150 ms while held.
struct RepeatButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: {}, label: label)
            .buttonStyle(RepeatingStyle(action: action))
            // VoiceOver presses don't go through isPressed, so give them the action directly.
            .accessibilityAction { action() }
    }

    private struct RepeatingStyle: ButtonStyle {
        let action: () -> Void

        func makeBody(configuration: Configuration) -> some View {
            RepeatingLabel(isPressed: configuration.isPressed, action: action) {
                configuration.label
            }
        }
    }

    private struct RepeatingLabel<Content: View>: View {
        let isPressed: Bool
        let action: () -> Void
        @ViewBuilder let content: () -> Content
        @State private var repeater: Task<Void, Never>?

        var body: some View {
            content()
                .opacity(isPressed ? 0.6 : 1)
                .onChange(of: isPressed) { _, pressed in
                    repeater?.cancel()
                    guard pressed else { return }
                    repeater = Task { @MainActor in
                        action()
                        while true {
                            try? await Task.sleep(for: .milliseconds(150))
                            guard !Task.isCancelled else { return }
                            action()
                        }
                    }
                }
        }
    }
}
