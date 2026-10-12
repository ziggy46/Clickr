import AppKit
import Observation
import os
import Updates

/// Checks GitHub Releases for a newer Clickr. Asks once whether to check automatically;
/// when allowed, checks at most once a day. Only GitHub's public API is contacted, and the
/// only thing sent is the request itself (with "Clickr/<version>" as the User-Agent).
@MainActor
@Observable
final class UpdateController {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case noReleases
        case available(Release)
        case failed(String)
    }

    static let repository = "ziggy46/Clickr"

    private(set) var status: Status = .idle
    private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: Keys.lastChecked) as? Date

    var checksAutomatically: Bool = UserDefaults.standard.bool(forKey: Keys.automatic) {
        didSet {
            UserDefaults.standard.set(checksAutomatically, forKey: Keys.automatic)
            UserDefaults.standard.set(true, forKey: Keys.choiceMade)
            if checksAutomatically { checkIfDue() }
        }
    }

    let currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private var started = false
    private var schedule: Task<Void, Never>?
    private let log = Logger(subsystem: "com.ziggy46.clickr", category: "Updates")

    private enum Keys {
        static let automatic = "AutomaticUpdateChecks"
        static let choiceMade = "UpdateCheckChoiceMade"
        static let lastChecked = "LastUpdateCheck"
    }

    var availableRelease: Release? {
        if case .available(let release) = status { release } else { nil }
    }

    /// Called once at launch: asks the first-run question, then keeps the daily schedule.
    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        if PreviewOverrides.current != nil { return }
        #endif
        if !UserDefaults.standard.bool(forKey: Keys.choiceMade) {
            Task {
                // Let the app settle (and any Local Network prompt appear) first.
                try? await Task.sleep(for: .seconds(3))
                askAboutAutomaticChecks()
            }
        }
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkIfDue()
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    func checkNow() {
        guard status != .checking else { return }
        status = .checking
        Task {
            let checker = ReleaseChecker(repository: Self.repository, currentVersion: AppVersion(currentVersion) ?? AppVersion("0")!)
            do {
                switch try await checker.check() {
                case .upToDate: status = .upToDate
                case .noReleases: status = .noReleases
                case .available(let release):
                    log.info("Update available: \(release.version.description, privacy: .public)")
                    status = .available(release)
                }
                lastChecked = Date()
                UserDefaults.standard.set(lastChecked, forKey: Keys.lastChecked)
            } catch {
                log.error("Update check failed: \(String(describing: error), privacy: .public)")
                status = .failed("Couldn't reach GitHub.")
            }
            StatusItemMenu.availableUpdate = availableRelease
        }
    }

    func openReleasePage() {
        let url = availableRelease?.pageURL ?? URL(string: "https://github.com/\(Self.repository)/releases")!
        NSWorkspace.shared.open(url)
    }

    private func checkIfDue() {
        guard checksAutomatically else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 24 * 60 * 60, status != .idle { return }
        checkNow()
    }

    private func askAboutAutomaticChecks() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Check for updates automatically?"
        alert.informativeText = "Clickr can check GitHub once a day for a new version. It only asks GitHub for the latest version number; nothing about you or your Apple TV is sent. You can change this anytime in Settings."
        alert.addButton(withTitle: "Check Automatically")
        alert.addButton(withTitle: "Don't Check")
        checksAutomatically = alert.runModal() == .alertFirstButtonReturn
    }
}
