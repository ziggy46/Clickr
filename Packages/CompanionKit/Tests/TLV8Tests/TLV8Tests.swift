import Foundation
import TestSupport
import Testing
@testable import TLV8

/// One entry from Vectors/tlv8.json, made by scripts/gen_vectors.py with pyatv's write_tlv.
struct TLV8Vector: Decodable, Sendable, CustomStringConvertible {
    let name: String
    let items: [[Item]]
    let hex: String

    enum Item: Decodable, Sendable {
        case tag(UInt8)
        case value(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let tag = try? container.decode(UInt8.self) {
                self = .tag(tag)
            } else {
                self = .value(try container.decode(String.self))
            }
        }
    }

    var description: String { name }

    var tlv: TLV8 {
        TLV8(items.map { pair in
            guard case .tag(let tag) = pair[0], case .value(let hex) = pair[1] else { fatalError("bad vector") }
            return TLV8.Item(TLV8.Tag(tag), Data(hex: hex))
        })
    }

    static func load() -> [TLV8Vector] {
        let url = Bundle.module.url(forResource: "tlv8", withExtension: "json", subdirectory: "Vectors")!
        return try! JSONDecoder().decode([TLV8Vector].self, from: Data(contentsOf: url))
    }
}

@Suite struct TLV8VectorTests {
    static let vectors = TLV8Vector.load()

    @Test(arguments: vectors)
    func encodesLikePyatv(_ vector: TLV8Vector) {
        #expect(vector.tlv.encoded().hex == vector.hex)
    }

    @Test(arguments: vectors)
    func decodesPyatvBytes(_ vector: TLV8Vector) throws {
        #expect(try TLV8(decoding: Data(hex: vector.hex)) == vector.tlv)
    }
}

@Suite struct TLV8Tests {
    @Test func splitsLongValuesAndJoinsThemBack() throws {
        let key = Data((0..<384).map { UInt8(truncatingIfNeeded: $0) })
        let encoded = TLV8([.init(.seqNo, Data([3])), .init(.publicKey, key)]).encoded()

        // 3 bytes for SeqNo, then 255 + 129 bytes of key, each chunk with its own header.
        #expect(encoded.count == 3 + 2 + 255 + 2 + 129)
        #expect(Array(encoded[3...4]) == [0x03, 0xFF])
        #expect(Array(encoded[260...261]) == [0x03, 0x81])

        let decoded = try TLV8(decoding: encoded)
        #expect(decoded[.publicKey] == key)
        #expect(decoded[.seqNo] == Data([3]))
        #expect(decoded.items.count == 2)
    }

    @Test(arguments: [255, 256, 510, 511, 1000])
    func roundTripsLength(_ length: Int) throws {
        let value = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let encoded = TLV8([.init(.encryptedData, value)]).encoded()
        #expect(encoded.count == length + 2 * ((length + 254) / 255))
        #expect(try TLV8(decoding: encoded)[.encryptedData] == value)
    }

    @Test func emptyValueIsTagAndZeroLength() throws {
        let tlv = TLV8([.init(.method, Data())])
        #expect(tlv.encoded() == Data([0x00, 0x00]))
        #expect(try TLV8(decoding: Data([0x00, 0x00]))[.method] == Data())
    }

    @Test func keepsUnknownTags() throws {
        let decoded = try TLV8(decoding: Data([0x06, 0x01, 0x02, 0x1B, 0x01, 0x01]))
        #expect(decoded[TLV8.Tag(0x1B)] == Data([0x01]))
    }

    @Test func subscriptSetsReplacesAndRemoves() {
        var tlv = TLV8()
        tlv[.seqNo] = Data([1])
        tlv[.method] = Data([0])
        tlv[.seqNo] = Data([2])
        #expect(tlv.items.map(\.tag) == [.seqNo, .method])
        #expect(tlv[.seqNo] == Data([2]))
        tlv[.seqNo] = nil
        #expect(tlv.items.map(\.tag) == [.method])
    }

    @Test(arguments: ["06", "0602", "060201"])
    func rejectsTruncatedInput(hex: String) {
        #expect(throws: TLV8.DecodingError.truncated) { try TLV8(decoding: Data(hex: hex)) }
    }
}
