import AppKit

/// MenuBarExtra has no right-click menu, so catch right-clicks (and control-clicks) on our
/// status item ourselves and show a small menu with Quit.
@MainActor
enum StatusItemMenu {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            // Local monitors are called on the main thread.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { showMenuIfNeeded(for: event) }
            return handled ? nil : event
        }
    }

    /// Returns true when the click was a secondary click on our status item and the menu was shown.
    private static func showMenuIfNeeded(for event: NSEvent) -> Bool {
        let isSecondaryClick = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
        guard isSecondaryClick,
              let window = event.window,
              String(describing: type(of: window)).contains("StatusBarWindow"),
              let view = window.contentView
        else { return false }

        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit Clickr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        return true
    }
}
