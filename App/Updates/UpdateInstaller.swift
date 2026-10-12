import AppKit
import os
import Updates

/// Downloads a release, checks it, and swaps it in for the running copy of Clickr.
///
/// Everything that can fail happens while Clickr is still running: download, signature
/// check, mounting the disk image, copying the app out and checking it. Only then does
/// Clickr quit, and a small shell helper moves the new copy into place once it has exited
/// and opens it. Replacing the bundle under a running app isn't safe, since AppKit loads
/// resources from it lazily.
struct UpdateInstaller {
    enum InstallError: LocalizedError {
        case notInstallable(String)
        case missingDownload
        case badSignature
        case commandFailed(String)
        case unexpectedApp(String)

        var errorDescription: String? {
            switch self {
            case .notInstallable(let reason): reason
            case .missingDownload: "The release doesn't include a signed download for this Mac."
            case .badSignature: "The download's signature didn't check out, so it wasn't installed."
            case .commandFailed(let command): "Couldn't prepare the update (\(command) failed)."
            case .unexpectedApp(let reason): "The download didn't contain the expected app (\(reason))."
            }
        }
    }

    /// A checked copy of the new version, waiting next to the installed app.
    struct PreparedUpdate {
        let version: AppVersion
        let stagedApp: URL
        let workDirectory: URL
    }

    let appURL = Bundle.main.bundleURL
    let currentVersion: AppVersion
    private let publicKey = Bundle.main.object(forInfoDictionaryKey: "ClickrUpdatePublicKey") as? String
    private let log = Logger(subsystem: "com.ziggy46.clickr", category: "Updates")

    /// Why this copy of Clickr can't replace itself, or nil when it can.
    var blocker: String? {
        if appURL.path.contains("/AppTranslocation/") {
            return "Move Clickr to your Applications folder to install updates automatically."
        }
        if !FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) {
            return "Clickr can't install updates where it is, because it can't change that folder."
        }
        if publicKey == nil {
            return "This build of Clickr can't check update signatures."
        }
        return nil
    }

    /// Whether `release` can be installed automatically (it was published with signed disk
    /// images and this copy of Clickr can replace itself).
    func canInstall(_ release: Release) -> Bool {
        blocker == nil && release.diskImage(forArm64: Self.isArm64) != nil && release.signaturesURL != nil
    }

    func prepare(_ release: Release) async throws -> PreparedUpdate {
        if let blocker { throw InstallError.notInstallable(blocker) }
        guard let publicKey,
              let image = release.diskImage(forArm64: Self.isArm64),
              let signaturesURL = release.signaturesURL
        else { throw InstallError.missingDownload }

        // A folder on the same volume as the app, so the final move is a rename.
        let work = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true
        )
        do {
            let (signaturesData, _) = try await URLSession.shared.data(from: signaturesURL)
            let signatures = UpdateSignatures.parse(String(decoding: signaturesData, as: UTF8.self))
            guard let signature = signatures[image.name] else { throw InstallError.missingDownload }

            log.info("Downloading \(image.name, privacy: .public)")
            let (download, _) = try await URLSession.shared.download(from: image.url)
            let diskImage = work.appending(path: image.name)
            try FileManager.default.moveItem(at: download, to: diskImage)
            let imageData = try Data(contentsOf: diskImage, options: .mappedIfSafe)
            guard UpdateSignatures.isValid(signature, of: imageData, publicKey: publicKey) else {
                throw InstallError.badSignature
            }

            let mountPoint = work.appending(path: "mount")
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: false)
            try await run("/usr/bin/hdiutil", "attach", diskImage.path, "-mountpoint", mountPoint.path,
                          "-nobrowse", "-readonly", "-noautoopen", "-quiet")
            let staged = work.appending(path: appURL.lastPathComponent)
            do {
                // --noqtn: the image was verified above, so don't carry a quarantine flag over.
                try await run("/usr/bin/ditto", "--noqtn", mountPoint.appending(path: "Clickr.app").path, staged.path)
            } catch {
                try? await run("/usr/bin/hdiutil", "detach", mountPoint.path, "-force", "-quiet")
                throw error
            }
            try? await run("/usr/bin/hdiutil", "detach", mountPoint.path, "-force", "-quiet")
            try? FileManager.default.removeItem(at: diskImage)

            try check(staged, expecting: release.version)
            try await run("/usr/bin/codesign", "--verify", "--deep", "--strict", staged.path)
            log.info("Update \(release.version.description, privacy: .public) is ready")
            return PreparedUpdate(version: release.version, stagedApp: staged, workDirectory: work)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    /// Starts the helper that swaps the app once Clickr has quit, then quits.
    @MainActor
    func installAndRelaunch(_ update: PreparedUpdate) throws {
        // Waits up to a minute for Clickr to exit, moves the old copy aside, moves the new
        // one in (putting the old one back if that fails), then opens whichever is there.
        let script = """
        pid="$1"; new="$2"; app="$3"; work="$4"
        tries=0
        while kill -0 "$pid" 2>/dev/null; do
          tries=$((tries + 1)); [ "$tries" -gt 300 ] && exit 1
          sleep 0.2
        done
        if mv "$app" "$work/previous.app"; then
          if mv "$new" "$app"; then
            rm -rf "$work"
          else
            mv "$work/previous.app" "$app"
          fi
        fi
        open "$app"
        """
        try spawnDetached([
            "/bin/sh", "-c", script, "clickr-update",
            String(ProcessInfo.processInfo.processIdentifier),
            update.stagedApp.path, appURL.path, update.workDirectory.path,
        ])
        log.info("Installing \(update.version.description, privacy: .public) and restarting")
        NSApp.terminate(nil)
    }

    func discard(_ update: PreparedUpdate) {
        try? FileManager.default.removeItem(at: update.workDirectory)
    }

    // MARK: - Helpers

    static var isArm64: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    private func check(_ app: URL, expecting version: AppVersion) throws {
        guard let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")) else {
            throw InstallError.unexpectedApp("no Info.plist")
        }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw InstallError.unexpectedApp("different bundle identifier")
        }
        guard let text = info["CFBundleShortVersionString"] as? String,
              let found = AppVersion(text), found == version
        else { throw InstallError.unexpectedApp("version doesn't match the release") }
        // Never install an older copy, even a correctly signed one.
        guard currentVersion < found else { throw InstallError.unexpectedApp("not newer than this version") }
    }

    private func run(_ arguments: String...) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            let name = URL(fileURLWithPath: arguments[0]).lastPathComponent
            throw InstallError.commandFailed(name)
        }
    }

    /// Starts a process in its own session, so it keeps running after Clickr quits.
    private func spawnDetached(_ arguments: [String]) throws {
        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor: Int32 in 0...2 {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0)
        }

        var argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, arguments[0], &actions, &attributes, &argv, environ)
        guard result == 0 else { throw InstallError.commandFailed("posix_spawn (\(result))") }
    }
}
