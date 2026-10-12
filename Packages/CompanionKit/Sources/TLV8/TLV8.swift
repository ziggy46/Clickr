import Foundation

/// HomeKit-style TLV8: one byte tag, one byte length, value. Values longer than 255 bytes
/// are split into consecutive chunks with the same tag.
public struct TLV8: Hashable, Sendable {
    public struct Tag: RawRepresentable, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public init(_ rawValue: UInt8) { self.rawValue = rawValue }

        // HAP tags, as named in pyatv.
        public static let method = Tag(0x00)
        public static let identifier = Tag(0x01)
        public static let salt = Tag(0x02)
        public static let publicKey = Tag(0x03)
        public static let proof = Tag(0x04)
        public static let encryptedData = Tag(0x05)
        public static let seqNo = Tag(0x06)
        public static let error = Tag(0x07)
        public static let backOff = Tag(0x08)
        public static let certificate = Tag(0x09)
        public static let signature = Tag(0x0A)
        public static let permissions = Tag(0x0B)
        public static let fragmentData = Tag(0x0C)
        public static let fragmentLast = Tag(0x0D)
        public static let name = Tag(0x11)
        public static let flags = Tag(0x13)
    }

    public struct Item: Hashable, Sendable {
        public var tag: Tag
        public var value: Data

        public init(_ tag: Tag, _ value: Data) {
            self.tag = tag
            self.value = value
        }
    }

    public enum DecodingError: Error, Equatable {
        case truncated
    }

    /// Items in order, one per tag.
    public private(set) var items: [Item]

    public init(_ items: [Item] = []) {
        self.items = []
        for item in items {
            self[item.tag] = item.value
        }
    }

    /// Parses TLV8 bytes. Repeated tags are joined into one value, like pyatv's `read_tlv`.
    public init(decoding data: Data) throws {
        let bytes = [UInt8](data)
        var items: [Item] = []
        var index = 0
        while index < bytes.count {
            guard index + 2 <= bytes.count else { throw DecodingError.truncated }
            let tag = Tag(bytes[index])
            let length = Int(bytes[index + 1])
            index += 2
            guard index + length <= bytes.count else { throw DecodingError.truncated }
            let value = Data(bytes[index..<index + length])
            index += length

            if let existing = items.firstIndex(where: { $0.tag == tag }) {
                items[existing].value += value
            } else {
                items.append(Item(tag, value))
            }
        }
        self.items = items
    }

    public subscript(tag: Tag) -> Data? {
        get { items.first { $0.tag == tag }?.value }
        set {
            if let index = items.firstIndex(where: { $0.tag == tag }) {
                if let newValue { items[index].value = newValue } else { items.remove(at: index) }
            } else if let newValue {
                items.append(Item(tag, newValue))
            }
        }
    }

    /// Encodes the items, splitting long values into 255-byte chunks. An empty value is
    /// written as tag + zero length (pyatv's `write_tlv` leaves it out instead).
    public func encoded() -> Data {
        var bytes: [UInt8] = []
        for item in items {
            let value = [UInt8](item.value)
            if value.isEmpty {
                bytes += [item.tag.rawValue, 0]
                continue
            }
            var start = 0
            while start < value.count {
                let end = min(start + 255, value.count)
                bytes += [item.tag.rawValue, UInt8(end - start)]
                bytes += value[start..<end]
                start = end
            }
        }
        return Data(bytes)
    }
}
