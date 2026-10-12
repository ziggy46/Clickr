// Signs release disk images so Clickr can check its own updates. Run with `swift`.
//
//   swift scripts/update-signing.swift generate-key <file>
//       Makes a new key pair, writes the private key to <file> (which must not exist yet)
//       and prints the public key. The public key goes in App/Info.plist as
//       ClickrUpdatePublicKey; the private key goes in the UPDATE_SIGNING_KEY secret.
//
//   UPDATE_SIGNING_KEY=... swift scripts/update-signing.swift sign <public key> <files...>
//       Prints a SIGNATURES.txt line for each file. Stops if the key in UPDATE_SIGNING_KEY
//       doesn't match <public key>, so a release can't go out signed with the wrong key.
//
// Keys are base64 of the raw 32-byte Ed25519 keys.

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "generate-key":
    guard arguments.count == 2 else { fail("usage: generate-key <file>") }
    let path = arguments[1]
    guard !FileManager.default.fileExists(atPath: path) else { fail("\(path) already exists") }
    let key = Curve25519.Signing.PrivateKey()
    let created = FileManager.default.createFile(
        atPath: path,
        contents: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8),
        attributes: [.posixPermissions: 0o600]
    )
    guard created else { fail("couldn't write \(path)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "sign":
    guard arguments.count >= 3 else { fail("usage: sign <public key> <files...>") }
    let secret = (ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !secret.isEmpty else { fail("UPDATE_SIGNING_KEY isn't set") }
    guard let keyData = Data(base64Encoded: secret),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    else { fail("UPDATE_SIGNING_KEY isn't a valid key") }
    guard key.publicKey.rawRepresentation.base64EncodedString() == arguments[1] else {
        fail("UPDATE_SIGNING_KEY doesn't match the public key in the app")
    }
    for path in arguments.dropFirst(2) {
        guard let data = FileManager.default.contents(atPath: path) else { fail("couldn't read \(path)") }
        guard let signature = try? key.signature(for: data),
              key.publicKey.isValidSignature(signature, for: data)
        else { fail("couldn't sign \(path)") }
        print("\(signature.base64EncodedString())  \(URL(fileURLWithPath: path).lastPathComponent)")
    }

default:
    fail("usage: generate-key <file> | sign <public key> <files...>")
}
