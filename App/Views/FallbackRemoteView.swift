import SwiftUI

/// The macOS 14 and 15 design (Section 5.3), also used with Reduce Transparency on 26.
struct FallbackRemoteView: View {
    let model: RemoteViewModel
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        RemoteContent(model: model)
            .popoverContainer(theme, width: theme.width, padding: theme.padding)
    }
}
