import Foundation

/// Clickr 0.1.x ran in the App Sandbox, which keeps preferences inside the app's container.
/// 0.2.0 dropped the sandbox so it can update itself, and now reads the normal preferences
/// file instead. This copies the old settings across once, so updating doesn't reset the
/// default TV, the shortcut and so on.
enum SandboxPreferences {
    private static let migratedKey = "MigratedSandboxPreferences"

    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey),
              ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil,
              let bundleID = Bundle.main.bundleIdentifier
        else { return }
        // Only ever try once, even if the old file can't be read.
        defaults.set(true, forKey: migratedKey)

        let home = FileManager.default.homeDirectoryForCurrentUser
        let oldFile = home.appending(path: "Library/Containers/\(bundleID)/Data/Library/Preferences/\(bundleID).plist")
        guard let old = NSDictionary(contentsOf: oldFile) as? [String: Any] else { return }
        // Compare with the new file itself. object(forKey:) also sees launch arguments, and
        // persistentDomain(forName:) can mix in the container's values.
        let newFile = home.appending(path: "Library/Preferences/\(bundleID).plist")
        let saved = NSDictionary(contentsOf: newFile) as? [String: Any] ?? [:]
        for (key, value) in old where saved[key] == nil {
            defaults.set(value, forKey: key)
        }
    }
}
