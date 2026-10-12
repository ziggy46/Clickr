import BigInt
import CryptoKit
import Foundation
import SRP

/// The TV's side of SRP, for tests. Same math and byte conventions as SRPClient
/// (and scripts/gen_vectors.py).
public struct FakeSRPServer {
    public let salt: Data
    public let publicKey: Data

    private let pin: String
    private let b: BigUInt
    private let v: BigUInt
    private let B: BigUInt

    public init(pin: String, salt: Data, privateKey: Data) {
        let N = SRPClient.groupPrime
        let g: BigUInt = 5
        self.pin = pin
        self.salt = salt
        b = BigUInt(bigEndian: privateKey)
        let x = BigUInt(bigEndian: Self.hash(salt, Self.hash(Data("Pair-Setup:\(pin)".utf8))))
        v = g.power(x, modulus: N)
        let k = BigUInt(bigEndian: Self.hash(N.bigEndianBytes(), g.bigEndianBytes(paddedTo: 384)))
        B = (k * v + g.power(b, modulus: N)) % N
        publicKey = B.bigEndianBytes()
    }

    /// The session key, the M1 proof a client with the right PIN sends, and the M2 reply.
    public func session(clientPublicKey: Data) -> (sessionKey: Data, clientProof: Data, serverProof: Data) {
        let N = SRPClient.groupPrime
        let g: BigUInt = 5
        let A = BigUInt(bigEndian: clientPublicKey)
        let u = BigUInt(bigEndian: Self.hash(A.bigEndianBytes(paddedTo: 384), B.bigEndianBytes(paddedTo: 384)))
        let S = (A * v.power(u, modulus: N)).power(b, modulus: N)
        let K = Self.hash(S.bigEndianBytes())
        let group = Data(zip(Self.hash(N.bigEndianBytes()), Self.hash(g.bigEndianBytes())).map { $0 ^ $1 })
        let M1 = Self.hash(group, Self.hash(Data("Pair-Setup".utf8)), salt, A.bigEndianBytes(), B.bigEndianBytes(), K)
        let M2 = Self.hash(A.bigEndianBytes(), M1, K)
        return (K, M1, M2)
    }

    static func hash(_ parts: Data...) -> Data {
        Data(SHA512.hash(data: parts.reduce(Data(), +)))
    }
}
