import CryptoKit
import Foundation

/// ChaCha20-Poly1305 for frame payloads after pair-verify. Each direction has its own key
/// and counter. The nonce is the counter as a 12-byte little-endian number, and the AAD is
/// the 4-byte frame header, whose length already includes the 16-byte tag. Empty payloads
/// are sent as-is and don't use up a nonce.
public struct FrameCipher: Sendable {
    public enum CipherError: Error {
        case authenticationFailed
    }

    public static let tagLength = 16

    private let outputKey: SymmetricKey
    private let inputKey: SymmetricKey
    private var outputCounter: UInt64 = 0
    private var inputCounter: UInt64 = 0

    public init(outputKey: Data, inputKey: Data) {
        self.outputKey = SymmetricKey(data: outputKey)
        self.inputKey = SymmetricKey(data: inputKey)
    }

    /// Returns the payload to put on the wire (ciphertext + tag).
    public mutating func seal(_ payload: Data, type: FrameType) throws -> Data {
        guard !payload.isEmpty else { return payload }
        let header = FrameHeader(type: type, payloadLength: payload.count + Self.tagLength)
        let box = try ChaChaPoly.seal(payload, using: outputKey, nonce: Self.nonce(outputCounter), authenticating: header.bytes)
        outputCounter += 1
        return box.ciphertext + box.tag
    }

    /// Decrypts a received payload (ciphertext + tag).
    public mutating func open(_ payload: Data, type: FrameType) throws -> Data {
        guard !payload.isEmpty else { return payload }
        guard payload.count >= Self.tagLength else { throw CipherError.authenticationFailed }
        let header = FrameHeader(type: type, payloadLength: payload.count)
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: Self.nonce(inputCounter),
                ciphertext: payload.dropLast(Self.tagLength),
                tag: payload.suffix(Self.tagLength)
            )
            let plaintext = try ChaChaPoly.open(box, using: inputKey, authenticating: header.bytes)
            inputCounter += 1
            return plaintext
        } catch {
            throw CipherError.authenticationFailed
        }
    }

    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 12)
        for index in 0..<8 {
            bytes[index] = UInt8(truncatingIfNeeded: counter >> (8 * UInt64(index)))
        }
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}
