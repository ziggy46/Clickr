import Foundation
import TestSupport
import Testing
@testable import MRP

/// Vectors/mrp.json, made by scripts/gen_vectors.py with pyatv's message builders.
struct MRPVectors: Decodable {
    let handshake: [String: String]
    let set_state: String
    let artwork_reply: String
    let varint_300: String

    static let shared: MRPVectors = {
        let url = Bundle.module.url(forResource: "mrp", withExtension: "json", subdirectory: "Vectors")!
        return try! JSONDecoder().decode(MRPVectors.self, from: Data(contentsOf: url))
    }()
}

private let unique = "5E1F2B6C-0A9D-4C3E-8F71-2D4B6A8C0E1F"

@Suite struct MRPEncodingTests {
    let vectors = MRPVectors.shared

    @Test func deviceInfoMatchesPyatv() {
        let inner = MRPRequests.deviceInfo(name: "Clickr", uniqueIdentifier: "abcdef01-2345-6789-abcd-ef0123456789", systemBuildVersion: "18G82")
        let data = MRPMessage.encode(.deviceInfo, identifier: "11111111-1111-1111-1111-111111111111", uniqueIdentifier: unique, inner: inner)
        #expect(data.hex == vectors.handshake["device_info"])
    }

    @Test func setConnectionStateMatchesPyatv() {
        let data = MRPMessage.encode(.setConnectionState, uniqueIdentifier: unique, inner: MRPRequests.setConnectionState())
        #expect(data.hex == vectors.handshake["set_connection_state"])
    }

    @Test func clientUpdatesConfigMatchesPyatv() {
        let data = MRPMessage.encode(.clientUpdatesConfig, identifier: "22222222-2222-2222-2222-222222222222", uniqueIdentifier: unique, inner: MRPRequests.clientUpdatesConfig())
        #expect(data.hex == vectors.handshake["client_updates_config"])
    }

    @Test func getKeyboardSessionMatchesPyatv() {
        let data = MRPMessage.encode(.getKeyboardSession, identifier: "33333333-3333-3333-3333-333333333333", uniqueIdentifier: unique)
        #expect(data.hex == vectors.handshake["get_keyboard_session"])
    }

    @Test func playbackQueueRequestMatchesPyatv() {
        let data = MRPMessage.encode(.playbackQueueRequest, identifier: "44444444-4444-4444-4444-444444444444", uniqueIdentifier: unique,
                                     inner: MRPRequests.playbackQueueRequest(location: 0, width: 512, height: -1))
        #expect(data.hex == vectors.handshake["playback_queue_request"])
    }

    @Test func varint() {
        #expect(ProtoWriter.varint(300).hex == vectors.varint_300)
        #expect(ProtoWriter.varint(0).hex == "00")
        var writer = ProtoWriter()
        writer.int(1, -1)
        #expect(writer.data.hex == "08ffffffffffffffffff01")
    }
}

@Suite struct MRPDecodingTests {
    let vectors = MRPVectors.shared

    @Test func readsSetState() throws {
        let message = try MRPMessage(decoding: Data(hex: vectors.set_state))
        #expect(message.kind == .setState)
        let state = try #require(message.inner)
        #expect(state.uint(6) == 1) // playing

        let path = try #require(state.message(9))
        #expect(path.message(2)?.string(2) == "com.example.video")
        #expect(path.message(2)?.string(7) == "Video")
        #expect(path.message(3)?.string(1) == "MediaRemote-DefaultPlayer")

        let queue = try #require(state.message(3))
        #expect(queue.int(1) ?? 0 == 0)
        let item = try #require(queue.messages(2).first)
        #expect(item.string(1) == "ITEM-1")
        let metadata = try #require(item.message(2))
        #expect(metadata.string(1) == "Episode 3")
        #expect(metadata.string(7) == "Some Show")
        #expect(metadata.string(6) == "Season 1")
        #expect(metadata.double(14) == 2712.5)
        #expect(metadata.double(35) == 61.25)
        #expect(metadata.double(74) == 813508517.465923)
        #expect(metadata.float(39) == 1.0)
        #expect(metadata.bool(19) == true)
        #expect(metadata.string(31) == "image/jpeg")
        #expect(metadata.string(80) == "3e7d403ad36f7472")
        #expect(metadata.uint(64) == 2)
    }

    @Test func readsArtworkReply() throws {
        let message = try MRPMessage(decoding: Data(hex: vectors.artwork_reply))
        #expect(message.identifier == "44444444-4444-4444-4444-444444444444")
        let item = try #require(message.inner?.message(3)?.messages(2).first)
        #expect(item.data(3)?.count == 300)
        #expect(item.int(13) == 512)
        #expect(item.int(14) == 288)
    }

    @Test func mergeReplacesFields() throws {
        var base = ProtoMessage()
        base.fields = [(1, .bytes(Data("Old".utf8))), (35, .fixed64(Double(5).bitPattern))]
        var update = ProtoMessage()
        update.fields = [(35, .fixed64(Double(9).bitPattern))]
        base.merge(update)
        #expect(base.string(1) == "Old")
        #expect(base.double(35) == 9)
    }

    @Test func rejectsTruncatedInput() {
        #expect(throws: ProtoMessage.DecodingError.self) { try ProtoMessage(decoding: Data([0x0A, 0x05, 0x01])) }
    }
}
