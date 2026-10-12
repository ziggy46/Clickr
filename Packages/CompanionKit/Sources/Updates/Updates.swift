import Foundation

/// A dotted version like "1.2.0". Tags such as "v1.2" are accepted; anything after a "-"
/// (pre-release labels) is ignored for ordering.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]
    public let description: String

    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("v") { trimmed.removeFirst() }
        let core = trimmed.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        components = parts.compactMap { $0 }
        description = core
    }

    /// Missing parts count as zero, so 1.2 == 1.2.0.
    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// The newest published release on GitHub.
public struct Release: Sendable, Equatable {
    public let version: AppVersion
    public let name: String?
    /// The release page, where the download is.
    public let pageURL: URL
    /// Downloads attached to the release, by file name.
    public let assets: [String: URL]
    /// The release notes (GitHub's markdown), if any.
    public let notes: String?

    public init(version: AppVersion, name: String?, pageURL: URL, assets: [String: URL] = [:], notes: String? = nil) {
        self.version = version
        self.name = name
        self.pageURL = pageURL
        self.assets = assets
        self.notes = notes
    }

    /// What changed, for the update alert: the notes without the install instructions and
    /// GitHub's bookkeeping lines. Nil when there's nothing to show.
    public var whatsNew: String? {
        notes.flatMap(ReleaseNotes.whatsNew(in:))
    }

    /// The disk image to install on this Mac: the Apple silicon build on Apple silicon if
    /// there is one, otherwise the universal build.
    public func diskImage(forArm64 isArm64: Bool) -> (name: String, url: URL)? {
        let variants = isArm64 ? ["arm64", "universal"] : ["universal"]
        for variant in variants {
            let name = "Clickr-\(version.description)-\(variant).dmg"
            if let url = assets[name] { return (name, url) }
        }
        return nil
    }

    /// The file listing an Ed25519 signature for each disk image.
    public var signaturesURL: URL? { assets[UpdateSignatures.fileName] }

    public static func == (lhs: Release, rhs: Release) -> Bool {
        lhs.version == rhs.version && lhs.pageURL == rhs.pageURL
    }
}

/// Asks GitHub's public API for a repository's latest release. Drafts and pre-releases are
/// never "latest" there, so they're skipped automatically.
public struct ReleaseChecker: Sendable {
    public enum CheckError: Error, Equatable {
        case badResponse
        case http(Int)
    }

    public enum Result: Sendable, Equatable {
        case upToDate
        case available(Release)
        /// The repository has no published releases yet.
        case noReleases
    }

    public let repository: String
    public let currentVersion: AppVersion

    public init(repository: String, currentVersion: AppVersion) {
        self.repository = repository
        self.currentVersion = currentVersion
    }

    public var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    public func check(using session: URLSession = .shared) async throws -> Result {
        var request = URLRequest(url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // GitHub asks for a User-Agent; this is the only thing about the app that's sent.
        request.setValue("Clickr/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CheckError.badResponse }
        if http.statusCode == 404 { return .noReleases }
        guard http.statusCode == 200 else { throw CheckError.http(http.statusCode) }
        return try evaluate(data)
    }

    /// Reads GitHub's release JSON and compares it with the running version.
    public func evaluate(_ data: Data) throws -> Result {
        struct Payload: Decodable {
            let tag_name: String
            let name: String?
            let html_url: URL
            let assets: [Asset]?
            let body: String?
        }
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let version = AppVersion(payload.tag_name) else { throw CheckError.badResponse }
        guard currentVersion < version else { return .upToDate }
        let assets = Dictionary((payload.assets ?? []).map { ($0.name, $0.browser_download_url) }) { first, _ in first }
        return .available(Release(version: version, name: payload.name, pageURL: payload.html_url, assets: assets, notes: payload.body))
    }
}
