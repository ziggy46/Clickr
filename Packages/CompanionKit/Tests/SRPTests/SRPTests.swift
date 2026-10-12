import BigInt
import Foundation
import TestSupport
import Testing
@testable import SRP

/// One entry from Vectors/srp.json, made by scripts/gen_vectors.py. Vectors marked
/// `matches_srptools` were checked against pyatv's srptools; the others are edge cases
/// where we deliberately differ (see BUILD_PLAN.md 3.5).
struct SRPVector: Decodable, Sendable, CustomStringConvertible {
    let name, pin, salt, a, B, A, k, x, u, S, K, M1, M2: String
    let matches_srptools: Bool

    var description: String { name }

    static func load() -> [SRPVector] {
        let url = Bundle.module.url(forResource: "srp", withExtension: "json", subdirectory: "Vectors")!
        return try! JSONDecoder().decode([SRPVector].self, from: Data(contentsOf: url))
    }
}

@Suite struct SRPVectorTests {
    static let vectors = SRPVector.load()

    @Test func coversTheEdgeCases() {
        let names = Set(Self.vectors.map(\.name))
        #expect(names.isSuperset(of: ["salt_leading_zero", "A_leading_zero", "B_leading_zero", "S_leading_zero"]))
        #expect(Self.vectors.filter(\.matches_srptools).count >= 5)
    }

    @Test(arguments: vectors)
    func matchesVector(_ vector: SRPVector) throws {
        let client = SRPClient(privateKey: BigUInt(hex: vector.a)!.bigEndianBytes())
        #expect(client.publicKey.hex == vector.A)

        let proof = try client.respond(salt: Data(hex: vector.salt), serverPublicKey: Data(hex: vector.B), pin: vector.pin)
        #expect(proof.values.k.hex == vector.k)
        #expect(proof.values.x.hex == vector.x)
        #expect(proof.values.u.hex == vector.u)
        #expect(proof.values.S.bigEndianBytes().hex == vector.S)
        #expect(proof.sessionKey.hex == vector.K)
        #expect(proof.clientProof.hex == vector.M1)
        #expect(proof.verifyServerProof(Data(hex: vector.M2)))
    }
}

@Suite struct SRPClientTests {
    let vector = SRPVectorTests.vectors[0]

    func proof(pin: String? = nil) throws -> SRPProof {
        let client = SRPClient(privateKey: BigUInt(hex: vector.a)!.bigEndianBytes())
        return try client.respond(salt: Data(hex: vector.salt), serverPublicKey: Data(hex: vector.B), pin: pin ?? vector.pin)
    }

    @Test func rejectsWrongServerProof() throws {
        let proof = try proof()
        var wrong = Data(hex: vector.M2)
        wrong[0] ^= 1
        #expect(!proof.verifyServerProof(wrong))
        #expect(!proof.verifyServerProof(Data(hex: vector.M2).dropLast()))
        #expect(!proof.verifyServerProof(Data()))
    }

    @Test func wrongPinGivesDifferentProof() throws {
        #expect(try proof(pin: "1235").clientProof != proof().clientProof)
    }

    // pyatv turns the PIN into an int first, so "0042" would be hashed as "42". We keep it as typed.
    @Test func leadingZeroPinIsHashedAsTyped() throws {
        #expect(try proof(pin: "0042").clientProof != proof(pin: "42").clientProof)
    }

    @Test(arguments: [Data(), Data([0]), SRPGroup.prime.bigEndianBytes(), (SRPGroup.prime * 2).bigEndianBytes()])
    func rejectsServerKeyThatIsZeroModN(_ key: Data) {
        let client = SRPClient(privateKey: Data(repeating: 7, count: 32))
        #expect(throws: SRPClient.SRPError.invalidServerPublicKey) {
            try client.respond(salt: Data(repeating: 1, count: 16), serverPublicKey: key, pin: "1234")
        }
    }

    @Test func randomClientsHaveFullLengthPublicKeys() {
        for _ in 0..<20 {
            let client = SRPClient()
            #expect(client.publicKey.count == 384)
            #expect(client.publicKey[0] != 0)
        }
    }
}
