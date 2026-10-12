import CryptoKit
import Foundation
import OPACK
import os
import SRP
import TLV8

/// The pair-setup exchange (HAP-style, carried in Companion PS_Start / PS_Next frames).
/// This type builds and reads the messages; sending them is the session's job.
///
///   M1  ->  start (TV shows a PIN)          M2 <- salt + SRP public key
///   M3  ->  SRP public key + proof          M4 <- TV's proof
///   M5  ->  our long-term key, encrypted    M6 <- TV's long-term key, encrypted
public struct PairSetup: Sendable {
    public enum PairingError: Error, Equatable {
        /// The TV rejected the PIN.
        case wrongPIN
        /// Too many attempts; the TV wants us to wait this many seconds.
        case backOff(seconds: Int)
        /// Some other error code from the TV (HAP error codes: 4 max peers, 6 unavailable, 7 busy).
        case device(code: UInt8)
        /// The TV's M4 proof didn't match, so it doesn't know the PIN.
        case serverProofMismatch
        /// A reply was missing a field or had the wrong step number.
        case badResponse(String)
    }

    /// Shown in the TV's list of paired remotes.
    public static let displayName = "Clickr"

    public let pairingID: Data
    let signingKey: Curve25519.Signing.PrivateKey
    let srp: SRPClient

    private var salt = Data()
    private var serverPublicKey = Data()
    private var proof: SRPProof?
    private let log = Logger(subsystem: "com.ziggy46.clickr", category: "Pairing")

    /// A new pairing with a fresh identifier and key pair.
    public init() {
        self.init(
            pairingID: Data(UUID().uuidString.utf8),
            signingKey: Curve25519.Signing.PrivateKey(),
            srp: SRPClient()
        )
    }

    init(pairingID: Data, signingKey: Curve25519.Signing.PrivateKey, srp: SRPClient) {
        self.pairingID = pairingID
        self.signingKey = signingKey
        self.srp = srp
    }

    // MARK: - Messages

    /// M1, sent in a PS_Start frame.
    public func startRequest() -> OPACKValue {
        Self.envelope(TLV8([.init(.method, Data([0])), .init(.seqNo, Data([1]))]))
    }

    /// Reads M2 (salt and the TV's SRP public key).
    public mutating func handleStartResponse(_ message: OPACKValue) throws {
        let tlv = try Self.pairingData(message, expectedStep: 2)
        guard let salt = tlv[.salt], let key = tlv[.publicKey] else { throw PairingError.badResponse("M2 missing salt or key") }
        self.salt = salt
        serverPublicKey = key
    }

    /// M3, sent in a PS_Next frame.
    public mutating func proofRequest(pin: String) throws -> OPACKValue {
        let proof = try srp.respond(salt: salt, serverPublicKey: serverPublicKey, pin: pin)
        self.proof = proof
        return Self.envelope(TLV8([
            .init(.seqNo, Data([3])),
            .init(.publicKey, srp.publicKey),
            .init(.proof, proof.clientProof),
        ]))
    }

    /// Reads M4 and checks the TV's proof.
    public func handleProofResponse(_ message: OPACKValue) throws {
        let tlv = try Self.pairingData(message, expectedStep: 4)
        guard let serverProof = tlv[.proof], let proof else { throw PairingError.badResponse("M4 missing proof") }
        guard proof.verifyServerProof(serverProof) else { throw PairingError.serverProofMismatch }
    }

    /// M5, sent in a PS_Next frame.
    public func exchangeRequest() throws -> OPACKValue {
        guard let proof else { throw PairingError.badResponse("M5 before M4") }
        let encrypted = try Self.encryptedExchange(
            sessionKey: proof.sessionKey, pairingID: pairingID, signingKey: signingKey, name: Self.displayName
        )
        return Self.envelope(TLV8([.init(.seqNo, Data([5])), .init(.encryptedData, encrypted)]))
    }

    /// Reads M6 and returns the credentials to store.
    public func handleExchangeResponse(_ message: OPACKValue) throws -> PairingCredentials {
        let tlv = try Self.pairingData(message, expectedStep: 6)
        guard let encrypted = tlv[.encryptedData], let proof else { throw PairingError.badResponse("M6 missing data") }
        let accessory = try Self.decryptExchange(encrypted, sessionKey: proof.sessionKey)
        if !accessory.signatureIsValid {
            // The channel is already authenticated by the M4 proof, and pyatv doesn't check
            // this at all, so log rather than fail. Pair-verify checks the TV's key later.
            log.error("TV's M6 signature didn't verify; keeping the pairing")
        }
        return PairingCredentials(
            deviceID: pairingID,
            ourLTSK: signingKey.rawRepresentation,
            ourLTPK: signingKey.publicKey.rawRepresentation,
            theirLTPK: accessory.publicKey,
            theirID: accessory.identifier
        )
    }

    // MARK: - Crypto for M5 and M6

    static func encryptedExchange(
        sessionKey: Data, pairingID: Data, signingKey: Curve25519.Signing.PrivateKey, name: String
    ) throws -> Data {
        let controllerX = hkdfBytes(sessionKey, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
        let publicKey = signingKey.publicKey.rawRepresentation
        let signature = try signingKey.signature(for: controllerX + pairingID + publicKey)
        let subTLV = TLV8([
            .init(.identifier, pairingID),
            .init(.publicKey, publicKey),
            .init(.signature, signature),
            .init(.name, OPACK.encode(["name": .string(name)])),
        ])
        let key = hkdf(sessionKey, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let box = try ChaChaPoly.seal(subTLV.encoded(), using: key, nonce: pairingNonce("PS-Msg05"))
        return box.ciphertext + box.tag
    }

    struct Accessory {
        let identifier: Data
        let publicKey: Data
        let signatureIsValid: Bool
    }

    static func decryptExchange(_ encrypted: Data, sessionKey: Data) throws -> Accessory {
        guard encrypted.count >= 16 else { throw PairingError.badResponse("M6 too short") }
        let key = hkdf(sessionKey, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let box = try ChaChaPoly.SealedBox(
            nonce: pairingNonce("PS-Msg06"),
            ciphertext: encrypted.dropLast(16),
            tag: encrypted.suffix(16)
        )
        let tlv = try TLV8(decoding: ChaChaPoly.open(box, using: key))
        guard let identifier = tlv[.identifier], let publicKey = tlv[.publicKey], let signature = tlv[.signature] else {
            throw PairingError.badResponse("M6 missing identifier, key or signature")
        }
        let accessoryX = hkdfBytes(sessionKey, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
        let isValid = (try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey))
            .map { $0.isValidSignature(signature, for: accessoryX + identifier + publicKey) } ?? false
        return Accessory(identifier: identifier, publicKey: publicKey, signatureIsValid: isValid)
    }

    // MARK: - Helpers

    /// `{"_pd": <tlv>, "_pwTy": 1}`; the session adds `_x`.
    static func envelope(_ tlv: TLV8) -> OPACKValue {
        ["_pd": .data(tlv.encoded()), "_pwTy": 1]
    }

    /// Pulls the TLV out of a reply, turning an error TLV into a PairingError.
    static func pairingData(_ message: OPACKValue, expectedStep: UInt8) throws -> TLV8 {
        guard let data = message["_pd"]?.dataValue else { throw PairingError.badResponse("no _pd in reply") }
        let tlv = try TLV8(decoding: data)
        if let code = tlv[.error]?.first {
            switch code {
            case 2: throw PairingError.wrongPIN
            case 3: throw PairingError.backOff(seconds: Int(tlv[.backOff].map(littleEndianInt) ?? 0))
            default: throw PairingError.device(code: code)
            }
        }
        guard tlv[.seqNo] == Data([expectedStep]) else {
            throw PairingError.badResponse("expected M\(expectedStep), got \(tlv[.seqNo]?.first.map(String.init) ?? "none")")
        }
        return tlv
    }

    static func hkdf(_ secret: Data, salt: String, info: String) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data(salt.utf8),
            info: Data(info.utf8),
            outputByteCount: 32
        )
    }

    static func hkdfBytes(_ secret: Data, salt: String, info: String) -> Data {
        hkdf(secret, salt: salt, info: info).withUnsafeBytes { Data($0) }
    }

    /// Pairing nonces are short ASCII labels with 4 zero bytes in front (12 bytes total).
    static func pairingNonce(_ label: String) -> ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: Data(count: 4) + Data(label.utf8))
    }

    private static func littleEndianInt(_ data: Data) -> UInt64 {
        data.reversed().reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
