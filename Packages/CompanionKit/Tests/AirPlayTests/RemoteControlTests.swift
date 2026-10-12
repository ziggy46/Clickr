import Foundation
import MRP
import Plist
import Testing
@testable import AirPlay

private let identity = AirPlayIdentity(
    name: "Clickr", model: "Mac16,8", osName: "macOS", osVersion: "27.0", osBuild: "26A434",
    deviceID: "02:11:22:33:44:55", macAddress: "02:11:22:33:44:55"
)

@Suite(.serialized) struct RemoteControlTests {
    @Test func setsUpTheTunnelAndReceivesNowPlaying() async throws {
        let server = try FakeAirPlayServer()
        try await server.start()
        defer { server.stop() }

        let session = AirPlayRemoteControl(endpoint: server.endpoint, credentials: server.clientCredentials, identity: identity)
        try await session.start()

        var tracker = NowPlayingTracker()
        for await message in session.messages {
            tracker.handle(message)
            if tracker.current != nil { break }
        }
        let playing = try #require(tracker.current)
        #expect(playing.title == "Episode 3")
        #expect(playing.appName == "Video")
        #expect(playing.state == .playing)

        let record = server.snapshot()
        #expect(record.methods.prefix(5) == ["POST", "POST", "SETUP", "RECORD", "SETUP"])
        #expect(record.mrpTypes.prefix(4) == [15, 38, 16, 24])
        #expect(record.setupIdentity["name"] == .string("Clickr"))
        #expect(record.setupIdentity["isRemoteControlOnly"] == .bool(true))
        // We answered the event channel request with 200, echoing its CSeq.
        #expect(record.eventReplies.first?.statusCode == 200)
        #expect(record.eventReplies.first?.headers["cseq"] == "7")
        // Our data frames count up, and the TV's frames got acknowledged... by us.
        #expect(record.dataSeqnos == record.dataSeqnos.sorted() && Set(record.dataSeqnos).count == record.dataSeqnos.count)
        await session.close()
    }

    @Test func fetchesArtwork() async throws {
        let server = try FakeAirPlayServer()
        try await server.start()
        defer { server.stop() }
        let session = AirPlayRemoteControl(endpoint: server.endpoint, credentials: server.clientCredentials, identity: identity)
        try await session.start()

        let reply = try await session.request(.playbackQueueRequest, MRPRequests.playbackQueueRequest(location: 0, width: 200, height: -1))
        let item = try #require(reply.inner?.message(3)?.messages(2).first)
        #expect(item.data(3)?.count == 1000)
        await session.close()
    }

    @Test func keepsTheSessionAliveWithFeedback() async throws {
        let server = try FakeAirPlayServer()
        try await server.start()
        defer { server.stop() }
        let session = AirPlayRemoteControl(endpoint: server.endpoint, credentials: server.clientCredentials, identity: identity)
        try await session.start()
        try await Task.sleep(for: .milliseconds(4500))
        #expect(server.snapshot().feedbackCount >= 2)
        await session.close()
    }

    @Test func endsWhenTheTVHangsUp() async throws {
        let server = try FakeAirPlayServer()
        try await server.start()
        let session = AirPlayRemoteControl(endpoint: server.endpoint, credentials: server.clientCredentials, identity: identity)
        try await session.start()
        server.stop()
        // The messages stream finishes once a connection drops.
        for await _ in session.messages {}
    }
}
