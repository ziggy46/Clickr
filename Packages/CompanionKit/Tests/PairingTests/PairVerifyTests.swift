import CryptoKit
import Foundation
import OPACK
import TLV8
import TestSupport
import Testing
@testable import Pairing

/// Vectors/verify.json: pyatv's verify1/verify2 run with fixed keys.
struct VerifyVector: Decodable {
    let client_ltsk, client_id, atv_ltpk, atv_id, client_eph_private, client_eph_public: String
    let atv_eph_public, shared_secret, verify_key, m2_encrypted, m3_encrypted, output_key, input_key: String

    static let shared: VerifyVector = {
        let url = Bundle.module.url(forResource: "verify", withExtension: "json", subdirectory: "Vectors")!
        return try! JSONDecoder().decode(VerifyVector.self, from: Data(contentsOf: url))
    }()

    var credentials: PairingCredentials {
        let ltsk = Data(hex: client_ltsk)
        return PairingCredentials(
            deviceID: Data(client_id.utf8),
            ourLTSK: ltsk,
            ourLTPK: try! Curve25519.Signing.PrivateKey(rawRepresentation: ltsk).publicKey.rawRepresentation,
            theirLTPK: Data(hex: atv_ltpk),
            theirID: Data(atv_id.utf8)
        )
    }

    func verifier(credentials: PairingCredentials? = nil) -> PairVerify {
        PairVerify(
            credentials: credentials ?? self.credentials,
            ephemeralKey: try! .init(rawRepresentation: Data(hex: client_eph_private))
        )
    }

    var m2: OPACKValue {
        let tlv = TLV8([.init(.seqNo, Data([2])), .init(.publicKey, Data(hex: atv_eph_public)), .init(.encryptedData, Data(hex: m2_encrypted))])
        return ["_pd": .data(tlv.encoded())]
    }
}

@Suite struct PairVerifyTests {
    let vector = VerifyVector.shared

    @Test func startRequestCarriesEphemeralKey() throws {
        let m1 = vector.verifier().startRequest()
        let tlv = try TLV8(decoding: m1["_pd"]!.dataValue!)
        #expect(tlv[.seqNo] == Data([1]))
        #expect(tlv[.publicKey]?.hex == vector.client_eph_public)
        #expect(m1["_auTy"] == 4)
    }

    @Test func derivesPyatvTransportKeys() throws {
        var verifier = vector.verifier()
        _ = try verifier.respond(to: vector.m2)
        let keys = try verifier.transportKeys()
        #expect(keys.output.hex == vector.output_key)
        #expect(keys.input.hex == vector.input_key)
    }

    /// Our M3 signature is randomized (CryptoKit), so compare fields and check it verifies.
    @Test func buildsM3LikePyatv() throws {
        var verifier = vector.verifier()
        let m3 = try verifier.respond(to: vector.m2)
        let outer = try TLV8(decoding: m3["_pd"]!.dataValue!)
        #expect(outer[.seqNo] == Data([3]))
        let encrypted = try #require(outer[.encryptedData])
        #expect(encrypted.count == Data(hex: vector.m3_encrypted).count)

        let key = PairSetup.hkdf(Data(hex: vector.shared_secret), salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        let box = try ChaChaPoly.SealedBox(nonce: PairSetup.pairingNonce("PV-Msg03"), ciphertext: encrypted.dropLast(16), tag: encrypted.suffix(16))
        let inner = try TLV8(decoding: ChaChaPoly.open(box, using: key))
        #expect(inner[.identifier] == Data(vector.client_id.utf8))
        let signed = Data(hex: vector.client_eph_public) + Data(vector.client_id.utf8) + Data(hex: vector.atv_eph_public)
        let ourKey = try Curve25519.Signing.PublicKey(rawRepresentation: vector.credentials.ourLTPK)
        #expect(ourKey.isValidSignature(inner[.signature]!, for: signed))
    }

    @Test func rejectsAnotherDevice() {
        var credentials = vector.credentials
        credentials.theirID = Data("11:22:33:44:55:66".utf8)
        var verifier = vector.verifier(credentials: credentials)
        #expect(throws: PairVerify.VerifyError.wrongDevice) { try verifier.respond(to: vector.m2) }
    }

    @Test func rejectsWrongLongTermKey() {
        var credentials = vector.credentials
        credentials.theirLTPK = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        var verifier = vector.verifier(credentials: credentials)
        #expect(throws: PairVerify.VerifyError.badSignature) { try verifier.respond(to: vector.m2) }
    }

    @Test func finishSurfacesErrors() {
        let m4 = OPACKValue.dictionary([.init("_pd", .data(TLV8([.init(.seqNo, Data([4])), .init(.error, Data([2]))]).encoded()))])
        #expect(throws: PairSetup.PairingError.wrongPIN) { try vector.verifier().handleFinish(m4) }
    }
}
