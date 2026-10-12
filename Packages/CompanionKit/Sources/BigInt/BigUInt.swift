import Foundation

/// An arbitrary-precision unsigned integer, just big enough for SRP.
public struct BigUInt: Hashable, Sendable {
    /// Little-endian 64-bit limbs with no zero limbs at the top. Zero has no limbs.
    public private(set) var limbs: [UInt64]

    public init() {
        limbs = []
    }

    public init(_ value: UInt64) {
        limbs = value == 0 ? [] : [value]
    }

    public init(limbs: [UInt64]) {
        self.limbs = limbs
        normalize()
    }

    private mutating func normalize() {
        while limbs.last == 0 {
            limbs.removeLast()
        }
    }

    public var isZero: Bool { limbs.isEmpty }

    public var isOdd: Bool { (limbs.first ?? 0) & 1 == 1 }

    /// Number of significant bits; 0 for zero.
    public var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return limbs.count * 64 - top.leadingZeroBitCount
    }

    func bit(_ index: Int) -> Bool {
        let limb = index / 64
        guard limb < limbs.count else { return false }
        return (limbs[limb] >> UInt64(index % 64)) & 1 == 1
    }
}

// MARK: - Bytes and hex

extension BigUInt {
    /// Reads a big-endian byte string. Leading zero bytes are fine.
    public init<Bytes: Collection<UInt8>>(bigEndian bytes: Bytes) {
        var limbs = [UInt64](repeating: 0, count: (bytes.count + 7) / 8)
        for (offset, byte) in bytes.reversed().enumerated() {
            limbs[offset / 8] |= UInt64(byte) << UInt64(8 * (offset % 8))
        }
        self.init(limbs: limbs)
    }

    /// Big-endian bytes, left-padded with zeros to `length` if given. Without a length the
    /// result is as short as possible (but at least one byte).
    public func bigEndianBytes(paddedTo length: Int? = nil) -> Data {
        let minimal = max(1, (bitWidth + 7) / 8)
        let count = max(minimal, length ?? 0)
        var bytes = [UInt8](repeating: 0, count: count)
        for index in 0..<min(minimal, limbs.count * 8) {
            bytes[count - 1 - index] = UInt8(truncatingIfNeeded: limbs[index / 8] >> UInt64(8 * (index % 8)))
        }
        return Data(bytes)
    }

    public init?(hex: String) {
        var limbs: [UInt64] = []
        var end = hex.endIndex
        while end > hex.startIndex {
            let start = hex.index(end, offsetBy: -16, limitedBy: hex.startIndex) ?? hex.startIndex
            guard let limb = UInt64(hex[start..<end], radix: 16) else { return nil }
            limbs.append(limb)
            end = start
        }
        self.init(limbs: limbs)
    }

    /// Lowercase hex without leading zeros; "0" for zero.
    public var hex: String {
        guard let top = limbs.last else { return "0" }
        return limbs.dropLast().reversed().reduce(String(top, radix: 16)) { result, limb in
            let digits = String(limb, radix: 16)
            return result + String(repeating: "0", count: 16 - digits.count) + digits
        }
    }
}

extension BigUInt: CustomStringConvertible, ExpressibleByIntegerLiteral {
    public var description: String { "0x" + hex }

    public init(integerLiteral value: UInt64) {
        self.init(value)
    }
}

// MARK: - Comparison

extension BigUInt: Comparable {
    public static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        compare(lhs.limbs[...], rhs.limbs[...]) < 0
    }

    /// Compares limb arrays that may have zero limbs at the top.
    static func compare(_ lhs: ArraySlice<UInt64>, _ rhs: ArraySlice<UInt64>) -> Int {
        let count = max(lhs.count, rhs.count)
        for index in stride(from: count - 1, through: 0, by: -1) {
            let left = index < lhs.count ? lhs[lhs.startIndex + index] : 0
            let right = index < rhs.count ? rhs[rhs.startIndex + index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }
}

// MARK: - Arithmetic

extension BigUInt {
    public static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        let (long, short) = lhs.limbs.count >= rhs.limbs.count ? (lhs.limbs, rhs.limbs) : (rhs.limbs, lhs.limbs)
        var result = long
        var carry = false
        for index in 0..<long.count {
            let addend = index < short.count ? short[index] : 0
            if !carry && index >= short.count { break }
            let (sum1, overflow1) = result[index].addingReportingOverflow(addend)
            let (sum2, overflow2) = sum1.addingReportingOverflow(carry ? 1 : 0)
            result[index] = sum2
            carry = overflow1 || overflow2
        }
        if carry { result.append(1) }
        return BigUInt(limbs: result)
    }

    /// Requires `lhs >= rhs`.
    public static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        precondition(lhs >= rhs, "BigUInt subtraction would go negative")
        var result = lhs.limbs
        var borrow = false
        for index in 0..<result.count {
            let subtrahend = index < rhs.limbs.count ? rhs.limbs[index] : 0
            if !borrow && index >= rhs.limbs.count { break }
            let (difference1, underflow1) = result[index].subtractingReportingOverflow(subtrahend)
            let (difference2, underflow2) = difference1.subtractingReportingOverflow(borrow ? 1 : 0)
            result[index] = difference2
            borrow = underflow1 || underflow2
        }
        return BigUInt(limbs: result)
    }

    public static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        guard !lhs.isZero, !rhs.isZero else { return BigUInt() }
        var result = [UInt64](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for (i, left) in lhs.limbs.enumerated() {
            var carry: UInt64 = 0
            for (j, right) in rhs.limbs.enumerated() {
                (result[i + j], carry) = multiplyAdd(left, right, result[i + j], carry)
            }
            result[i + rhs.limbs.count] = carry
        }
        return BigUInt(limbs: result)
    }

    public static func / (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        lhs.quotientAndRemainder(dividingBy: rhs).quotient
    }

    public static func % (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        lhs.quotientAndRemainder(dividingBy: rhs).remainder
    }

    public static func += (lhs: inout BigUInt, rhs: BigUInt) { lhs = lhs + rhs }
    public static func -= (lhs: inout BigUInt, rhs: BigUInt) { lhs = lhs - rhs }
    public static func *= (lhs: inout BigUInt, rhs: BigUInt) { lhs = lhs * rhs }

    /// Returns (low, high) of a * b + c + d, which always fits in 128 bits.
    @inline(__always)
    static func multiplyAdd(_ a: UInt64, _ b: UInt64, _ c: UInt64, _ d: UInt64) -> (low: UInt64, high: UInt64) {
        let (high, low) = a.multipliedFullWidth(by: b)
        let (low1, carry1) = low.addingReportingOverflow(c)
        let (low2, carry2) = low1.addingReportingOverflow(d)
        return (low2, high &+ (carry1 ? 1 : 0) &+ (carry2 ? 1 : 0))
    }
}
