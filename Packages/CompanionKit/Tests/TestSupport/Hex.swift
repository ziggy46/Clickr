import Foundation

extension Data {
    /// Parses a hex string such as "e3435f". Traps on bad input, which is fine in tests.
    public init(hex: String) {
        precondition(hex.count.isMultiple(of: 2), "odd-length hex string")
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    public var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
