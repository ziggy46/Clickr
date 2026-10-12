extension BigUInt {
    /// self^exponent mod modulus. Uses Montgomery multiplication when the modulus is odd
    /// (always the case for SRP), and plain square-and-multiply otherwise.
    public func power(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        precondition(!modulus.isZero, "modulus must be nonzero")
        if modulus == 1 { return BigUInt() }
        if modulus.isOdd {
            return Montgomery(modulus: modulus).power(self % modulus, exponent)
        }

        var result: BigUInt = 1
        let base = self % modulus
        for index in stride(from: exponent.bitWidth - 1, through: 0, by: -1) {
            result = (result * result) % modulus
            if exponent.bit(index) {
                result = (result * base) % modulus
            }
        }
        return result
    }
}

/// Montgomery arithmetic modulo an odd number N with n limbs, where R = 2^(64n).
private struct Montgomery {
    let modulus: [UInt64]
    let n: Int
    /// -N^-1 mod 2^64.
    let nPrime: UInt64
    /// R^2 mod N, for converting into Montgomery form.
    let rSquared: [UInt64]

    init(modulus: BigUInt) {
        self.modulus = modulus.limbs
        n = modulus.limbs.count

        // Newton's iteration doubles the correct low bits each step: 1 -> 2 -> ... -> 64.
        let n0 = modulus.limbs[0]
        var inverse: UInt64 = 1
        for _ in 0..<6 {
            inverse = inverse &* (2 &- n0 &* inverse)
        }
        nPrime = 0 &- inverse

        // R^2 mod N by doubling 1 a total of 2 * 64n times, reducing as we go.
        var value: BigUInt = 1
        for _ in 0..<(2 * 64 * n) {
            value = value + value
            if value >= modulus { value = value - modulus }
        }
        rSquared = Self.padded(value, to: n)
    }

    func power(_ base: BigUInt, _ exponent: BigUInt) -> BigUInt {
        var one = [UInt64](repeating: 0, count: n)
        one[0] = 1
        let montOne = multiply(rSquared, one)

        // Fixed 4-bit window: table[i] = base^i in Montgomery form.
        var table = [montOne, multiply(Self.padded(base, to: n), rSquared)]
        for index in 2..<16 {
            table.append(multiply(table[index - 1], table[1]))
        }

        var result = montOne
        let windows = (exponent.bitWidth + 3) / 4
        for window in stride(from: windows - 1, through: 0, by: -1) {
            for _ in 0..<4 {
                result = multiply(result, result)
            }
            var digit = 0
            for bit in 0..<4 where exponent.bit(window * 4 + bit) {
                digit |= 1 << bit
            }
            if digit != 0 {
                result = multiply(result, table[digit])
            }
        }
        return BigUInt(limbs: multiply(result, one))
    }

    /// a * b * R^-1 mod N, for a and b below N (CIOS method).
    func multiply(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var t = [UInt64](repeating: 0, count: n + 2)
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                modulus.withUnsafeBufferPointer { m in
                    t.withUnsafeMutableBufferPointer { t in
                        for i in 0..<n {
                            // t += a * b[i]
                            var carry: UInt64 = 0
                            let bi = b[i]
                            for j in 0..<n {
                                (t[j], carry) = BigUInt.multiplyAdd(a[j], bi, t[j], carry)
                            }
                            let (sum, overflow) = t[n].addingReportingOverflow(carry)
                            t[n] = sum
                            t[n + 1] = overflow ? 1 : 0

                            // Add a multiple of N that clears the low limb, then drop it.
                            let factor = t[0] &* nPrime
                            carry = BigUInt.multiplyAdd(factor, m[0], t[0], 0).high
                            for j in 1..<n {
                                (t[j - 1], carry) = BigUInt.multiplyAdd(factor, m[j], t[j], carry)
                            }
                            let (top, topOverflow) = t[n].addingReportingOverflow(carry)
                            t[n - 1] = top
                            t[n] = t[n + 1] &+ (topOverflow ? 1 : 0)
                        }
                    }
                }
            }
        }

        // The result is below 2N; subtract N once if needed.
        var result = Array(t[0..<n])
        if t[n] != 0 || BigUInt.compare(result[...], modulus[...]) >= 0 {
            var borrow = false
            for index in 0..<n {
                let (difference1, underflow1) = result[index].subtractingReportingOverflow(modulus[index])
                let (difference2, underflow2) = difference1.subtractingReportingOverflow(borrow ? 1 : 0)
                result[index] = difference2
                borrow = underflow1 || underflow2
            }
        }
        return result
    }

    private static func padded(_ value: BigUInt, to count: Int) -> [UInt64] {
        value.limbs + [UInt64](repeating: 0, count: count - value.limbs.count)
    }
}
