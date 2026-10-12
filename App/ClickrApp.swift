import SwiftUI

@main
struct ClickrApp: App {
    @State private var model = RemoteViewModel()

    init() {
        StatusItemMenu.install()
        GlobalShortcut.shared.start()
        #if DEBUG
        IconDump.runIfRequested()
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            RemotePopover(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// The menu bar icon, plus a hook that hands SwiftUI's open-Settings action to the
/// right-click menu (which is AppKit and can't reach the environment itself).
private struct MenuBarLabel: View {
    let model: RemoteViewModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        MenuBarIcon(state: model.connectionState)
            .onAppear {
                StatusItemMenu.openSettings = { openSettings() }
                #if DEBUG
                PreviewWindow.showIfRequested(model: model)
                #endif
            }
    }
}
