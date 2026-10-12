import SwiftUI

/// The remote's sections in order. Shared by the Glass and Fallback designs, which only
/// differ in their container and the theme values.
struct RemoteContent: View {
    let model: RemoteViewModel
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        VStack(spacing: theme.spacing) {
            DeviceHeader(model: model)
            // Now Playing (Milestone 10) stays hidden until it has real data.
            Group {
                Clickpad(model: model)
                ButtonRow(model: model)
                VolumePill(model: model)
                TypeOnTVField()
            }
            .disabled(!hasDevice)
            .opacity(hasDevice ? 1 : 0.4)
            FooterHint()
        }
    }

    private var hasDevice: Bool { model.selectedDevice != nil }
}

extension View {
    /// The popover background: system glass on macOS 26, a flat panel on 14 and 15.
    @ViewBuilder
    func popoverContainer(_ theme: RemoteTheme, width: CGFloat, padding: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
        let content = self.padding(padding).frame(width: width)
        if theme.isGlass, #available(macOS 26, *) {
            content.glassEffect(
                .regular.tint(Color(red: 20 / 255, green: 26 / 255, blue: 40 / 255).opacity(0.5)),
                in: shape
            )
            .overlay {
                // The system glass draws its own edge, so only add one for Increase Contrast.
                if theme.increasedContrast {
                    shape.stroke(theme.border(0.24), lineWidth: 1)
                }
            }
        } else {
            content
                .background(RemoteTheme.fallbackBackground, in: shape)
                .overlay(shape.stroke(theme.border(0.10), lineWidth: 1))
        }
    }
}
