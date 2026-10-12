import BigInt
import CryptoKit
import Foundation
import Security

/// The client side of SRP-6a with SHA-512 and the RFC 5054 3072-bit group, as used by
/// HomeKit-style pair-setup. The username is always "Pair-Setup" and the password is the
/// PIN shown on the TV.
///
/// The math matches srptools (what pyatv uses), with one difference: the salt is hashed as
/// the raw bytes the TV sent, where srptools drops leading zero bytes. See BUILD_PLAN.md 3.5.
public struct SRPClient: Sendable {
    public static let username = "Pair-Setup"

    public enum SRPError: Error, Equatable {
        /// B mod N is zero, which would make the shared secret predictable.
        case invalidServerPublicKey
        /// u is zero, which would let the server skip the password check.
        case invalidScrambler
    }

    let privateKey: BigUInt
    let publicKeyValue: BigUInt

    /// A, sent to the TV in pair-setup M3.
    public var publicKey: Data { publicKeyValue.bigEndianBytes() }

    /// Uses a fixed private key. Only for tests.
    public init(privateKey: Data) {
        self.privateKey = BigUInt(bigEndian: privateKey)
        publicKeyValue = SRPGroup.generator.power(self.privateKey, modulus: SRPGroup.prime)
    }

    /// Picks a random 32-byte private key. It retries the rare key whose A would start with
    /// a zero byte, so A is always exactly 384 bytes and there's no question of whether
    /// either side pads it.
    public init() {
        while true {
            var bytes = [UInt8](repeating: 0, count: 32)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            precondition(status == errSecSuccess, "no random bytes")
            let candidate = SRPClient(privateKey: Data(bytes))
            if candidate.publicKeyValue.bitWidth > 8 * (SRPGroup.byteCount - 1) {
                self = candidate
                return
            }
        }
    }

    /// Works out the session key and proofs from the TV's salt and public key (pair-setup M2).
    public func respond(salt: Data, serverPublicKey: Data, pin: String) throws -> SRPProof {
        let N = SRPGroup.prime
        let g = SRPGroup.generator
        let B = BigUInt(bigEndian: serverPublicKey)
        guard !(B % N).isZero else { throw SRPError.invalidServerPublicKey }

        let k = Self.hashInt(N.bigEndianBytes(), Self.padded(g))
        let x = Self.hashInt(salt, Self.hash(Data("\(Self.username):\(pin)".utf8)))
        let u = Self.hashInt(Self.padded(publicKeyValue), Self.padded(B))
        guard !u.isZero else { throw SRPError.invalidScrambler }

        // S = (B - k * g^x) ^ (a + u * x) mod N
        let kv = (k * g.power(x, modulus: N)) % N
        let base = ((B % N) + N - kv) % N
        let S = base.power(privateKey + u * x, modulus: N)
        let K = Self.hash(S.bigEndianBytes())

        // M1 = H(H(N) xor H(g) | H(I) | s | A | B | K). Both fixed hashes start with a
        // nonzero byte, so hashing them in full is the same as srptools' minimal form.
        let groupHash = Data(zip(Self.hash(N.bigEndianBytes()), Self.hash(g.bigEndianBytes())).map { $0 ^ $1 })
        let A = publicKeyValue.bigEndianBytes()
        let M1 = Self.hash(groupHash, Self.hash(Data(Self.username.utf8)), salt, A, B.bigEndianBytes(), K)
        let M2 = Self.hash(A, M1, K)

        return SRPProof(sessionKey: K, clientProof: M1, expectedServerProof: M2,
                        values: .init(k: k, x: x, u: u, S: S))
    }

    static func hash(_ parts: Data...) -> Data {
        var hasher = SHA512()
        parts.forEach { hasher.update(data: $0) }
        return Data(hasher.finalize())
    }

    static func hashInt(_ parts: Data...) -> BigUInt {
        var hasher = SHA512()
        parts.forEach { hasher.update(data: $0) }
        return BigUInt(bigEndian: Data(hasher.finalize()))
    }

    static func padded(_ value: BigUInt) -> Data {
        value.bigEndianBytes(paddedTo: SRPGroup.byteCount)
    }
}

/// The result of SRP: the shared session key and the proofs both sides exchange.
public struct SRPProof: Sendable {
    /// K = H(S). Pair-setup derives its encryption and signing keys from this.
    public let sessionKey: Data
    /// M1, sent to the TV in pair-setup M3.
    public let clientProof: Data
    let expectedServerProof: Data

    /// Intermediate values, kept for tests.
    struct Values: Sendable {
        let k: BigUInt
        let x: BigUInt
        let u: BigUInt
        let S: BigUInt
    }
    let values: Values

    /// Checks the TV's M2 from pair-setup M4. A match proves the TV knew the PIN too.
    public func verifyServerProof(_ proof: Data) -> Bool {
        guard proof.count == expectedServerProof.count else { return false }
        // Constant time, so timing doesn't reveal how many bytes matched.
        return zip(proof, expectedServerProof).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
