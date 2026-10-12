extension BigUInt {
    /// Long division (Knuth, TAOCP vol. 2, 4.3.1, algorithm D) with 64-bit limbs.
    public func quotientAndRemainder(dividingBy divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        precondition(!divisor.isZero, "division by zero")
        if self < divisor { return (BigUInt(), self) }
        if divisor.limbs.count == 1 { return dividedBySingleLimb(divisor.limbs[0]) }

        let n = divisor.limbs.count
        let m = limbs.count - n
        // Shift so the divisor's top limb has its high bit set. That keeps each quotient
        // digit estimate at most two too large.
        let shift = divisor.limbs[n - 1].leadingZeroBitCount
        let v = Self.shiftLeft(divisor.limbs, by: shift, extraLimb: false)
        var u = Self.shiftLeft(limbs, by: shift, extraLimb: true)
        var quotient = [UInt64](repeating: 0, count: m + 1)

        for j in stride(from: m, through: 0, by: -1) {
            // Estimate the quotient digit from the top two limbs of the current window.
            var qhat: UInt64
            var rhat: UInt64
            var rhatOverflowed = false
            if u[j + n] >= v[n - 1] {
                // The real digit is 2^64 - 1 or less; start there.
                qhat = .max
                let (sum, overflow) = u[j + n - 1].addingReportingOverflow(v[n - 1])
                rhat = sum
                rhatOverflowed = overflow
            } else {
                (qhat, rhat) = v[n - 1].dividingFullWidth((u[j + n], u[j + n - 1]))
            }

            // Fix the estimate using the next limb of each, while rhat still fits.
            while !rhatOverflowed {
                let (productHigh, productLow) = qhat.multipliedFullWidth(by: v[n - 2])
                guard productHigh > rhat || (productHigh == rhat && productLow > u[j + n - 2]) else { break }
                qhat -= 1
                (rhat, rhatOverflowed) = rhat.addingReportingOverflow(v[n - 1])
            }

            // Subtract qhat * v from the window u[j...j+n].
            var carry: UInt64 = 0
            var borrow = false
            for i in 0..<n {
                let (low, high) = Self.multiplyAdd(qhat, v[i], carry, 0)
                carry = high
                let (difference1, underflow1) = u[i + j].subtractingReportingOverflow(low)
                let (difference2, underflow2) = difference1.subtractingReportingOverflow(borrow ? 1 : 0)
                u[i + j] = difference2
                borrow = underflow1 || underflow2
            }
            let (top1, underflow1) = u[j + n].subtractingReportingOverflow(carry)
            let (top2, underflow2) = top1.subtractingReportingOverflow(borrow ? 1 : 0)
            u[j + n] = top2

            if underflow1 || underflow2 {
                // qhat was still one too large: add v back once.
                qhat -= 1
                var addCarry = false
                for i in 0..<n {
                    let (sum1, overflow1) = u[i + j].addingReportingOverflow(v[i])
                    let (sum2, overflow2) = sum1.addingReportingOverflow(addCarry ? 1 : 0)
                    u[i + j] = sum2
                    addCarry = overflow1 || overflow2
                }
                u[j + n] &+= addCarry ? 1 : 0
            }
            quotient[j] = qhat
        }

        let remainder = Self.shiftRight(Array(u[0..<n]), by: shift)
        return (BigUInt(limbs: quotient), BigUInt(limbs: remainder))
    }

    private func dividedBySingleLimb(_ divisor: UInt64) -> (quotient: BigUInt, remainder: BigUInt) {
        var quotient = [UInt64](repeating: 0, count: limbs.count)
        var remainder: UInt64 = 0
        for index in stride(from: limbs.count - 1, through: 0, by: -1) {
            (quotient[index], remainder) = divisor.dividingFullWidth((remainder, limbs[index]))
        }
        return (BigUInt(limbs: quotient), BigUInt(remainder))
    }

    /// Shifts limbs left by fewer than 64 bits, optionally keeping the bits pushed out the top.
    private static func shiftLeft(_ limbs: [UInt64], by shift: Int, extraLimb: Bool) -> [UInt64] {
        var result = limbs
        if extraLimb { result.append(0) }
        guard shift > 0 else { return result }
        for index in stride(from: result.count - 1, through: 0, by: -1) {
            let lower = index > 0 ? result[index - 1] >> UInt64(64 - shift) : 0
            result[index] = (result[index] << UInt64(shift)) | lower
        }
        return result
    }

    private static func shiftRight(_ limbs: [UInt64], by shift: Int) -> [UInt64] {
        guard shift > 0 else { return limbs }
        var result = limbs
        for index in 0..<result.count {
            let upper = index + 1 < result.count ? result[index + 1] << UInt64(64 - shift) : 0
            result[index] = (result[index] >> UInt64(shift)) | upper
        }
        return result
    }
}
