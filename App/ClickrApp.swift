import SwiftUI

@main
struct ClickrApp: App {
    // Stored properties are set up in order, so this runs before anything below reads a setting.
    private let preferencesMigrated: Void = SandboxPreferences.migrateIfNeeded()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = RemoteViewModel()
    @State private var updates = UpdateController()
    @AppStorage(AppSettings.hideIconWithoutAppleTV) private var hideIconWithoutAppleTV = false

    init() {
        StatusItemMenu.install()
        GlobalShortcut.shared.start()
        #if DEBUG
        IconDump.runIfRequested()
        #endif
    }

    var body: some Scene {
        MenuBarExtra(isInserted: iconIsShown) {
            RemotePopover(model: model)
        } label: {
            MenuBarLabel(model: model, updates: updates)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model, updates: updates)
        }
        .windowResizability(.contentSize)
    }

    private var iconIsShown: Binding<Bool> {
        Binding(
            get: { !(hideIconWithoutAppleTV && model.noAppleTVFound) },
            set: { _ in }
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opening Clickr while it's already running shows Settings. That's the way back when
    /// the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated { StatusItemMenu.showSettings() }
        return false
    }
}

/// The menu bar icon, plus a hook that hands SwiftUI's open-Settings action to the
/// right-click menu (which is AppKit and can't reach the environment itself).
private struct MenuBarLabel: View {
    let model: RemoteViewModel
    let updates: UpdateController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        MenuBarIcon(state: model.connectionState)
            .onAppear {
                StatusItemMenu.openSettings = { openSettings() }
                StatusItemMenu.showUpdate = { updates.presentAvailableUpdate() }
                updates.start()
                #if DEBUG
                PreviewWindow.showIfRequested(model: model)
                if UserDefaults.standard.bool(forKey: "ClickrPreviewOpenSettings") {
                    StatusItemMenu.showSettings()
                }
                #endif
            }
    }
}
