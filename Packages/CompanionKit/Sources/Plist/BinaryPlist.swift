import Foundation

/// The subset of Apple's binary property list format (bplist00) needed for the keyed
/// archives used by text input. Includes the UID type, which PropertyListSerialization
/// can read but gives no way to create or inspect.
public enum PlistValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    /// Real numbers. Dates are read as reals too (seconds since 2001).
    case real(Double)
    case string(String)
    case data(Data)
    /// A reference into a keyed archive's `$objects`.
    case uid(Int)
    case array([PlistValue])
    case dict([String: PlistValue])

    public subscript(key: String) -> PlistValue? {
        if case .dict(let entries) = self { entries[key] } else { nil }
    }
}

public enum BinaryPlist {
    public enum DecodingError: Error, Equatable {
        case notABinaryPlist
        case truncated
        case unsupportedObject(UInt8)
        case nestedTooDeeply
    }

    // MARK: - Writing

    public static func encode(_ root: PlistValue) -> Data {
        // Pass 1: give every value an index (root first). Containers remember the indexes
        // of their children; scalars are written straight away.
        enum Slot {
            case bytes(Data)
            case array([Int])
            case dict(keys: [Int], values: [Int])
        }
        var slots: [Slot] = [.bytes(Data())]
        var queue: [(index: Int, value: PlistValue)] = [(0, root)]

        func reserve(_ value: PlistValue) -> Int {
            slots.append(.bytes(Data()))
            queue.append((slots.count - 1, value))
            return slots.count - 1
        }

        var cursor = 0
        while cursor < queue.count {
            let (index, value) = queue[cursor]
            cursor += 1
            switch value {
            case .array(let items):
                slots[index] = .array(items.map(reserve))
            case .dict(let entries):
                let keys = entries.keys.sorted()
                let keyRefs = keys.map { reserve(.string($0)) }
                let valueRefs = keys.map { reserve(entries[$0]!) }
                slots[index] = .dict(keys: keyRefs, values: valueRefs)
            default:
                slots[index] = .bytes(scalar(value))
            }
        }

        // Pass 2: write objects, the offset table and the trailer.
        let refSize = slots.count < 256 ? 1 : 2
        var output = Data("bplist00".utf8)
        var offsets: [Int] = []
        for slot in slots {
            offsets.append(output.count)
            switch slot {
            case .bytes(let bytes):
                output += bytes
            case .array(let refs):
                output += marker(0xA0, count: refs.count)
                refs.forEach { output += bigEndian(UInt64($0), size: refSize) }
            case .dict(let keys, let values):
                output += marker(0xD0, count: keys.count)
                (keys + values).forEach { output += bigEndian(UInt64($0), size: refSize) }
            }
        }
        let tableOffset = output.count
        let offsetSize = tableOffset < 256 ? 1 : (tableOffset < 65_536 ? 2 : 4)
        offsets.forEach { output += bigEndian(UInt64($0), size: offsetSize) }
        output += Data(count: 6)
        output += Data([UInt8(offsetSize), UInt8(refSize)])
        output += bigEndian(UInt64(slots.count), size: 8)
        output += bigEndian(0, size: 8)
        output += bigEndian(UInt64(tableOffset), size: 8)
        return output
    }

    private static func scalar(_ value: PlistValue) -> Data {
        switch value {
        case .null:
            return Data([0x00])
        case .bool(let flag):
            return Data([flag ? 0x09 : 0x08])
        case .int(let number):
            if number >= 0, number <= 0xFF { return Data([0x10]) + bigEndian(UInt64(number), size: 1) }
            if number >= 0, number <= 0xFFFF { return Data([0x11]) + bigEndian(UInt64(number), size: 2) }
            if number >= 0, number <= 0xFFFF_FFFF { return Data([0x12]) + bigEndian(UInt64(number), size: 4) }
            return Data([0x13]) + bigEndian(UInt64(bitPattern: number), size: 8)
        case .string(let string):
            if string.allSatisfy(\.isASCII) {
                return marker(0x50, count: string.utf8.count) + Data(string.utf8)
            }
            let units = Array(string.utf16)
            return marker(0x60, count: units.count) + Data(units.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        case .real(let number):
            return Data([0x23]) + bigEndian(number.bitPattern, size: 8)
        case .data(let data):
            return marker(0x40, count: data.count) + data
        case .uid(let index):
            let size = index < 256 ? 1 : (index < 65_536 ? 2 : 4)
            return Data([0x80 | UInt8(size - 1)]) + bigEndian(UInt64(index), size: size)
        case .array, .dict:
            preconditionFailure("containers are written separately")
        }
    }

    /// Type nibble plus count; counts of 15 or more follow as an int object.
    private static func marker(_ type: UInt8, count: Int) -> Data {
        if count < 15 { return Data([type | UInt8(count)]) }
        return Data([type | 0x0F]) + scalar(.int(Int64(count)))
    }

    private static func bigEndian(_ value: UInt64, size: Int) -> Data {
        Data((0..<size).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) })
    }

    // MARK: - Reading

    public static func decode(_ data: Data) throws -> PlistValue {
        let bytes = [UInt8](data)
        guard bytes.count >= 40, bytes.starts(with: Array("bplist0".utf8)) else { throw DecodingError.notABinaryPlist }
        let trailer = bytes.suffix(32).map { $0 }
        let offsetSize = Int(trailer[6])
        let refSize = Int(trailer[7])
        let objectCount = Int(readInt(trailer[8..<16]))
        let topObject = Int(readInt(trailer[16..<24]))
        let tableOffset = Int(readInt(trailer[24..<32]))
        guard offsetSize > 0, refSize > 0, tableOffset + objectCount * offsetSize <= bytes.count - 32 else {
            throw DecodingError.truncated
        }
        let offsets = (0..<objectCount).map {
            Int(readInt(bytes[(tableOffset + $0 * offsetSize)..<(tableOffset + ($0 + 1) * offsetSize)]))
        }

        func object(_ index: Int, depth: Int) throws -> PlistValue {
            guard depth < 64 else { throw DecodingError.nestedTooDeeply }
            guard index < offsets.count, offsets[index] < bytes.count else { throw DecodingError.truncated }
            var position = offsets[index]

            func take(_ count: Int) throws -> ArraySlice<UInt8> {
                guard count >= 0, position + count <= bytes.count else { throw DecodingError.truncated }
                defer { position += count }
                return bytes[position..<position + count]
            }
            func count(_ low: UInt8) throws -> Int {
                guard low == 0x0F else { return Int(low) }
                let intMarker = try take(1).first!
                guard intMarker & 0xF0 == 0x10 else { throw DecodingError.unsupportedObject(intMarker) }
                return Int(readInt(try take(1 << Int(intMarker & 0x0F))))
            }

            let marker = try take(1).first!
            let low = marker & 0x0F
            switch marker >> 4 {
            case 0x0:
                switch marker {
                case 0x00: return .null
                case 0x08: return .bool(false)
                case 0x09: return .bool(true)
                default: throw DecodingError.unsupportedObject(marker)
                }
            case 0x1:
                return .int(Int64(bitPattern: readInt(try take(1 << Int(low)))))
            case 0x2:
                let raw = try take(1 << Int(low))
                return raw.count == 4
                    ? .real(Double(Float(bitPattern: UInt32(readInt(raw)))))
                    : .real(Double(bitPattern: readInt(raw)))
            case 0x3:
                return .real(Double(bitPattern: readInt(try take(8))))
            case 0x4:
                return .data(Data(try take(try count(low))))
            case 0x5:
                return .string(String(decoding: try take(try count(low)), as: UTF8.self))
            case 0x6:
                let raw = Array(try take(2 * (try count(low))))
                let units = stride(from: 0, to: raw.count, by: 2).map { UInt16(raw[$0]) << 8 | UInt16(raw[$0 + 1]) }
                return .string(String(decoding: units, as: UTF16.self))
            case 0x8:
                return .uid(Int(readInt(try take(Int(low) + 1))))
            case 0xA:
                let refs = try (0..<(try count(low))).map { _ in Int(readInt(try take(refSize))) }
                return .array(try refs.map { try object($0, depth: depth + 1) })
            case 0xD:
                let entries = try count(low)
                let keyRefs = try (0..<entries).map { _ in Int(readInt(try take(refSize))) }
                let valueRefs = try (0..<entries).map { _ in Int(readInt(try take(refSize))) }
                var result: [String: PlistValue] = [:]
                for (keyRef, valueRef) in zip(keyRefs, valueRefs) {
                    guard case .string(let key) = try object(keyRef, depth: depth + 1) else {
                        throw DecodingError.unsupportedObject(marker)
                    }
                    result[key] = try object(valueRef, depth: depth + 1)
                }
                return .dict(result)
            default:
                throw DecodingError.unsupportedObject(marker)
            }
        }

        return try object(topObject, depth: 0)
    }

    private static func readInt<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> UInt64 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
