import Foundation

/// OPACK encoder and decoder.
///
/// Repeated values are written once and then referred to by index. Which values get an
/// index matters, because both sides have to count the same way. We follow pyatv's
/// decoder, which is what has been tested against real Apple TVs: every value except
/// null, bools, small inline ints (0...39), arrays and dictionaries gets the next index
/// the first time it appears. pyatv's encoder also counts containers and skips empty
/// strings, which its own decoder can't read back; see BUILD_PLAN.md 3.3.
public enum OPACK {
    public enum DecodingError: Error, Equatable {
        case truncated
        case unknownTag(UInt8)
        case invalidUTF8
        case invalidReference(Int)
        case unexpectedTerminator
        case trailingBytes(Int)
        case nestedTooDeeply
    }

    public static func encode(_ value: OPACKValue) -> Data {
        var encoder = Encoder()
        encoder.write(value)
        return Data(encoder.bytes)
    }

    /// Decodes one value and requires that it uses all of `data`.
    public static func decode(_ data: Data) throws -> OPACKValue {
        var decoder = Decoder(bytes: [UInt8](data))
        let value = try decoder.readValue(depth: 0)
        if decoder.position != decoder.bytes.count {
            throw DecodingError.trailingBytes(decoder.bytes.count - decoder.position)
        }
        return value
    }

    static let maxDepth = 64
}

extension OPACKValue {
    /// Whether the encoder gives this value a back-reference index (see `OPACK`).
    var takesReferenceSlot: Bool {
        switch self {
        case .null, .bool, .array, .dictionary: false
        case .int(let value): value > 0x27
        default: true
        }
    }
}

// MARK: - Encoding

private struct Encoder {
    var bytes: [UInt8] = []
    var references: [OPACKValue: Int] = [:]

    mutating func write(_ value: OPACKValue) {
        if value.takesReferenceSlot, let index = references[value] {
            writeReference(index)
            return
        }

        switch value {
        case .null:
            bytes.append(0x04)
        case .bool(let flag):
            bytes.append(flag ? 0x01 : 0x02)
        case .int(let number):
            switch number {
            case 0...0x27: bytes.append(UInt8(number) + 0x08)
            case ...0xFF: bytes.append(0x30); appendLittleEndian(number, count: 1)
            case ...0xFFFF: bytes.append(0x31); appendLittleEndian(number, count: 2)
            case ...0xFFFF_FFFF: bytes.append(0x32); appendLittleEndian(number, count: 4)
            default: bytes.append(0x33); appendLittleEndian(number, count: 8)
            }
        case .double(let number):
            bytes.append(0x36)
            appendLittleEndian(number.bitPattern, count: 8)
        case .string(let string):
            let utf8 = Array(string.utf8)
            writeLength(utf8.count, inlineBase: 0x40, sizedTags: [(0xFF, 0x61, 1), (0xFFFF, 0x62, 2), (0xFF_FFFF, 0x63, 3), (0xFFFF_FFFF, 0x64, 4)])
            bytes += utf8
        case .data(let data):
            writeLength(data.count, inlineBase: 0x70, sizedTags: [(0xFF, 0x91, 1), (0xFFFF, 0x92, 2), (0xFFFF_FFFF, 0x93, 4), (Int.max, 0x94, 8)])
            bytes += data
        case .uuid(let uuid):
            bytes.append(0x05)
            withUnsafeBytes(of: uuid.uuid) { bytes += $0 }
        case .absoluteTime(let raw):
            bytes.append(0x06)
            appendLittleEndian(raw, count: 8)
        case .array(let items):
            bytes.append(0xD0 + UInt8(min(items.count, 0xF)))
            items.forEach { write($0) }
            if items.count >= 0xF { bytes.append(0x03) }
        case .dictionary(let entries):
            bytes.append(0xE0 + UInt8(min(entries.count, 0xF)))
            for entry in entries {
                write(entry.key)
                write(entry.value)
            }
            if entries.count >= 0xF { bytes.append(0x03) }
        }

        if value.takesReferenceSlot {
            references[value] = references.count
        }
    }

    /// Short lengths (0...32) go in the tag itself; longer ones use the first sized tag that fits.
    private mutating func writeLength(_ length: Int, inlineBase: UInt8, sizedTags: [(max: Int, tag: UInt8, byteCount: Int)]) {
        if length <= 0x20 {
            bytes.append(inlineBase + UInt8(length))
            return
        }
        let sized = sizedTags.first { length <= $0.max }!
        bytes.append(sized.tag)
        appendLittleEndian(UInt64(length), count: sized.byteCount)
    }

    private mutating func writeReference(_ index: Int) {
        switch index {
        case 0...0x20: bytes.append(0xA0 + UInt8(index))
        case ...0xFF: bytes.append(0xC1); appendLittleEndian(UInt64(index), count: 1)
        case ...0xFFFF: bytes.append(0xC2); appendLittleEndian(UInt64(index), count: 2)
        case ...0xFF_FFFF: bytes.append(0xC3); appendLittleEndian(UInt64(index), count: 3)
        default: bytes.append(0xC4); appendLittleEndian(UInt64(index), count: 4)
        }
    }

    private mutating func appendLittleEndian(_ value: UInt64, count: Int) {
        for shift in 0..<count {
            bytes.append(UInt8(truncatingIfNeeded: value >> (8 * shift)))
        }
    }
}

// MARK: - Decoding

private struct Decoder {
    let bytes: [UInt8]
    var position = 0
    var references: [OPACKValue] = []
    var referenced: Set<OPACKValue> = []

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func readValue(depth: Int) throws -> OPACKValue {
        guard depth < OPACK.maxDepth else { throw OPACK.DecodingError.nestedTooDeeply }
        let tag = try readByte()
        let value: OPACKValue

        switch tag {
        case 0x01: value = .bool(true)
        case 0x02: value = .bool(false)
        case 0x03: throw OPACK.DecodingError.unexpectedTerminator
        case 0x04: value = .null
        case 0x05:
            let raw = Array(try read(16))
            value = .uuid(UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                                      raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15])))
        case 0x06: value = .absoluteTime(try readLittleEndian(8))
        case 0x08...0x2F: value = .int(UInt64(tag - 0x08))
        case 0x30...0x33: value = .int(try readLittleEndian(1 << Int(tag - 0x30)))
        case 0x35: value = .double(Double(Float(bitPattern: UInt32(try readLittleEndian(4)))))
        case 0x36: value = .double(Double(bitPattern: try readLittleEndian(8)))
        case 0x40...0x60: value = try readString(length: Int(tag - 0x40))
        case 0x61...0x64: value = try readString(length: try readLength(Int(tag - 0x60)))
        case 0x70...0x90: value = .data(Data(try read(Int(tag - 0x70))))
        case 0x91...0x94: value = .data(Data(try read(try readLength(1 << Int(tag - 0x91)))))
        case 0xA0...0xC0: return try reference(Int(tag - 0xA0))
        case 0xC1...0xC4: return try reference(try readLength(Int(tag - 0xC0)))
        case 0xD0...0xDF:
            var items: [OPACKValue] = []
            try readItems(count: tag & 0xF, depth: depth) { decoder in
                items.append(try decoder.readValue(depth: depth + 1))
            }
            value = .array(items)
        case 0xE0...0xEF:
            var entries: [OPACKValue.Entry] = []
            try readItems(count: tag & 0xF, depth: depth) { decoder in
                let key = try decoder.readValue(depth: depth + 1)
                entries.append(.init(key, try decoder.readValue(depth: depth + 1)))
            }
            value = .dictionary(entries)
        default:
            throw OPACK.DecodingError.unknownTag(tag)
        }

        // Goes by how the value was written, not its value: a sized int like 0x30 0x01
        // takes an index even though the encoder would write 1 inline.
        let takesSlot = switch value {
        case .null, .bool, .array, .dictionary: false
        default: !(0x08...0x2F).contains(tag)
        }
        if takesSlot, !referenced.contains(value) {
            references.append(value)
            referenced.insert(value)
        }
        return value
    }

    /// Counts below 15 are exact. 15 means "until a 0x03 terminator".
    private mutating func readItems(count: UInt8, depth: Int, _ readOne: (inout Decoder) throws -> Void) throws {
        if count == 0xF {
            while try peekByte() != 0x03 {
                try readOne(&self)
            }
            position += 1
        } else {
            for _ in 0..<count {
                try readOne(&self)
            }
        }
    }

    private func reference(_ index: Int) throws -> OPACKValue {
        guard references.indices.contains(index) else { throw OPACK.DecodingError.invalidReference(index) }
        return references[index]
    }

    private mutating func readString(length: Int) throws -> OPACKValue {
        guard let string = String(bytes: try read(length), encoding: .utf8) else {
            throw OPACK.DecodingError.invalidUTF8
        }
        return .string(string)
    }

    private func peekByte() throws -> UInt8 {
        guard position < bytes.count else { throw OPACK.DecodingError.truncated }
        return bytes[position]
    }

    private mutating func readByte() throws -> UInt8 {
        let byte = try peekByte()
        position += 1
        return byte
    }

    private mutating func read(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= bytes.count - position else { throw OPACK.DecodingError.truncated }
        defer { position += count }
        return bytes[position..<position + count]
    }

    /// A length or index; anything that doesn't fit in an Int can't be valid.
    private mutating func readLength(_ byteCount: Int) throws -> Int {
        guard let length = Int(exactly: try readLittleEndian(byteCount)) else { throw OPACK.DecodingError.truncated }
        return length
    }

    private mutating func readLittleEndian(_ count: Int) throws -> UInt64 {
        try read(count).reversed().reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
