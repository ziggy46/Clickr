import Foundation
import TestSupport
import Testing
@testable import MRP

// Small builders for the TV's messages.
private func client(_ bundle: String, name: String? = nil) -> ProtoWriter {
    var writer = ProtoWriter()
    writer.string(2, bundle)
    if let name { writer.string(7, name) }
    return writer
}

private func path(_ bundle: String, name: String? = nil, player: String = "MediaRemote-DefaultPlayer") -> ProtoWriter {
    var writer = ProtoWriter()
    writer.message(2, client(bundle, name: name))
    var playerWriter = ProtoWriter()
    playerWriter.string(1, player)
    writer.message(3, playerWriter)
    return writer
}

private func item(_ id: String, title: String? = nil, artist: String? = nil, duration: Double? = nil,
                  elapsed: Double? = nil, timestamp: Double? = nil, rate: Float? = nil, artwork: Bool? = nil) -> ProtoWriter {
    var metadata = ProtoWriter()
    if let title { metadata.string(1, title) }
    if let artist { metadata.string(7, artist) }
    if let duration { metadata.double(14, duration) }
    if let artwork { metadata.bool(19, artwork) }
    if let elapsed { metadata.double(35, elapsed) }
    if let rate { metadata.float(39, rate) }
    if let timestamp { metadata.double(74, timestamp) }
    var writer = ProtoWriter()
    writer.string(1, id)
    writer.message(2, metadata)
    return writer
}

private func message(_ kind: MRPMessage.Kind, _ inner: ProtoWriter) -> MRPMessage {
    try! MRPMessage(decoding: MRPMessage.encode(kind, inner: inner))
}

private func setState(_ bundle: String, name: String? = nil, state: UInt64? = nil, items: [ProtoWriter]? = nil, location: Int = 0) -> MRPMessage {
    var inner = ProtoWriter()
    if let items {
        var queue = ProtoWriter()
        queue.int(1, Int64(location))
        items.forEach { queue.message(2, $0) }
        inner.message(3, queue)
    }
    if let state { inner.varint(6, state) }
    inner.message(9, path(bundle, name: name))
    return message(.setState, inner)
}

private func setClient(_ bundle: String, name: String? = nil) -> MRPMessage {
    var inner = ProtoWriter()
    inner.message(1, client(bundle, name: name))
    return message(.setNowPlayingClient, inner)
}

@Suite struct NowPlayingTrackerTests {
    @Test func nothingUntilAClientIsActive() {
        var tracker = NowPlayingTracker()
        tracker.handle(setState("com.example.video", name: "Video", state: 1, items: [item("A", title: "Episode 3")]))
        #expect(tracker.current == nil)
        tracker.handle(setClient("com.example.video"))
        #expect(tracker.current?.title == "Episode 3")
        #expect(tracker.current?.appName == "Video")
        #expect(tracker.current?.state == .playing)
    }

    @Test func readsTheFields() throws {
        var tracker = NowPlayingTracker()
        tracker.handle(setClient("com.google.ios.youtube", name: "YouTube"))
        tracker.handle(setState("com.google.ios.youtube", state: 1, items: [
            item("A", title: "The Video", artist: "The Channel", duration: 4397.2, elapsed: 12, timestamp: 813508517, rate: 1, artwork: false),
        ]))
        let playing = try #require(tracker.current)
        #expect(playing.title == "The Video")
        #expect(playing.artist == "The Channel")
        #expect(playing.duration == 4397.2)
        #expect(playing.bundleID == "com.google.ios.youtube")
        #expect(playing.artworkAvailable == false)
        #expect(playing.itemID == "A")
    }

    @Test func positionMovesOnOnlyWhilePlaying() throws {
        var tracker = NowPlayingTracker()
        let reported = Date(timeIntervalSinceReferenceDate: 800_000_000)
        tracker.handle(setClient("app"))
        tracker.handle(setState("app", state: 1, items: [item("A", title: "T", elapsed: 10, timestamp: 800_000_000, rate: 1)]))
        #expect(tracker.current?.position(at: reported.addingTimeInterval(5)) == 15)

        tracker.handle(setState("app", state: 2))
        #expect(tracker.current?.state == .paused)
        #expect(tracker.current?.position(at: reported.addingTimeInterval(5)) == 10)
    }

    @Test func updateContentItemMergesAndNeverAdds() {
        var tracker = NowPlayingTracker()
        tracker.handle(setClient("app"))
        tracker.handle(setState("app", state: 1, items: [item("A", title: "Old title", artist: "Artist")]))

        var inner = ProtoWriter()
        inner.message(1, item("A", title: "New title"))
        inner.message(1, item("B", title: "Not in the queue"))
        inner.message(2, path("app"))
        tracker.handle(message(.updateContentItem, inner))

        #expect(tracker.current?.title == "New title")
        #expect(tracker.current?.artist == "Artist")
    }

    @Test func pausedWithEmptyQueueIsNothing() {
        var tracker = NowPlayingTracker()
        tracker.handle(setClient("app"))
        tracker.handle(setState("app", state: 2, items: []))
        #expect(tracker.current == nil)
    }

    @Test func removingTheActiveClientClears() {
        var tracker = NowPlayingTracker()
        tracker.handle(setClient("app"))
        tracker.handle(setState("app", state: 1, items: [item("A", title: "T")]))
        var inner = ProtoWriter()
        inner.message(1, client("app"))
        tracker.handle(message(.removeClient, inner))
        #expect(tracker.current == nil)
    }

    @Test func switchingAppsFollowsSetNowPlayingClient() {
        var tracker = NowPlayingTracker()
        tracker.handle(setState("spotify", name: "Spotify", state: 2, items: [item("S", title: "Podcast")]))
        tracker.handle(setState("youtube", name: "YouTube", state: 1, items: [item("Y", title: "Video")]))
        tracker.handle(setClient("spotify"))
        #expect(tracker.current?.title == "Podcast")
        tracker.handle(setClient("youtube"))
        #expect(tracker.current?.title == "Video")
    }

    @Test func pyatvSetStateVector() throws {
        var tracker = NowPlayingTracker()
        tracker.handle(try MRPMessage(decoding: Data(hex: MRPVectors.shared.set_state)))
        tracker.handle(setClient("com.example.video"))
        let playing = try #require(tracker.current)
        #expect(playing.title == "Episode 3")
        #expect(playing.album == "Season 1")
        #expect(playing.playbackRate == 1)
        #expect(playing.artworkAvailable)
        #expect(playing.appName == "Video")
    }
}
