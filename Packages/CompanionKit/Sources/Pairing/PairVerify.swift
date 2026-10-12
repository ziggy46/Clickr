import CryptoKit
import Foundation
import OPACK
import TLV8

/// Pair-verify, run on every connection to prove both sides still hold the keys from
/// pair-setup and to agree on fresh encryption keys (PV_Start / PV_Next frames).
///
///   M1  ->  our ephemeral X25519 key        M2 <- TV's ephemeral key + encrypted signature
///   M3  ->  our encrypted signature         M4 <- done
public struct PairVerify: Sendable {
    public enum VerifyError: Error, Equatable {
        /// The TV answered with a different identifier than the one we paired with.
        case wrongDevice
        /// The TV's signature didn't verify with its long-term key from pair-setup.
        case badSignature
    }

    let credentials: PairingCredentials
    let ephemeralKey: Curve25519.KeyAgreement.PrivateKey
    private var sharedSecret: Data?

    public init(credentials: PairingCredentials) {
        self.init(credentials: credentials, ephemeralKey: .init())
    }

    init(credentials: PairingCredentials, ephemeralKey: Curve25519.KeyAgreement.PrivateKey) {
        self.credentials = credentials
        self.ephemeralKey = ephemeralKey
    }

    /// M1, sent in a PV_Start frame.
    public func startRequest() -> OPACKValue {
        let tlv = TLV8([.init(.seqNo, Data([1])), .init(.publicKey, ephemeralKey.publicKey.rawRepresentation)])
        return ["_pd": .data(tlv.encoded()), "_auTy": 4]
    }

    /// Reads M2, checks the TV is the one we paired with, and returns M3 (PV_Next frame).
    public mutating func respond(to message: OPACKValue) throws -> OPACKValue {
        let tlv = try PairSetup.pairingData(message, expectedStep: 2)
        guard let theirPublic = tlv[.publicKey], let encrypted = tlv[.encryptedData], encrypted.count >= 16 else {
            throw PairSetup.PairingError.badResponse("M2 missing key or data")
        }

        let shared = try ephemeralKey.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: theirPublic))
            .withUnsafeBytes { Data($0) }
        sharedSecret = shared
        let key = PairSetup.hkdf(shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")

        let box = try ChaChaPoly.SealedBox(
            nonce: PairSetup.pairingNonce("PV-Msg02"),
            ciphertext: encrypted.dropLast(16),
            tag: encrypted.suffix(16)
        )
        let inner = try TLV8(decoding: ChaChaPoly.open(box, using: key))
        guard let identifier = inner[.identifier], let signature = inner[.signature] else {
            throw PairSetup.PairingError.badResponse("M2 missing identifier or signature")
        }
        guard identifier == credentials.theirID else { throw VerifyError.wrongDevice }

        let ourPublic = ephemeralKey.publicKey.rawRepresentation
        let theirLongTermKey = try Curve25519.Signing.PublicKey(rawRepresentation: credentials.theirLTPK)
        guard theirLongTermKey.isValidSignature(signature, for: theirPublic + identifier + ourPublic) else {
            throw VerifyError.badSignature
        }

        let ourLongTermKey = try Curve25519.Signing.PrivateKey(rawRepresentation: credentials.ourLTSK)
        let ourSignature = try ourLongTermKey.signature(for: ourPublic + credentials.deviceID + theirPublic)
        let reply = TLV8([.init(.identifier, credentials.deviceID), .init(.signature, ourSignature)])
        let sealed = try ChaChaPoly.seal(reply.encoded(), using: key, nonce: PairSetup.pairingNonce("PV-Msg03"))

        let m3 = TLV8([.init(.seqNo, Data([3])), .init(.encryptedData, sealed.ciphertext + sealed.tag)])
        return ["_pd": .data(m3.encoded())]
    }

    /// Reads M4; throws if the TV rejected us.
    public func handleFinish(_ message: OPACKValue) throws {
        _ = try PairSetup.pairingData(message, expectedStep: 4)
    }

    /// The transport keys: (ours to the TV, the TV's to us). Empty salt, as in pyatv.
    public func transportKeys() throws -> (output: Data, input: Data) {
        guard let sharedSecret else { throw PairSetup.PairingError.badResponse("keys before M2") }
        return (
            PairSetup.hkdfBytes(sharedSecret, salt: "", info: "ClientEncrypt-main"),
            PairSetup.hkdfBytes(sharedSecret, salt: "", info: "ServerEncrypt-main")
        )
    }
}
