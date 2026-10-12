import Session
import SwiftUI

/// The round directional pad with OK in the middle (Section 5.2, item 3).
struct Clickpad: View {
    let model: RemoteViewModel
    @Environment(\.remoteTheme) private var theme
    /// Whether the current drag already sent its direction.
    @State private var swipeSent = false
    @AppStorage(AppSettings.trackpadSwipes) private var trackpadSwipes = true

    private var diameter: CGFloat { theme.isGlass ? 224 : 220 }
    private var arrowSize: CGFloat { theme.isGlass ? 46 : 44 }
    private var inset: CGFloat { theme.isGlass ? 7 : 6 }
    private var okDiameter: CGFloat { theme.isGlass ? 88 : 84 }

    var body: some View {
        ZStack {
            Color.clear
                .surface(theme, in: Circle(), glassTint: 0.10, fallbackFill: Color(hex: 0x353539),
                         edge: theme.isGlass ? 0.24 : 0.08)

            let edgeOffset = diameter / 2 - inset - arrowSize / 2
            arrow(.up, symbol: "chevron.up", label: "Up").offset(y: -edgeOffset)
            arrow(.down, symbol: "chevron.down", label: "Down").offset(y: edgeOffset)
            arrow(.left, symbol: "chevron.left", label: "Left").offset(x: -edgeOffset)
            arrow(.right, symbol: "chevron.right", label: "Right").offset(x: edgeOffset)

            okButton
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .simultaneousGesture(swipe)
        .modifier(TrackpadSwipes(model: model, isEnabled: trackpadSwipes))
    }

    private func arrow(_ button: RemoteButton, symbol: String, label: String) -> some View {
        Button {
            model.press(button)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .frame(width: arrowSize, height: arrowSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var okButton: some View {
        let button = HoldableButton {
            model.press(.select)
        } holdAction: {
            model.press(.select, hold: true)
        } label: {
            Text("OK")
                .font(.system(size: theme.isGlass ? 16 : 15, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .frame(width: okDiameter, height: okDiameter)
                .contentShape(Circle())
        }
        .accessibilityLabel("Select")

        if theme.isGlass, #available(macOS 26, *) {
            button.buttonStyle(GlassControlStyle(tint: Color.accentColor.opacity(0.62)))
        } else {
            button.buttonStyle(FilledButtonStyle(fill: Color.accentColor.opacity(0.85), radius: nil))
        }
    }

    /// A drag of 30 pt or more on the pad sends one press in the drag's main direction.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { drag in
                guard !swipeSent else { return }
                let dx = drag.translation.width
                let dy = drag.translation.height
                guard max(abs(dx), abs(dy)) >= 30 else { return }
                swipeSent = true
                if abs(dx) > abs(dy) {
                    model.press(dx > 0 ? .right : .left)
                } else {
                    model.press(dy > 0 ? .down : .up)
                }
            }
            .onEnded { _ in swipeSent = false }
    }
}
