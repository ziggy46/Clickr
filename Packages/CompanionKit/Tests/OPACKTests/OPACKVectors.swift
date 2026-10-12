import Foundation
import OPACK
import TestSupport

/// One entry from Vectors/opack.json, made by scripts/gen_vectors.py with pyatv.
struct OPACKVector: Decodable, Sendable, CustomStringConvertible {
    let name: String
    let value: OPACKValue
    let hex: String

    var description: String { name }

    enum CodingKeys: CodingKey { case name, value, hex }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        value = try container.decode(Node.self, forKey: .value).value
        hex = try container.decode(String.self, forKey: .hex)
    }

    static func load() -> [OPACKVector] {
        let url = Bundle.module.url(forResource: "opack", withExtension: "json", subdirectory: "Vectors")!
        return try! JSONDecoder().decode([OPACKVector].self, from: Data(contentsOf: url))
    }
}

/// The typed node format from gen_vectors.py.
private struct Node: Decodable {
    let value: OPACKValue

    enum CodingKeys: CodingKey { case t, v }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .t) {
        case "null":
            value = .null
        case "bool":
            value = .bool(try container.decode(Bool.self, forKey: .v))
        case "int":
            value = .int(UInt64(try container.decode(String.self, forKey: .v))!)
        case "double":
            let bits = Data(hex: try container.decode(String.self, forKey: .v))
            value = .double(Double(bitPattern: bits.reversed().reduce(0) { ($0 << 8) | UInt64($1) }))
        case "string":
            value = .string(try container.decode(String.self, forKey: .v))
        case "data":
            value = .data(Data(hex: try container.decode(String.self, forKey: .v)))
        case "uuid":
            value = .uuid(UUID(uuidString: try container.decode(String.self, forKey: .v))!)
        case "array":
            value = .array(try container.decode([Node].self, forKey: .v).map(\.value))
        case "dict":
            let pairs = try container.decode([[Node]].self, forKey: .v)
            value = .dictionary(pairs.map { OPACKValue.Entry($0[0].value, $0[1].value) })
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .t, in: container, debugDescription: "unknown node type \(other)")
        }
    }
}
