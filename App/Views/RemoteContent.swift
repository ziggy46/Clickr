import SwiftUI

/// The remote's sections in order. Shared by the Glass and Fallback designs, which only
/// differ in their container and the theme values.
struct RemoteContent: View {
    let model: RemoteViewModel
    @Environment(\.remoteTheme) private var theme
    @AppStorage(AppSettings.showKeyboardHint) private var showKeyboardHint = true

    var body: some View {
        VStack(spacing: theme.spacing) {
            DeviceHeader(model: model)
            if let nowPlaying = model.nowPlaying {
                NowPlayingCard(nowPlaying: nowPlaying, artwork: model.artwork)
            }
            Group {
                Clickpad(model: model)
                ButtonRow(model: model)
                VolumePill(model: model)
                TypeOnTVField(model: model)
            }
            .disabled(!hasDevice)
            .opacity(hasDevice ? 1 : 0.4)
            if showKeyboardHint {
                FooterHint()
            }
        }
    }

    private var hasDevice: Bool { model.selectedDevice != nil }
}

extension View {
    /// The popover background.
    ///
    /// On macOS 26 the menu bar window already draws its own glass behind our content, and
    /// clearing the window background doesn't remove it, so drawing a second glass panel
    /// gave doubled corners. The glass design therefore uses the system's glass as the
    /// container and only sets the size. On 14 and 15 we draw the flat fallback panel.
    @ViewBuilder
    func popoverContainer(_ theme: RemoteTheme, width: CGFloat, padding: CGFloat) -> some View {
        let sized = self.padding(padding).frame(width: width)
        if theme.isGlass {
            sized
        } else {
            let shape = RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
            sized
                .background(RemoteTheme.fallbackBackground, in: shape)
                .overlay(shape.stroke(theme.border(0.10), lineWidth: 1))
        }
    }
}
