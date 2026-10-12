import SwiftUI

@main
struct ClickrApp: App {
    @State private var model = RemoteViewModel()

    init() {
        StatusItemMenu.install()
        #if DEBUG
        IconDump.runIfRequested()
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            RemotePopover(model: model)
        } label: {
            MenuBarIcon(state: model.connectionState)
                #if DEBUG
                .onAppear { PreviewWindow.showIfRequested(model: model) }
                #endif
        }
        .menuBarExtraStyle(.window)
    }
}
