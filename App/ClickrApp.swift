import SwiftUI

@main
struct ClickrApp: App {
    @State private var model = RemoteViewModel()

    var body: some Scene {
        MenuBarExtra {
            RemotePopover(model: model)
        } label: {
            MenuBarIcon()
        }
        .menuBarExtraStyle(.window)
    }
}
