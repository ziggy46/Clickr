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
