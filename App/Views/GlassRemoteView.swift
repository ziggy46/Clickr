import SwiftUI

/// The macOS 26 design (Section 5.2). RemotePopover wraps it in a GlassEffectContainer.
@available(macOS 26, *)
struct GlassRemoteView: View {
    let model: RemoteViewModel
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        RemoteContent(model: model)
            .popoverContainer(theme, width: theme.width, padding: theme.padding)
    }
}
