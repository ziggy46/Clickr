import CryptoKit
import Foundation

/// The encryption AirPlay uses on its TCP connections after pair-verify (HAP "session"
/// framing): plaintext is cut into blocks of up to 1024 bytes, each sent as a 2-byte
/// little-endian length, then the ChaCha20-Poly1305 ciphertext and tag. The length is the
/// AAD. The nonce is 4 zero bytes then a 64-bit little-endian counter per block, which is
/// laid out differently from Companion's FrameCipher, so the two are kept separate.
struct HAPFraming: Sendable {
    enum FramingError: Error {
        case authenticationFailed
    }

    static let maxBlock = 1024
    static let tagLength = 16

    private let outputKey: SymmetricKey
    private let inputKey: SymmetricKey
    private var outputCounter: UInt64 = 0
    private var inputCounter: UInt64 = 0
    private var buffer = Data()

    init(outputKey: Data, inputKey: Data) {
        self.outputKey = SymmetricKey(data: outputKey)
        self.inputKey = SymmetricKey(data: inputKey)
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        var output = Data()
        var start = plaintext.startIndex
        while start < plaintext.endIndex {
            let end = min(start + Self.maxBlock, plaintext.endIndex)
            let block = plaintext[start..<end]
            let length = Data([UInt8(block.count & 0xFF), UInt8(block.count >> 8)])
            let box = try ChaChaPoly.seal(block, using: outputKey, nonce: Self.nonce(outputCounter), authenticating: length)
            outputCounter += 1
            output += length + box.ciphertext + box.tag
            start = end
        }
        return output
    }

    /// Adds received bytes and returns whatever whole blocks they complete, decrypted.
    mutating func open(_ received: Data) throws -> Data {
        buffer += received
        var plaintext = Data()
        while buffer.count >= 2 {
            let length = Int(buffer[buffer.startIndex]) | Int(buffer[buffer.startIndex + 1]) << 8
            guard buffer.count >= 2 + length + Self.tagLength else { break }
            let lengthBytes = buffer.prefix(2)
            let body = buffer.dropFirst(2).prefix(length + Self.tagLength)
            do {
                let box = try ChaChaPoly.SealedBox(
                    nonce: Self.nonce(inputCounter),
                    ciphertext: body.prefix(length),
                    tag: body.suffix(Self.tagLength)
                )
                plaintext += try ChaChaPoly.open(box, using: inputKey, authenticating: lengthBytes)
            } catch {
                throw FramingError.authenticationFailed
            }
            inputCounter += 1
            buffer = Data(buffer.dropFirst(2 + length + Self.tagLength))
        }
        return plaintext
    }

    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 12)
        for index in 0..<8 {
            bytes[4 + index] = UInt8(truncatingIfNeeded: counter >> (8 * UInt64(index)))
        }
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}
