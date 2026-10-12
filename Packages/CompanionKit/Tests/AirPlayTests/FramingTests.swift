import Foundation
import MRP
import Plist
import TestSupport
import Testing
@testable import AirPlay

/// Vectors/mrp.json (the transport part), made with pyatv's HAPSession and DataStreamChannel.
struct TransportVectors: Decodable {
    let hap_out_key, hap_in_key, hap_plaintext, hap_framed, data_frame: String
    let data_frame_seqno: UInt64
    let handshake: [String: String]

    static let shared: TransportVectors = {
        let url = Bundle.module.url(forResource: "mrp", withExtension: "json", subdirectory: "Vectors")!
        return try! JSONDecoder().decode(TransportVectors.self, from: Data(contentsOf: url))
    }()
}

@Suite struct HAPFramingTests {
    let vectors = TransportVectors.shared

    @Test func sealsLikePyatv() throws {
        var framing = HAPFraming(outputKey: Data(hex: vectors.hap_out_key), inputKey: Data(hex: vectors.hap_in_key))
        // 1500 bytes: a 1024-byte block and a 476-byte block, counters 0 and 1.
        #expect(try framing.seal(Data(hex: vectors.hap_plaintext)).hex == vectors.hap_framed)
    }

    @Test func opensAcrossArbitrarySplits() throws {
        var framing = HAPFraming(outputKey: Data(hex: vectors.hap_in_key), inputKey: Data(hex: vectors.hap_out_key))
        let wire = Data(hex: vectors.hap_framed)
        var plaintext = Data()
        for chunk in stride(from: 0, to: wire.count, by: 333) {
            plaintext += try framing.open(wire[chunk..<min(chunk + 333, wire.count)])
        }
        #expect(plaintext.hex == vectors.hap_plaintext)
    }

    @Test func rejectsTampering() {
        var framing = HAPFraming(outputKey: Data(hex: vectors.hap_in_key), inputKey: Data(hex: vectors.hap_out_key))
        var wire = Data(hex: vectors.hap_framed)
        wire[10] ^= 1
        #expect(throws: HAPFraming.FramingError.self) { try framing.open(wire) }
    }

    @Test func nonceIsZerosThenLittleEndianCounter() {
        let nonce = Array(HAPFraming.nonce(0x0102).withUnsafeBytes { Data($0) })
        #expect(nonce == [0, 0, 0, 0, 0x02, 0x01, 0, 0, 0, 0, 0, 0])
    }
}

@Suite struct DataStreamFrameTests {
    let vectors = TransportVectors.shared

    @Test func headerAndEnvelopeMatchPyatv() throws {
        let message = Data(hex: vectors.handshake["set_connection_state"]!)
        let frame = DataStreamFrame.sync([message], seqno: vectors.data_frame_seqno)
        let ours = frame.encoded()
        let theirs = Data(hex: vectors.data_frame)
        // Header byte for byte; the plists may order objects differently, so compare decoded.
        #expect(ours.prefix(32).hex == theirs.prefix(32).hex)
        #expect(try BinaryPlist.decode(ours.dropFirst(32)) == BinaryPlist.decode(theirs.dropFirst(32)))
    }

    @Test func readsMessagesBack() throws {
        var buffer = Data(hex: vectors.data_frame)
        let frame = try #require(DataStreamFrame.next(from: &buffer))
        #expect(buffer.isEmpty)
        #expect(frame.isSync)
        #expect(frame.command == "comm")
        #expect(frame.seqno == vectors.data_frame_seqno)
        #expect(frame.mrpMessages() == [Data(hex: vectors.handshake["set_connection_state"]!)])
    }

    @Test func waitsForWholeFrames() {
        var buffer = Data(hex: vectors.data_frame).prefix(40)
        #expect(DataStreamFrame.next(from: &buffer) == nil)
        #expect(buffer.count == 40)
    }

    @Test func readsSeveralPrefixedMessages() {
        let a = Data(hex: vectors.handshake["set_connection_state"]!)
        let b = Data(hex: vectors.handshake["get_keyboard_session"]!)
        #expect(DataStreamFrame.sync([a, b], seqno: 1).mrpMessages() == [a, b])
    }

    @Test func bareMessageStartingWith08() {
        // ConfigureConnection can arrive without a length prefix.
        let bare = Data([0x08, 0x78, 0x20, 0x00])
        let payload = BinaryPlist.encode(.dict(["params": .dict(["data": .data(bare)])]))
        let frame = DataStreamFrame(messageType: "sync", command: "comm", seqno: 1, payload: payload)
        #expect(frame.mrpMessages() == [bare])
    }

    @Test func replyEchoesSeqnoWithNoPayload() {
        let reply = DataStreamFrame.reply(to: DataStreamFrame(messageType: "sync", command: "comm", seqno: 77, payload: Data([1])))
        #expect(reply.encoded().hex == "00000020" + "72706c79" + String(repeating: "00", count: 8) + "00000000" + "000000000000004d" + "00000000")
    }
}
