import SwiftUI

@main
struct ClickrApp: App {
    var body: some Scene {
        MenuBarExtra {
            RemotePopover()
        } label: {
            MenuBarIcon()
        }
        .menuBarExtraStyle(.window)
    }
}
