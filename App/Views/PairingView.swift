import AppKit
import SwiftUI

/// First-time pairing: the TV shows a code and the user types it here (Section 5.4).
struct PairingView: View {
    let model: RemoteViewModel
    let deviceName: String
    @Environment(\.remoteTheme) private var theme

    @State private var digits = ""
    @State private var isVerifying = false
    @State private var shakes: CGFloat = 0
    @FocusState private var pinFocused: Bool

    private static let pairBlue = Color(red: 10 / 255, green: 100 / 255, blue: 235 / 255).opacity(0.85)

    var body: some View {
        VStack(spacing: 16) {
            badge

            Text("Pair with \(deviceName)")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.primaryText)

            Text(model.pairingFailed ? "That code didn't match. Try again." : "Enter the 4-digit code shown on your TV.")
                .font(.system(size: 13))
                .foregroundStyle(theme.isGlass ? Color.white.opacity(0.8) : theme.secondaryText)

            pinBoxes
                .modifier(ShakeEffect(shakes: shakes))

            pairButton

            Button {
                model.cancelPairing()
            } label: {
                Text("Cancel")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: 0xA9D2FF))
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("You only do this once. The pairing key stays in your Mac's Keychain.")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .popoverContainer(theme, width: 308, padding: 24)
        .onAppear { pinFocused = true }
    }

    private var badge: some View {
        Image("RemoteIcon")
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(theme.primaryText)
            .frame(width: 17, height: 29)
            .frame(width: 56, height: 56)
            .surface(theme, in: Circle(), glassTint: 0.14, fallbackFill: .white.opacity(0.14), edge: 0.24)
            .accessibilityHidden(true)
    }

    private var pinBoxes: some View {
        HStack(spacing: 10) {
            ForEach(0..<4, id: \.self) { index in
                PINBox(
                    digit: index < digits.count ? String(Array(digits)[index]) : "",
                    isFocused: pinFocused && index == min(digits.count, 3),
                    theme: theme
                )
            }
        }
        .focusable()
        .focused($pinFocused)
        .focusEffectDisabled()
        .onKeyPress(characters: .decimalDigits, phases: [.down, .repeat]) { press in
            guard digits.count < 4, !isVerifying else { return .handled }
            digits.append(press.characters)
            return .handled
        }
        .onKeyPress(.delete) {
            if !digits.isEmpty, !isVerifying { digits.removeLast() }
            return .handled
        }
        .onKeyPress(.return) {
            submit()
            return .handled
        }
        .onPasteCommand(of: [.plainText]) { _ in
            let pasted = (NSPasteboard.general.string(forType: .string) ?? "").filter(\.isNumber)
            if pasted.count == 4 { digits = pasted }
        }
        .accessibilityElement()
        .accessibilityLabel("Pairing code")
        .accessibilityValue("\(digits.count) of 4 digits entered")
    }

    @ViewBuilder
    private var pairButton: some View {
        let button = Button(action: submit) {
            ZStack {
                if isVerifying {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Pair").font(.system(size: 14, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Capsule())
        }
        .disabled(digits.count < 4 || isVerifying)

        if theme.isGlass, #available(macOS 26, *) {
            button.buttonStyle(GlassControlStyle(tint: Self.pairBlue))
        } else {
            button.buttonStyle(FilledButtonStyle(fill: Self.pairBlue, radius: nil))
        }
    }

    private func submit() {
        guard digits.count == 4, !isVerifying else { return }
        isVerifying = true
        Task {
            let accepted = await model.submitPIN(digits)
            isVerifying = false
            if !accepted {
                withAnimation(.linear(duration: 0.4)) { shakes += 1 }
                digits = ""
            }
        }
    }
}

private struct PINBox: View {
    let digit: String
    let isFocused: Bool
    let theme: RemoteTheme

    private static let focusBlue = Color(hex: 0x4DA3FF)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        Text(digit)
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(theme.primaryText)
            .frame(width: 54, height: 62)
            .background(Color.black.opacity(0.26), in: shape)
            .overlay {
                if isFocused {
                    shape.strokeBorder(Self.focusBlue, lineWidth: 2)
                } else {
                    shape.strokeBorder(theme.border(0.26), lineWidth: 1)
                }
            }
            .overlay {
                if isFocused {
                    // 3 pt ring just outside the box.
                    RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .strokeBorder(Self.focusBlue.opacity(0.28), lineWidth: 3)
                        .padding(-3)
                }
            }
    }
}

/// Side-to-side shake for a wrong code. Each increment of `shakes` plays one shake.
private struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(shakes * .pi * 6), y: 0))
    }
}
