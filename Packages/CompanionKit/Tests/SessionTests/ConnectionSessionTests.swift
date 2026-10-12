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

/// Waits until the session reports `target`, failing after `timeout`.
private func waitFor(_ target: ConnectionState, in session: AppleTVSession, timeout: Duration = .seconds(10)) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await state in await session.state where state == target { return true }
            return false
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return false
        }
        let result = await group.next()!
        group.cancelAll()
        return result
    }
}

/// A fake TV and a session already paired with it.
private func pairedSession() async throws -> (FakeAppleTV, AppleTVSession) {
    let tv = try FakeAppleTV(pin: "4821")
    try await tv.start()
    let session = AppleTVSession(device: device(at: tv.endpoint), store: InMemoryCredentialStore())
    try await session.beginPairing()
    try await session.finishPairing(pin: "4821")
    return (tv, session)
}

@Suite(.serialized) struct ConnectionSessionTests {
    @Test func connectsWithPairVerifyAndStartsSession() async throws {
        let (tv, session) = try await pairedSession()
        defer { tv.stop() }

        await session.connect()
        #expect(await waitFor(.connected, in: session))
        #expect(tv.snapshot().requests == ["_systemInfo", "_sessionStart", "TVRCSessionStart", "FetchAttentionState", "_tiStart"])
        #expect(tv.events == ["SystemStatus", "TVSystemStatus"])
        await session.disconnect()
    }

    @Test func pressSendsDownThenUp() async throws {
        let (tv, session) = try await pairedSession()
        defer { tv.stop() }
        await session.connect()
        #expect(await waitFor(.connected, in: session))

        try await session.press(.select)
        try await session.press(.volumeUp)
        let hid = tv.snapshot().hid.map { [$0.state, $0.code] }
        #expect(hid == [[1, 6], [2, 6], [1, 8], [2, 8]])
        await session.disconnect()
    }

    @Test func longPressHoldsForASecond() async throws {
        let (tv, session) = try await pairedSession()
        defer { tv.stop() }
        await session.connect()
        #expect(await waitFor(.connected, in: session))

        let clock = ContinuousClock()
        let elapsed = try await clock.measure { try await session.press(.home, hold: true) }
        #expect(elapsed >= .seconds(1))
        #expect(tv.snapshot().hid.map { [$0.state, $0.code] } == [[1, 7], [2, 7]])
        await session.disconnect()
    }

    @Test func reconnectsAfterTheTVDrops() async throws {
        let (tv, session) = try await pairedSession()
        defer { tv.stop() }
        await session.connect()
        #expect(await waitFor(.connected, in: session))

        tv.dropConnections()
        #expect(await waitFor(.disconnected, in: session))
        // First retry is after 1 s.
        #expect(await waitFor(.connected, in: session))
        try await session.press(.select)
        await session.disconnect()
    }

    @Test func forgottenPairingNeedsPairingAgain() async throws {
        let (tv, session) = try await pairedSession()
        defer { tv.stop() }
        tv.rejectsVerify = true

        await session.connect()
        #expect(await waitFor(.needsPairing, in: session))
    }

    @Test func reportsSleepAndWake() async throws {
        let (tv, session) = try await pairedSession()
        defer { tv.stop() }
        tv.isAsleep = true
        var updates = await session.updates.makeAsyncIterator()

        await session.connect()
        #expect(await updates.next() == .asleep(true))
        // Then the connect-time _tiStart reports the focused field.
        #expect(await updates.next() == .keyboardShown(text: ""))
        tv.setAsleep(false)
        #expect(await updates.next() == .asleep(false))
        await session.disconnect()
    }

    @Test func powerSendsSleepAndWake() async throws {
        let (tv, session) = try await pairedSession()
        defer { tv.stop() }
        await session.connect()
        #expect(await waitFor(.connected, in: session))

        try await session.setPower(on: false)
        try await session.setPower(on: true)
        #expect(tv.snapshot().hid.map { [$0.state, $0.code] } == [[2, 12], [2, 13]])
        await session.disconnect()
    }

    @Test func pressWithoutConnectionThrows() async {
        let session = AppleTVSession(device: device(at: .hostPort(host: "127.0.0.1", port: 9)), store: InMemoryCredentialStore())
        await #expect(throws: AppleTVSession.SessionError.notConnected) {
            try await session.press(.select)
        }
    }
}
