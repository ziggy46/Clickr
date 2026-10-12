import CryptoKit
import Foundation

/// Release downloads are signed with an Ed25519 key that only the release workflow has. The
/// app carries the public key and won't install a disk image whose signature doesn't check
/// out, so a release can't be swapped for something else, even by someone who gets into the
/// GitHub account.
///
/// The signatures ship as a text file next to the downloads, one line per file:
///
///     <base64 signature>  <file name>
public enum UpdateSignatures {
    public static let fileName = "SIGNATURES.txt"

    /// Signatures by file name. Lines that don't parse are skipped.
    public static func parse(_ text: String) -> [String: Data] {
        var signatures: [String: Data] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2,
                  let signature = Data(base64Encoded: String(parts[0])),
                  signature.count == 64
            else { continue }
            signatures[parts[1].trimmingCharacters(in: .whitespaces)] = signature
        }
        return signatures
    }

    /// Whether `signature` is a valid signature of `data` by the key whose raw public bytes
    /// are base64 encoded in `publicKey`.
    public static func isValid(_ signature: Data, of data: Data, publicKey: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return false }
        return key.isValidSignature(signature, for: data)
    }
}
