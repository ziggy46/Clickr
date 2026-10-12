import Foundation

/// A value in Apple's OPACK binary format.
public enum OPACKValue: Hashable, Sendable {
    case null
    case bool(Bool)
    /// OPACK integers are unsigned on the wire (up to 8 bytes).
    case int(UInt64)
    case double(Double)
    case string(String)
    case data(Data)
    case uuid(UUID)
    /// Tag 0x06. pyatv reads it as an 8-byte little-endian integer, so keep the raw value.
    case absoluteTime(UInt64)
    case array([OPACKValue])
    /// Keys stay in order so encoding is deterministic.
    case dictionary([Entry])

    public struct Entry: Hashable, Sendable {
        public var key: OPACKValue
        public var value: OPACKValue

        public init(_ key: OPACKValue, _ value: OPACKValue) {
            self.key = key
            self.value = value
        }
    }
}

// MARK: - Reading values

extension OPACKValue {
    /// Looks up a string key in a dictionary.
    public subscript(key: String) -> OPACKValue? {
        guard case .dictionary(let entries) = self else { return nil }
        return entries.first { $0.key == .string(key) }?.value
    }

    public var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var intValue: UInt64? {
        if case .int(let value) = self { value } else { nil }
    }

    public var dataValue: Data? {
        if case .data(let value) = self { value } else { nil }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    public var doubleValue: Double? {
        if case .double(let value) = self { value } else { nil }
    }

    public var arrayValue: [OPACKValue]? {
        if case .array(let value) = self { value } else { nil }
    }

    public var dictionaryEntries: [Entry]? {
        if case .dictionary(let value) = self { value } else { nil }
    }
}

// MARK: - Literals

extension OPACKValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: UInt64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: OPACKValue...) { self = .array(elements) }

    /// Dictionary literals keep their written order.
    public init(dictionaryLiteral elements: (OPACKValue, OPACKValue)...) {
        self = .dictionary(elements.map { Entry($0.0, $0.1) })
    }
}
