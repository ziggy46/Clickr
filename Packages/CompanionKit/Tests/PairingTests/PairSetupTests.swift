import BigInt
import CryptoKit
import Foundation
import OPACK
import SRP
import TLV8
import TestSupport
import Testing
@testable import Pairing

/// Vectors/pairing.json: pyatv's own pair-setup steps 3 and 4 run with fixed keys.
struct PairingVector: Decodable {
    let session_key, client_seed, client_public, pairing_id, name, encrypt_key, controller_x: String
    let m5_encrypted, atv_seed, atv_public, atv_id, m6_encrypted: String

    static let shared: PairingVector = {
        let url = Bundle.module.url(forResource: "pairing", withExtension: "json", subdirectory: "Vectors")!
        return try! JSONDecoder().decode(PairingVector.self, from: Data(contentsOf: url))
    }()
}

@Suite struct PairSetupCryptoTests {
    let vector = PairingVector.shared

    @Test func derivesTheSameKeysAsPyatv() {
        let sessionKey = Data(hex: vector.session_key)
        #expect(PairSetup.hkdfBytes(sessionKey, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info").hex == vector.encrypt_key)
        #expect(PairSetup.hkdfBytes(sessionKey, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info").hex == vector.controller_x)
    }

    @Test func readsPyatvM5() throws {
        // Decrypt pyatv's M5 with our nonce and key handling, and check its fields.
        let key = PairSetup.hkdf(Data(hex: vector.session_key), salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let encrypted = Data(hex: vector.m5_encrypted)
        let box = try ChaChaPoly.SealedBox(nonce: PairSetup.pairingNonce("PS-Msg05"), ciphertext: encrypted.dropLast(16), tag: encrypted.suffix(16))
        let tlv = try TLV8(decoding: ChaChaPoly.open(box, using: key))
        #expect(tlv[.identifier] == Data(vector.pairing_id.utf8))
        #expect(tlv[.publicKey]?.hex == vector.client_public)
    }

    /// CryptoKit's Ed25519 signatures are randomized, so our M5 can't match pyatv byte for
    /// byte. Everything else in it must, and the signature must verify.
    @Test func buildsM5LikePyatv() throws {
        let sessionKey = Data(hex: vector.session_key)
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(hex: vector.client_seed))
        let ours = try PairSetup.encryptedExchange(
            sessionKey: sessionKey, pairingID: Data(vector.pairing_id.utf8), signingKey: signingKey, name: vector.name
        )
        #expect(ours.count == Data(hex: vector.m5_encrypted).count)

        let key = PairSetup.hkdf(sessionKey, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let box = try ChaChaPoly.SealedBox(nonce: PairSetup.pairingNonce("PS-Msg05"), ciphertext: ours.dropLast(16), tag: ours.suffix(16))
        let tlv = try TLV8(decoding: ChaChaPoly.open(box, using: key))
        #expect(tlv.items.map(\.tag) == [.identifier, .publicKey, .signature, .name])
        #expect(tlv[.identifier] == Data(vector.pairing_id.utf8))
        #expect(tlv[.publicKey]?.hex == vector.client_public)
        #expect(try OPACK.decode(tlv[.name]!) == ["name": "Clickr"])

        let signed = Data(hex: vector.controller_x) + Data(vector.pairing_id.utf8) + Data(hex: vector.client_public)
        #expect(signingKey.publicKey.isValidSignature(tlv[.signature]!, for: signed))
    }

    @Test func readsM6() throws {
        let accessory = try PairSetup.decryptExchange(Data(hex: vector.m6_encrypted), sessionKey: Data(hex: vector.session_key))
        #expect(accessory.identifier == Data(vector.atv_id.utf8))
        #expect(accessory.publicKey.hex == vector.atv_public)
        #expect(accessory.signatureIsValid)
    }

    @Test func rejectsTamperedM6() {
        var encrypted = Data(hex: vector.m6_encrypted)
        encrypted[3] ^= 0x01
        #expect(throws: (any Error).self) {
            try PairSetup.decryptExchange(encrypted, sessionKey: Data(hex: vector.session_key))
        }
    }
}

@Suite struct PairSetupMessageTests {
    @Test func startRequestMatchesPyatv() {
        var message = PairSetup().startRequest()
        if case .dictionary(var entries) = message {
            entries.append(.init("_x", 0))
            message = .dictionary(entries)
        }
        // pyatv's PS_Start payload from Milestone 2.
        #expect(OPACK.encode(message).hex == "e3435f706476000100060101455f7077547909425f7808")
    }

    @Test func runsM2ThroughM4AgainstFakeTV() throws {
        let srp = SRPClient(privateKey: Data(hex: "2b51b4c8b3e2b9ae0f9a13bb6c35b0ae4c4ebd7ecb21d5b25c06dd3c1f00a5d9"))
        var setup = PairSetup(pairingID: Data("test".utf8), signingKey: .init(), srp: srp)
        let tv = FakeSRPServer(pin: "1234", salt: Data(repeating: 0x11, count: 16), privateKey: Data(repeating: 0x22, count: 32))

        try setup.handleStartResponse(Self.reply(step: 2, [.init(.salt, tv.salt), .init(.publicKey, tv.publicKey)]))
        let m3 = try setup.proofRequest(pin: "1234")
        let m3TLV = try TLV8(decoding: m3["_pd"]!.dataValue!)
        #expect(m3TLV[.seqNo] == Data([3]))
        #expect(m3TLV[.publicKey] == srp.publicKey)
        #expect(m3["_pwTy"] == 1)

        let session = tv.session(clientPublicKey: srp.publicKey)
        #expect(m3TLV[.proof] == session.clientProof)
        try setup.handleProofResponse(Self.reply(step: 4, [.init(.proof, session.serverProof)]))
    }

    @Test func badServerProofIsRejected() throws {
        var setup = PairSetup(pairingID: Data("test".utf8), signingKey: .init(), srp: SRPClient(privateKey: Data(repeating: 9, count: 32)))
        try setup.handleStartResponse(Self.reply(step: 2, [.init(.salt, Data(repeating: 1, count: 16)), .init(.publicKey, Data(repeating: 7, count: 384))]))
        _ = try setup.proofRequest(pin: "1234")
        #expect(throws: PairSetup.PairingError.serverProofMismatch) {
            try setup.handleProofResponse(Self.reply(step: 4, [.init(.proof, Data(repeating: 0, count: 64))]))
        }
    }

    @Test(arguments: [
        ([TLV8.Item(.seqNo, Data([4])), .init(.error, Data([2]))], PairSetup.PairingError.wrongPIN),
        ([.init(.seqNo, Data([2])), .init(.error, Data([3])), .init(.backOff, Data([0x2C, 0x01]))], .backOff(seconds: 300)),
        ([.init(.seqNo, Data([2])), .init(.error, Data([6]))], .device(code: 6)),
        ([.init(.seqNo, Data([4]))], .badResponse("expected M2, got 4")),
    ])
    func mapsErrors(items: [TLV8.Item], error: PairSetup.PairingError) {
        var setup = PairSetup()
        #expect(throws: error) { try setup.handleStartResponse(Self.reply(items)) }
    }

    static func reply(step: UInt8, _ items: [TLV8.Item]) -> OPACKValue {
        reply([.init(.seqNo, Data([step]))] + items)
    }

    static func reply(_ items: [TLV8.Item]) -> OPACKValue {
        ["_pd": .data(TLV8(items).encoded())]
    }
}
