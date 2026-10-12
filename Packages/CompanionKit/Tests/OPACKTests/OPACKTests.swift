import Foundation
import TestSupport
import Testing
@testable import OPACK

@Suite struct PyatvVectorTests {
    static let vectors = OPACKVector.load()

    @Test func haveEnoughVectors() {
        #expect(Self.vectors.count >= 10)
    }

    @Test(arguments: vectors)
    func encodesLikePyatv(_ vector: OPACKVector) {
        #expect(OPACK.encode(vector.value).hex == vector.hex)
    }

    @Test(arguments: vectors)
    func decodesPyatvBytes(_ vector: OPACKVector) throws {
        #expect(try OPACK.decode(Data(hex: vector.hex)) == vector.value)
    }
}

@Suite struct RoundTripTests {
    @Test(arguments: [
        OPACKValue.null, true, false,
        0, 39, 40, 255, 256, 65_535, 65_536, 4_294_967_295, 4_294_967_296, .int(.max),
        1.5, -0.25, .double(.greatestFiniteMagnitude),
        "", "a", "Café ’s Room · Den", .string(String(repeating: "z", count: 300)),
        .data(Data()), .data(Data([0, 1, 2])), .data(Data(repeating: 7, count: 70_000)),
        .uuid(UUID(uuidString: "0F8E7D6C-5B4A-4938-8271-605F4E3D2C1B")!),
        .absoluteTime(0x0123_4567_89AB_CDEF),
        [], [1, "two", 3.0, nil], .array(Array(repeating: "same", count: 40)),
        [:], ["b": 1, "a": 2], ["outer": ["inner": ["deep": [1, 2, ["x": "y"]]]]],
    ] as [OPACKValue])
    func roundTrips(_ value: OPACKValue) throws {
        #expect(try OPACK.decode(OPACK.encode(value)) == value)
    }

    @Test func keepsDictionaryOrder() throws {
        let value: OPACKValue = ["z": 1, "a": 2, "m": 3]
        let keys = try OPACK.decode(OPACK.encode(value)).dictionaryEntries?.map(\.key)
        #expect(keys == ["z", "a", "m"])
    }

    @Test func longCollectionsUseTerminator() {
        let fourteen = OPACK.encode(.array((0..<14).map { .int($0) }))
        let fifteen = OPACK.encode(.array((0..<15).map { .int($0) }))
        #expect(fourteen.first == 0xDE && fourteen.last != 0x03)
        #expect(fifteen.first == 0xDF && fifteen.last == 0x03)
    }
}

@Suite struct BackReferenceTests {
    @Test func repeatedStringBecomesReference() {
        #expect(OPACK.encode(["a", "a"]).hex == "d24161a0")
    }

    // pyatv's encoder gives the nested dict an index here, so it would write a4 and
    // its own decoder would read back "c". We don't count containers, so "hello" is a3.
    @Test func containersDoNotTakeAnIndex() throws {
        let value: OPACKValue = ["a": ["x": 1], "b": "hello", "c": "hello"]
        let bytes = OPACK.encode(value)
        #expect(bytes.hex == "e34161e141780941624568656c6c6f4163a3")
        #expect(try OPACK.decode(bytes) == value)
    }

    // Same story for empty strings: they take an index when decoding, so they must when encoding.
    @Test func emptyStringsTakeAnIndex() throws {
        let value: OPACKValue = ["a": "", "b": "xx", "c": "xx"]
        let bytes = OPACK.encode(value)
        #expect(bytes.hex == "e341614041624278784163a3")
        #expect(try OPACK.decode(bytes) == value)
    }

    @Test func decodesPyatvEncoderOutputTheWayPyatvDecodes() throws {
        // pyatv.pack({"a": "", "b": "xx", "c": "xx"}); pyatv.unpack reads "c" back as "b".
        #expect(try OPACK.decode(Data(hex: "e341614041624278784163a2")) == ["a": "", "b": "xx", "c": "b"])
    }

    @Test func smallIntsAndFlagsTakeNoIndex() {
        // 5, true and nil are single bytes and never referenced; "k" is index 0.
        #expect(OPACK.encode([5, true, nil, "k", 5, "k"]).hex == "d60d0104416b0da0")
    }

    @Test func farReferencesUseSizedTags() throws {
        let strings = (0..<300).map { OPACKValue.string("s\($0)") }
        let value = OPACKValue.array(strings + [strings[33], strings[256]])
        let bytes = OPACK.encode(value)
        // Index 33 is past the one-byte range (0xA0...0xC0), index 256 needs two bytes.
        #expect(bytes.suffix(6).hex == "c121c2000103")
        #expect(try OPACK.decode(bytes) == value)
    }

    // From pyatv's test_unpack_uid: C1...C4 are followed by 1...4 index bytes.
    @Test(arguments: [
        "df30013002c10103",
        "df30013002c2010003",
        "df30013002c301000003",
        "df30013002c40100000003",
    ])
    func decodesSizedReferences(hex: String) throws {
        #expect(try OPACK.decode(Data(hex: hex)) == [1, 2, 2])
    }
}

@Suite struct DecodingTests {
    @Test func readsFloat32() throws {
        #expect(try OPACK.decode(Data(hex: "350000c03f")) == 1.5)
    }

    @Test func readsAbsoluteTimeRaw() throws {
        #expect(try OPACK.decode(Data(hex: "06efcdab8967452301")) == .absoluteTime(0x0123_4567_89AB_CDEF))
    }

    @Test func subscriptFindsStringKeys() throws {
        let value = try OPACK.decode(Data(hex: "e3435f706476000100060101455f7077547909425f7808"))
        #expect(value["_pwTy"] == 1)
        #expect(value["_x"]?.intValue == 0)
        #expect(value["_pd"]?.dataValue == Data([0x00, 0x01, 0x00, 0x06, 0x01, 0x01]))
        #expect(value["missing"] == nil)
    }

    @Test(arguments: [
        ("", OPACK.DecodingError.truncated),
        ("43666f", .truncated),
        ("e2416109", .truncated),
        ("07", .unknownTag(0x07)),
        ("f0", .unknownTag(0xF0)),
        ("a5", .invalidReference(5)),
        ("03", .unexpectedTerminator),
        ("0909", .trailingBytes(1)),
        ("41ff", .invalidUTF8),
        ("93ffffffff", .truncated),
    ])
    func rejectsBadInput(hex: String, error: OPACK.DecodingError) {
        #expect(throws: error) { try OPACK.decode(Data(hex: hex)) }
    }

    @Test func rejectsDeepNesting() {
        let bytes = Data(repeating: 0xD1, count: 100) + Data([0x09])
        #expect(throws: OPACK.DecodingError.nestedTooDeeply) { try OPACK.decode(bytes) }
    }
}
