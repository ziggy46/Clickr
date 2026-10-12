import SwiftUI

@main
struct ClickrApp: App {
    @State private var model = RemoteViewModel()

    init() {
        StatusItemMenu.install()
    }

    var body: some Scene {
        MenuBarExtra {
            RemotePopover(model: model)
        } label: {
            MenuBarIcon()
        }
        .menuBarExtraStyle(.window)
    }
}
