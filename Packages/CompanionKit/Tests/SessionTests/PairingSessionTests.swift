import Discovery
import Foundation
import Network
import Pairing
import Store
import Testing
@testable import Session

private func device(at endpoint: NWEndpoint) -> DiscoveredDevice {
    DiscoveredDevice(name: "Fake TV", endpoint: endpoint, txt: ["rpMd": "AppleTV11,1", "rpMRtID": "FAKE-TV"])!
}

private func firstState(_ session: AppleTVSession) async -> ConnectionState? {
    var states = await session.state.makeAsyncIterator()
    return await states.next()
}

@Suite(.serialized) struct PairingSessionTests {
    @Test func pairsAndSavesCredentials() async throws {
        let tv = try FakeAppleTV(pin: "4821")
        try await tv.start()
        defer { tv.stop() }
        let store = InMemoryCredentialStore()
        let session = AppleTVSession(device: device(at: tv.endpoint), store: store, nowPlaying: false)
        #expect(await firstState(session) == .needsPairing)

        try await session.beginPairing()
        try await session.finishPairing(pin: "4821")

        let credentials = try #require(try store.credentials(for: "FAKE-TV"))
        #expect(credentials.theirID == tv.identifier)
        #expect(credentials.theirLTPK == tv.signingKey.publicKey.rawRepresentation)
        #expect(credentials.ourLTSK.count == 32)
        #expect(tv.snapshot().name == "Clickr")
        #expect(await firstState(session) == .disconnected)
    }

    @Test func wrongPINIsReportedAndNothingIsSaved() async throws {
        let tv = try FakeAppleTV(pin: "4821")
        try await tv.start()
        defer { tv.stop() }
        let store = InMemoryCredentialStore()
        let session = AppleTVSession(device: device(at: tv.endpoint), store: store, nowPlaying: false)

        try await session.beginPairing()
        await #expect(throws: PairSetup.PairingError.wrongPIN) {
            try await session.finishPairing(pin: "0000")
        }
        #expect(try store.credentials(for: "FAKE-TV") == nil)

        // A fresh attempt works after a wrong PIN.
        try await session.beginPairing()
        try await session.finishPairing(pin: "4821")
        #expect(try store.credentials(for: "FAKE-TV") != nil)
    }

    @Test func startsDisconnectedWhenAlreadyPaired() async throws {
        let store = InMemoryCredentialStore()
        try store.save(PairingCredentials(deviceID: Data(), ourLTSK: Data(), ourLTPK: Data(), theirLTPK: Data(), theirID: Data()), for: "FAKE-TV")
        let session = AppleTVSession(device: device(at: .hostPort(host: "127.0.0.1", port: 9)), store: store)
        #expect(await firstState(session) == .disconnected)
    }

    @Test func finishWithoutBeginThrows() async {
        let session = AppleTVSession(device: device(at: .hostPort(host: "127.0.0.1", port: 9)), store: InMemoryCredentialStore())
        await #expect(throws: AppleTVSession.SessionError.notPairing) {
            try await session.finishPairing(pin: "1234")
        }
    }
}
