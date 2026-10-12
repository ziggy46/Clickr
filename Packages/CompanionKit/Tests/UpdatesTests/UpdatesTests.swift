import CryptoKit
import Foundation
import Testing
@testable import Updates

@Suite struct AppVersionTests {
    @Test(arguments: [
        ("0.1.0", "0.2.0"), ("1.9", "1.10"), ("v1.0", "1.0.1"), ("1.2.3", "2.0"), ("1.0.0-beta", "1.0.1"),
    ])
    func orders(older: String, newer: String) throws {
        #expect(try #require(AppVersion(older)) < #require(AppVersion(newer)))
    }

    @Test func equalIgnoringTrailingZerosAndPrefix() throws {
        #expect(try #require(AppVersion("v1.2")) == #require(AppVersion("1.2.0")))
    }

    @Test(arguments: ["", "v", "latest", "1.x", "1..2"])
    func rejectsNonVersions(text: String) {
        #expect(AppVersion(text) == nil)
    }
}

@Suite struct ReleaseCheckerTests {
    let checker = ReleaseChecker(repository: "ziggy46/Clickr", currentVersion: AppVersion("0.1.0")!)

    private func json(tag: String) -> Data {
        Data("""
        {"tag_name": "\(tag)", "name": "Clickr \(tag)", "html_url": "https://github.com/ziggy46/Clickr/releases/tag/\(tag)",
         "draft": false, "prerelease": false, "assets": []}
        """.utf8)
    }

    @Test func newerReleaseIsAvailable() throws {
        guard case .available(let release) = try checker.evaluate(json(tag: "v0.2.0")) else {
            Issue.record("expected an update")
            return
        }
        #expect(release.version.description == "0.2.0")
        #expect(release.pageURL.absoluteString == "https://github.com/ziggy46/Clickr/releases/tag/v0.2.0")
    }

    @Test func sameOrOlderIsUpToDate() throws {
        #expect(try checker.evaluate(json(tag: "v0.1.0")) == .upToDate)
        #expect(try checker.evaluate(json(tag: "0.0.9")) == .upToDate)
    }

    @Test func oddTagIsAnError() {
        #expect(throws: (any Error).self) { try checker.evaluate(json(tag: "nightly")) }
    }

    @Test func asksTheRightURL() {
        #expect(checker.latestReleaseURL.absoluteString == "https://api.github.com/repos/ziggy46/Clickr/releases/latest")
    }
}

@Suite struct ReleaseAssetTests {
    private func release(_ names: [String]) -> Release {
        let base = "https://github.com/ziggy46/Clickr/releases/download/v0.2.0/"
        return Release(
            version: AppVersion("0.2.0")!,
            name: nil,
            pageURL: URL(string: "https://github.com/ziggy46/Clickr/releases/tag/v0.2.0")!,
            assets: Dictionary(uniqueKeysWithValues: names.map { ($0, URL(string: base + $0)!) })
        )
    }

    @Test func readsAssetsFromGitHub() throws {
        let checker = ReleaseChecker(repository: "ziggy46/Clickr", currentVersion: AppVersion("0.1.0")!)
        let json = Data("""
        {"tag_name": "v0.2.0", "name": "Clickr 0.2.0", "html_url": "https://github.com/ziggy46/Clickr/releases/tag/v0.2.0",
         "assets": [{"name": "SIGNATURES.txt", "browser_download_url": "https://example.com/SIGNATURES.txt"}]}
        """.utf8)
        guard case .available(let release) = try checker.evaluate(json) else {
            Issue.record("expected an update")
            return
        }
        #expect(release.signaturesURL?.absoluteString == "https://example.com/SIGNATURES.txt")
    }

    @Test func picksTheDiskImageForTheMac() {
        let both = release(["Clickr-0.2.0-arm64.dmg", "Clickr-0.2.0-universal.dmg", "SIGNATURES.txt"])
        #expect(both.diskImage(forArm64: true)?.name == "Clickr-0.2.0-arm64.dmg")
        #expect(both.diskImage(forArm64: false)?.name == "Clickr-0.2.0-universal.dmg")

        let universalOnly = release(["Clickr-0.2.0-universal.dmg"])
        #expect(universalOnly.diskImage(forArm64: true)?.name == "Clickr-0.2.0-universal.dmg")

        // Older releases shipped zips, which can't be installed automatically.
        let zips = release(["Clickr-0.2.0-arm64.zip", "Clickr-0.2.0-universal.zip"])
        #expect(zips.diskImage(forArm64: true) == nil)
        #expect(zips.signaturesURL == nil)
    }
}

@Suite struct UpdateSignatureTests {
    let key = Curve25519.Signing.PrivateKey()
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    @Test func acceptsAGoodSignature() throws {
        let image = Data("disk image".utf8)
        let signature = try key.signature(for: image)
        let file = "\(signature.base64EncodedString())  Clickr-0.2.0-arm64.dmg\n"
        let parsed = UpdateSignatures.parse(file)
        let found = try #require(parsed["Clickr-0.2.0-arm64.dmg"])
        #expect(UpdateSignatures.isValid(found, of: image, publicKey: publicKey))
    }

    @Test func rejectsTamperingAndOtherKeys() throws {
        let image = Data("disk image".utf8)
        let signature = try key.signature(for: image)
        #expect(!UpdateSignatures.isValid(signature, of: Data("disk imagf".utf8), publicKey: publicKey))

        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        #expect(!UpdateSignatures.isValid(signature, of: image, publicKey: otherKey))
        #expect(!UpdateSignatures.isValid(signature, of: image, publicKey: "not a key"))
    }

    @Test func skipsMalformedLines() {
        let good = Data(repeating: 1, count: 64).base64EncodedString()
        let short = Data(repeating: 1, count: 10).base64EncodedString()
        let parsed = UpdateSignatures.parse("""
        \(good)  a.dmg
        \(short)  b.dmg
        nonsense
        !!!!  c.dmg

        """)
        #expect(Array(parsed.keys) == ["a.dmg"])
    }
}

@Suite struct ReleaseNotesTests {
    @Test func keepsWhatChangedAndDropsTheInstallSection() {
        let body = """
        ## What's Changed
        * Playback controls by @ziggy46 in https://github.com/ziggy46/Clickr/pull/3
        * Trackpad swiping by @some-one in https://github.com/ziggy46/Clickr/pull/4

        ## New Contributors
        * @some-one made their first contribution in https://github.com/ziggy46/Clickr/pull/4

        **Full Changelog**: https://github.com/ziggy46/Clickr/compare/v0.2.1...v0.3.0

        <!-- clickr:install -->
        ### Installing

        1. Download the disk image.
        """
        #expect(ReleaseNotes.whatsNew(in: body) == """
        ## What's Changed
        * Playback controls
        * Trackpad swiping
        """)
    }

    @Test func readsOlderReleasesWithInstallInstructionsFirst() {
        let body = """
        ### Installing

        1. Download it.

        ## What's Changed
        * Follow the system accent color (0.2.1) by @ziggy46 in https://github.com/ziggy46/Clickr/pull/2

        **Full Changelog**: https://github.com/ziggy46/Clickr/compare/v0.2.0...v0.2.1
        """
        #expect(ReleaseNotes.whatsNew(in: body) == "## What's Changed\n* Follow the system accent color (0.2.1)")
    }

    @Test func nothingToShow() {
        #expect(ReleaseNotes.whatsNew(in: "") == nil)
        #expect(ReleaseNotes.whatsNew(in: "\n<!-- clickr:install -->\n### Installing") == nil)
    }

    @Test func checkerKeepsTheBody() throws {
        let checker = ReleaseChecker(repository: "ziggy46/Clickr", currentVersion: AppVersion("0.2.1")!)
        let json = Data("{\"tag_name\": \"v0.3.0\", \"html_url\": \"https://github.com/ziggy46/Clickr/releases/tag/v0.3.0\", \"body\": \"## What's Changed\\n* New things\"}".utf8)
        guard case .available(let release) = try checker.evaluate(json) else {
            Issue.record("expected an update")
            return
        }
        #expect(release.whatsNew == "## What's Changed\n* New things")
    }
}
