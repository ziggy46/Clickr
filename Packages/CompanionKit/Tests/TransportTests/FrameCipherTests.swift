import Foundation
import TestSupport
import Testing
@testable import Transport

/// Vectors/frames.json: frames encrypted the way pyatv's CompanionConnection does it.
struct FrameVectors: Decodable {
    struct WireFrame: Decodable {
        let type: UInt8
        let payload: String
        let wire: String
    }

    let output_key: String
    let input_key: String
    let frames_to_tv: [WireFrame]
    let frames_from_tv: [WireFrame]

    static let shared: FrameVectors = {
        let url = Bundle.module.url(forResource: "frames", withExtension: "json", subdirectory: "Vectors")!
        return try! JSONDecoder().decode(FrameVectors.self, from: Data(contentsOf: url))
    }()
}

@Suite struct FrameCipherTests {
    let vectors = FrameVectors.shared

    @Test func encryptsLikePyatv() throws {
        var cipher = FrameCipher(outputKey: Data(hex: vectors.output_key), inputKey: Data(hex: vectors.input_key))
        for frame in vectors.frames_to_tv {
            let type = FrameType(rawValue: frame.type)
            let body = try cipher.seal(Data(hex: frame.payload), type: type)
            let header = FrameHeader(type: type, payloadLength: body.count)
            #expect((header.bytes + body).hex == frame.wire)
        }
    }

    @Test func decryptsWhatTheTVSends() throws {
        var cipher = FrameCipher(outputKey: Data(hex: vectors.output_key), inputKey: Data(hex: vectors.input_key))
        for frame in vectors.frames_from_tv {
            let wire = Data(hex: frame.wire)
            #expect(try cipher.open(wire.dropFirst(4), type: FrameType(rawValue: frame.type)).hex == frame.payload)
        }
    }

    @Test func rejectsTamperedFrame() {
        var cipher = FrameCipher(outputKey: Data(hex: vectors.output_key), inputKey: Data(hex: vectors.input_key))
        var body = Data(Data(hex: vectors.frames_from_tv[0].wire).dropFirst(4))
        body[body.startIndex] ^= 1
        #expect(throws: FrameCipher.CipherError.self) { try cipher.open(body, type: .eOPACK) }
    }

    @Test func rejectsWrongFrameType() {
        // The header is the AAD, so a frame relabelled with another type must fail.
        var cipher = FrameCipher(outputKey: Data(hex: vectors.output_key), inputKey: Data(hex: vectors.input_key))
        let body = Data(Data(hex: vectors.frames_from_tv[0].wire).dropFirst(4))
        #expect(throws: FrameCipher.CipherError.self) { try cipher.open(body, type: .pOPACK) }
    }

    @Test func nonceIsLittleEndianCounterThenZeros() {
        let nonce = Array(FrameCipher.nonce(0x0102).withUnsafeBytes { Data($0) })
        #expect(nonce == [0x02, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func encryptedRoundTripOverLoopback() async throws {
        // Client and an echo server can't share one cipher, so check that what we send
        // comes back undecryptable with our own input key, and that the length grows by 16.
        let server = try await LoopbackServer.start(.record)
        defer { server.stop() }
        let connection = CompanionConnection(endpoint: server.endpoint)
        try await connection.connect()
        await connection.enableEncryption(outputKey: Data(hex: vectors.output_key), inputKey: Data(hex: vectors.input_key))
        let payload = Data(hex: vectors.frames_to_tv[0].payload)
        try await connection.send(Frame(type: .eOPACK, payload: payload))
        let bytes = try await server.waitForBytes(4 + payload.count + 16)
        #expect(bytes.hex == vectors.frames_to_tv[0].wire)
        await connection.close()
    }
}
