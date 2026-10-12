import AppKit

/// MenuBarExtra has no right-click menu, so catch right-clicks (and control-clicks) on our
/// status item ourselves and show a small menu with Settings and Quit.
@MainActor
enum StatusItemMenu {
    private static var monitor: Any?
    /// Opens the Settings window; set by the SwiftUI side, which owns that action.
    static var openSettings: (() -> Void)?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            // Local monitors are called on the main thread.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { showMenuIfNeeded(for: event) }
            return handled ? nil : event
        }
    }

    /// Opens or closes the remote, as if the icon were clicked (used by the global shortcut).
    static func togglePopover() {
        guard let button = statusButton() else { return }
        NSApp.activate()
        button.performClick(nil)
    }

    /// Returns true when the click was a secondary click on our status item and the menu was shown.
    private static func showMenuIfNeeded(for event: NSEvent) -> Bool {
        let isSecondaryClick = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
        guard isSecondaryClick,
              let window = event.window,
              isStatusBarWindow(window),
              let view = window.contentView
        else { return false }

        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(MenuActions.openSettings), keyEquivalent: ",")
        settings.target = MenuActions.shared
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Clickr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        return true
    }

    private static func isStatusBarWindow(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).contains("StatusBarWindow")
    }

    private static func statusButton() -> NSButton? {
        for window in NSApp.windows where isStatusBarWindow(window) {
            if let button = firstButton(in: window.contentView) { return button }
        }
        return nil
    }

    private static func firstButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton { return button }
        for subview in view.subviews {
            if let button = firstButton(in: subview) { return button }
        }
        return nil
    }

    @MainActor
    private final class MenuActions: NSObject {
        static let shared = MenuActions()

        @objc func openSettings() {
            NSApp.activate()
            if let open = StatusItemMenu.openSettings {
                open()
            } else {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }
}
