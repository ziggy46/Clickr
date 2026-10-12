import AppKit
import Observation
import os
import Updates

/// Checks GitHub Releases for a newer Clickr. Asks once whether to check automatically;
/// when allowed, checks at most once a day. Only GitHub's public API is contacted, and the
/// only thing sent is the request itself (with "Clickr/<version>" as the User-Agent).
/// Installing an update downloads it from the release, and with automatic installs on that
/// happens in the background, restarting Clickr while it isn't in use.
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

    enum InstallState: Equatable {
        case idle
        case preparing
        /// Downloaded and checked; waiting for Clickr to be idle before restarting.
        case waitingToRestart
        case failed(String)
    }

    static let repository = "ziggy46/Clickr"

    private(set) var status: Status = .idle
    private(set) var installState: InstallState = .idle
    private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: Keys.lastChecked) as? Date

    var checksAutomatically: Bool = UserDefaults.standard.bool(forKey: Keys.automatic) {
        didSet {
            UserDefaults.standard.set(checksAutomatically, forKey: Keys.automatic)
            UserDefaults.standard.set(true, forKey: Keys.choiceMade)
            if checksAutomatically { checkIfDue() }
        }
    }

    var installsAutomatically: Bool = UserDefaults.standard.bool(forKey: Keys.autoInstall) {
        didSet {
            UserDefaults.standard.set(installsAutomatically, forKey: Keys.autoInstall)
            if installsAutomatically { installAutomaticallyIfPossible() }
        }
    }

    let currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private var started = false
    private var schedule: Task<Void, Never>?
    private var preparedUpdate: UpdateInstaller.PreparedUpdate?
    private var idleObserver: NSObjectProtocol?
    private let launchedAt = Date()
    private let log = Logger(subsystem: "com.ziggy46.clickr", category: "Updates")

    private enum Keys {
        static let automatic = "AutomaticUpdateChecks"
        static let choiceMade = "UpdateCheckChoiceMade"
        static let lastChecked = "LastUpdateCheck"
        static let autoInstall = "AutomaticallyInstallUpdates"
    }

    private var installer: UpdateInstaller {
        UpdateInstaller(currentVersion: AppVersion(currentVersion) ?? AppVersion("0")!)
    }

    /// Whether the available update can be installed from inside Clickr.
    var canInstallAvailableUpdate: Bool {
        availableRelease.map(installer.canInstall) ?? false
    }

    /// Why updates can't be installed from inside Clickr, when that's down to where it is.
    var installBlocker: String? { installer.blocker }

    var availableRelease: Release? {
        if case .available(let release) = status { release } else { nil }
    }

    /// Called once at launch: asks the first-run question, then keeps the daily schedule.
    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        // Previews never check, unless testing an install from a local folder.
        if PreviewOverrides.current != nil, UserDefaults.standard.string(forKey: "ClickrUpdateFeed") == nil { return }
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
        if case .failed = installState { installState = .idle }
        Task {
            #if DEBUG
            if let release = Self.localTestRelease() {
                status = .available(release)
                StatusItemMenu.availableUpdate = release
                installAutomaticallyIfPossible()
                return
            }
            #endif
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
            installAutomaticallyIfPossible()
        }
    }

    /// The right-click menu's "Update Available" item.
    func presentAvailableUpdate() {
        guard let release = availableRelease else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Clickr \(release.version) is available"
        if canInstallAvailableUpdate {
            alert.informativeText = "You have \(currentVersion). Clickr will restart to finish installing."
            alert.addButton(withTitle: "Install and Restart")
            alert.addButton(withTitle: "Release Notes")
            alert.addButton(withTitle: "Later")
            switch alert.runModal() {
            case .alertFirstButtonReturn: installNow()
            case .alertSecondButtonReturn: openReleasePage()
            default: break
            }
        } else {
            let reason = installBlocker.map { " \($0)" } ?? ""
            alert.informativeText = "You have \(currentVersion). Download the new version from GitHub.\(reason)"
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn { openReleasePage() }
        }
    }

    /// "Install and Restart": downloads (unless that's already done) and restarts right away.
    func installNow() {
        guard let release = availableRelease, installState != .preparing else { return }
        if let preparedUpdate, preparedUpdate.version == release.version {
            restart(into: preparedUpdate)
            return
        }
        Task {
            if let update = await prepare(release) { restart(into: update) }
        }
    }

    private func installAutomaticallyIfPossible() {
        guard installsAutomatically, checksAutomatically,
              let release = availableRelease, installer.canInstall(release),
              installState == .idle
        else { return }
        Task {
            guard await prepare(release) != nil else { return }
            installState = .waitingToRestart
            restartWhenIdle()
        }
    }

    private func prepare(_ release: Release) async -> UpdateInstaller.PreparedUpdate? {
        installState = .preparing
        do {
            let update = try await installer.prepare(release)
            if let old = preparedUpdate { installer.discard(old) }
            preparedUpdate = update
            installState = .idle
            return update
        } catch {
            log.error("Couldn't prepare the update: \(String(describing: error), privacy: .public)")
            installState = .failed(error.localizedDescription)
            return nil
        }
    }

    /// Restarts once Clickr isn't in use: not in front (the remote and Settings are closed)
    /// and not just launched. Checks again whenever Clickr goes to the background.
    private func restartWhenIdle() {
        guard installState == .waitingToRestart, let preparedUpdate else { return }
        let settled = Date().timeIntervalSince(launchedAt) > 60
        if settled && !NSApp.isActive {
            restart(into: preparedUpdate)
            return
        }
        if idleObserver == nil {
            idleObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.restartWhenIdle() }
            }
        }
        if !settled {
            Task {
                try? await Task.sleep(for: .seconds(61))
                restartWhenIdle()
            }
        }
    }

    private func restart(into update: UpdateInstaller.PreparedUpdate) {
        do {
            try installer.installAndRelaunch(update)
        } catch {
            log.error("Couldn't start installing: \(String(describing: error), privacy: .public)")
            installState = .failed(error.localizedDescription)
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
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Also install updates automatically"
        alert.suppressionButton?.state = .off
        let checks = alert.runModal() == .alertFirstButtonReturn
        installsAutomatically = checks && alert.suppressionButton?.state == .on
        checksAutomatically = checks
    }

    #if DEBUG
    /// For testing installs without GitHub: `-ClickrUpdateFeed <folder>` treats a folder
    /// holding Clickr-<version>-<variant>.dmg files and SIGNATURES.txt as the latest release.
    private static func localTestRelease() -> Release? {
        guard let folder = UserDefaults.standard.string(forKey: "ClickrUpdateFeed") else { return nil }
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        guard let image = names.first(where: { $0.hasSuffix(".dmg") }),
              let version = AppVersion(String(image.split(separator: "-")[1]))
        else { return nil }
        let assets = Dictionary(uniqueKeysWithValues: names.map { ($0, url.appending(path: $0)) })
        return Release(version: version, name: nil, pageURL: url, assets: assets)
    }
    #endif
}
