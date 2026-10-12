import Foundation

/// Just enough of the protobuf wire format for MRP: write fields in the order given, and
/// read a message into its raw fields so callers can pick out what they need by number.
public struct ProtoWriter: Sendable {
    public private(set) var data = Data()

    public init() {}

    public mutating func varint(_ field: Int, _ value: UInt64) {
        key(field, wireType: 0)
        data += Self.varint(value)
    }

    /// int32/int64. Negative values take 10 bytes, as in protobuf.
    public mutating func int(_ field: Int, _ value: Int64) {
        varint(field, UInt64(bitPattern: value))
    }

    public mutating func bool(_ field: Int, _ value: Bool) {
        varint(field, value ? 1 : 0)
    }

    public mutating func double(_ field: Int, _ value: Double) {
        key(field, wireType: 1)
        data += littleEndian(value.bitPattern, count: 8)
    }

    public mutating func float(_ field: Int, _ value: Float) {
        key(field, wireType: 5)
        data += littleEndian(UInt64(value.bitPattern), count: 4)
    }

    public mutating func bytes(_ field: Int, _ value: Data) {
        key(field, wireType: 2)
        data += Self.varint(UInt64(value.count))
        data += value
    }

    public mutating func string(_ field: Int, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    public mutating func message(_ field: Int, _ value: ProtoWriter) {
        bytes(field, value.data)
    }

    private mutating func key(_ field: Int, wireType: UInt64) {
        data += Self.varint(UInt64(field) << 3 | wireType)
    }

    public static func varint(_ value: UInt64) -> Data {
        var value = value
        var bytes = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    private func littleEndian(_ value: UInt64, count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) })
    }
}

/// A decoded protobuf message: its fields in wire order, values left raw.
public struct ProtoMessage: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)
    }

    public enum DecodingError: Error, Equatable {
        case truncated
        case unsupportedWireType(Int)
    }

    public var fields: [(number: Int, value: Value)]

    public init() {
        fields = []
    }

    public init(decoding data: Data) throws {
        var reader = ProtoReader(bytes: [UInt8](data))
        var fields: [(Int, Value)] = []
        while !reader.isAtEnd {
            let key = try reader.varint()
            let number = Int(key >> 3)
            switch key & 7 {
            case 0: fields.append((number, .varint(try reader.varint())))
            case 1: fields.append((number, .fixed64(try reader.littleEndian(8))))
            case 2: fields.append((number, .bytes(Data(try reader.take(Int(try reader.varint()))))))
            case 5: fields.append((number, .fixed32(UInt32(try reader.littleEndian(4)))))
            case let other: throw DecodingError.unsupportedWireType(Int(other))
            }
        }
        self.fields = fields
    }

    public static func == (lhs: ProtoMessage, rhs: ProtoMessage) -> Bool {
        lhs.fields.map(\.number) == rhs.fields.map(\.number) && lhs.fields.map(\.value) == rhs.fields.map(\.value)
    }

    // MARK: - Reading fields (the last occurrence wins, as protobuf does for singular fields)

    public func has(_ number: Int) -> Bool {
        fields.contains { $0.number == number }
    }

    private func last(_ number: Int) -> Value? {
        fields.last { $0.number == number }?.value
    }

    public func uint(_ number: Int) -> UInt64? {
        if case .varint(let value) = last(number) { value } else { nil }
    }

    public func int(_ number: Int) -> Int64? {
        uint(number).map { Int64(bitPattern: $0) }
    }

    public func bool(_ number: Int) -> Bool? {
        uint(number).map { $0 != 0 }
    }

    public func double(_ number: Int) -> Double? {
        if case .fixed64(let bits) = last(number) { Double(bitPattern: bits) } else { nil }
    }

    public func float(_ number: Int) -> Float? {
        if case .fixed32(let bits) = last(number) { Float(bitPattern: bits) } else { nil }
    }

    public func data(_ number: Int) -> Data? {
        if case .bytes(let data) = last(number) { data } else { nil }
    }

    public func string(_ number: Int) -> String? {
        data(number).map { String(decoding: $0, as: UTF8.self) }
    }

    public func message(_ number: Int) -> ProtoMessage? {
        data(number).flatMap { try? ProtoMessage(decoding: $0) }
    }

    /// Every occurrence of a repeated message field.
    public func messages(_ number: Int) -> [ProtoMessage] {
        fields.compactMap { field in
            guard field.number == number, case .bytes(let data) = field.value else { return nil }
            return try? ProtoMessage(decoding: data)
        }
    }

    /// Writes the fields back out unchanged.
    public func encoded() -> Data {
        var writer = ProtoWriter()
        for (number, value) in fields {
            switch value {
            case .varint(let raw): writer.varint(number, raw)
            case .fixed64(let raw): writer.double(number, Double(bitPattern: raw))
            case .bytes(let raw): writer.bytes(number, raw)
            case .fixed32(let raw): writer.float(number, Float(bitPattern: raw))
            }
        }
        return writer.data
    }

    /// Replaces every occurrence of a field with one length-delimited value.
    public mutating func set(_ number: Int, message: ProtoMessage) {
        fields.removeAll { $0.number == number }
        fields.append((number, .bytes(message.encoded())))
    }

    /// Like protobuf's MergeFrom for the singular fields MRP uses: each field present in
    /// `other` replaces this message's value for that field.
    public mutating func merge(_ other: ProtoMessage) {
        let replaced = Set(other.fields.map(\.number))
        fields.removeAll { replaced.contains($0.number) }
        fields += other.fields
    }
}

struct ProtoReader {
    let bytes: [UInt8]
    var position = 0

    var isAtEnd: Bool { position >= bytes.count }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard position < bytes.count, shift < 64 else { throw ProtoMessage.DecodingError.truncated }
            let byte = bytes[position]
            position += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, position + count <= bytes.count else { throw ProtoMessage.DecodingError.truncated }
        defer { position += count }
        return bytes[position..<position + count]
    }

    mutating func littleEndian(_ count: Int) throws -> UInt64 {
        try take(count).reversed().reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
