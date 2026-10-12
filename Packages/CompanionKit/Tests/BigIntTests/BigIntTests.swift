import BigInt
import Foundation
import TestSupport
import Testing

// Only uses the public API, so it also builds with `swift test -c release`.

/// Vectors/bigint.json, made by scripts/gen_vectors.py with Python ints.
struct BigIntVectors: Decodable {
    let add: [[String]]
    let sub: [[String]]
    let mul: [[String]]
    let divmod: [[String]]
    let modpow: [[String]]
    let bytes: [[String]]

    static let shared: BigIntVectors = {
        let url = Bundle.module.url(forResource: "bigint", withExtension: "json", subdirectory: "Vectors")!
        return try! JSONDecoder().decode(BigIntVectors.self, from: Data(contentsOf: url))
    }()
}

private func big(_ hex: String) -> BigUInt {
    BigUInt(hex: hex)!
}

private let isOptimizedBuild: Bool = {
    #if DEBUG
    false
    #else
    true
    #endif
}()

@Suite struct BigIntVectorTests {
    let vectors = BigIntVectors.shared

    @Test func addition() {
        for vector in vectors.add {
            let (a, b, sum) = (vector[0], vector[1], vector[2])
            #expect(big(a) + big(b) == big(sum), "\(a) + \(b)")
            #expect(big(b) + big(a) == big(sum), "\(b) + \(a)")
        }
    }

    @Test func subtraction() {
        for vector in vectors.sub {
            let (a, b, difference) = (vector[0], vector[1], vector[2])
            #expect(big(a) - big(b) == big(difference), "\(a) - \(b)")
        }
    }

    @Test func multiplication() {
        for vector in vectors.mul {
            let (a, b, product) = (vector[0], vector[1], vector[2])
            #expect(big(a) * big(b) == big(product), "\(a) * \(b)")
        }
    }

    @Test func division() {
        for vector in vectors.divmod {
            let (a, b, quotient, remainder, kind) = (vector[0], vector[1], vector[2], vector[3], vector[4])
            let result = big(a).quotientAndRemainder(dividingBy: big(b))
            #expect(result.quotient == big(quotient), "\(kind): \(a) / \(b)")
            #expect(result.remainder == big(remainder), "\(kind): \(a) % \(b)")
        }
    }

    @Test func divisionCoversRareBranches() {
        let kinds = Set(vectors.divmod.map { $0[4] }.flatMap { $0.split(separator: "+").map(String.init) })
        #expect(kinds.isSuperset(of: ["add_back", "qhat_max", "qhat_correction"]))
    }

    @Test func modularPower() {
        for vector in vectors.modpow {
            let (base, exponent, modulus, result) = (vector[0], vector[1], vector[2], vector[3])
            #expect(big(base).power(big(exponent), modulus: big(modulus)) == big(result), "\(base)^\(exponent) mod \(modulus)")
        }
    }

    @Test func bigEndianBytes() {
        for vector in vectors.bytes {
            let (hex, value) = (vector[0], vector[1])
            let bytes = Data(hex: hex)
            #expect(BigUInt(bigEndian: bytes) == big(value))
            #expect(big(value).bigEndianBytes(paddedTo: bytes.count) == bytes)
        }
    }
}

@Suite struct BigIntTests {
    @Test func hexRoundTrips() {
        for hex in ["0", "1", "ff", "10000000000000000", "123456789abcdef0123456789abcdef"] {
            #expect(big(hex).hex == hex)
        }
        #expect(BigUInt(hex: "00ff") == 255)
        #expect(BigUInt(hex: "xyz") == nil)
    }

    @Test func minimalBytes() {
        #expect(BigUInt().bigEndianBytes() == Data([0]))
        #expect(BigUInt(0x0102).bigEndianBytes() == Data([1, 2]))
        #expect(BigUInt(0x0102).bigEndianBytes(paddedTo: 4) == Data([0, 0, 1, 2]))
        #expect(BigUInt(bigEndian: Data([0, 0, 1, 2])) == 0x0102)
    }

    @Test func comparesAcrossLimbCounts() {
        #expect(big("10000000000000000") > big("ffffffffffffffff"))
        #expect(BigUInt(5) < 6)
        #expect(BigUInt(limbs: [7, 0, 0]) == 7)
    }

    @Test func modPowMatchesSquareAndMultiplyForOddModulus() {
        // Montgomery (odd) vs the plain path (even modulus 2m gives the same result mod m).
        let modulus = big("f123456789abcdef0123456789abcdef1")
        let base = big("abcdef")
        let exponent = big("10001")
        let viaEven = base.power(exponent, modulus: modulus * 2) % modulus
        #expect(base.power(exponent, modulus: modulus) == viaEven)
    }

    /// Plan target: a 3072-bit modPow in under 200 ms in a release build.
    /// Run with `swift test -c release --filter BigIntTests`.
    @Test(.enabled(if: isOptimizedBuild, "only meaningful in a release build"))
    func modPow3072IsFastEnough() {
        let modulus = big(String(repeating: "f", count: 768))  // odd, 3072 bits
        let base = big(String(repeating: "c3", count: 383))
        let exponent = big(String(repeating: "a5", count: 384)) // full 3072-bit exponent

        let clock = ContinuousClock()
        var result = BigUInt()
        let elapsed = clock.measure {
            result = base.power(exponent, modulus: modulus)
        }
        print("3072-bit modPow took \(elapsed)")
        #expect(!result.isZero)
        #expect(elapsed < .milliseconds(200))
    }
}
