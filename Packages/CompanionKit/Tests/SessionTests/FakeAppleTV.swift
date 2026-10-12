import CryptoKit
import Foundation
import Network
import OPACK
import TLV8
import TestSupport

/// A pretend Apple TV on 127.0.0.1 that plays the TV's side of pair-setup, so the whole
/// exchange can run without real hardware.
final class FakeAppleTV: @unchecked Sendable {
    let pin: String
    let identifier = Data("FA:KE:TV:00:00:01".utf8)
    let signingKey = Curve25519.Signing.PrivateKey()
    /// The controller name the client sent in M5, once it has.
    private(set) var pairedName: String?

    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeAppleTV")
    private var connections: [NWConnection] = []
    private var buffer = Data()
    private var srp: FakeSRPServer?
    private var sessionKey = Data()
    private var startContinuation: CheckedContinuation<Void, Error>?

    init(pin: String) throws {
        self.pin = pin
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var endpoint: NWEndpoint { .hostPort(host: "127.0.0.1", port: listener.port!) }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state { self.startContinuation?.resume(); self.startContinuation = nil }
                if case .failed(let error) = state { self.startContinuation?.resume(throwing: error); self.startContinuation = nil }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.connections.append(connection)
                self.buffer = Data()
                connection.start(queue: self.queue)
                self.receive(on: connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            connections.forEach { $0.cancel() }
            listener.cancel()
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { return }
            if let data { self.buffer.append(data) }
            while self.buffer.count >= 4 {
                let length = Int(self.buffer[self.buffer.startIndex + 1]) << 16 | Int(self.buffer[self.buffer.startIndex + 2]) << 8 | Int(self.buffer[self.buffer.startIndex + 3])
                guard self.buffer.count >= 4 + length else { break }
                let type = self.buffer[self.buffer.startIndex]
                let payload = Data(self.buffer.dropFirst(4).prefix(length))
                self.buffer = Data(self.buffer.dropFirst(4 + length))
                if let reply = self.handle(type: type, payload: payload) {
                    connection.send(content: reply, completion: .idempotent)
                }
            }
            if !isComplete { self.receive(on: connection) }
        }
    }

    /// Returns the reply frame, if any.
    private func handle(type: UInt8, payload: Data) -> Data? {
        guard let message = try? OPACK.decode(payload), let pd = message["_pd"]?.dataValue,
              let tlv = try? TLV8(decoding: pd) else { return nil }

        switch tlv[.seqNo]?.first {
        case 1 where type == 3:
            let srp = FakeSRPServer(pin: pin, salt: Data((0..<16).map { _ in UInt8.random(in: 1...255) }),
                                    privateKey: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
            self.srp = srp
            return reply([.init(.seqNo, Data([2])), .init(.salt, srp.salt), .init(.publicKey, srp.publicKey)])

        case 3:
            guard let srp, let A = tlv[.publicKey], let proof = tlv[.proof] else { return nil }
            let session = srp.session(clientPublicKey: A)
            guard proof == session.clientProof else {
                return reply([.init(.seqNo, Data([4])), .init(.error, Data([2]))])
            }
            sessionKey = session.sessionKey
            return reply([.init(.seqNo, Data([4])), .init(.proof, session.serverProof)])

        case 5:
            guard let encrypted = tlv[.encryptedData] else { return nil }
            let key = hkdf("Pair-Setup-Encrypt-Salt", "Pair-Setup-Encrypt-Info")
            guard let box = try? ChaChaPoly.SealedBox(nonce: nonce("PS-Msg05"), ciphertext: encrypted.dropLast(16), tag: encrypted.suffix(16)),
                  let inner = try? TLV8(decoding: ChaChaPoly.open(box, using: key)) else { return nil }
            pairedName = inner[.name].flatMap { try? OPACK.decode($0) }?["name"]?.stringValue

            let accessoryX = hkdf("Pair-Setup-Accessory-Sign-Salt", "Pair-Setup-Accessory-Sign-Info").withUnsafeBytes { Data($0) }
            let publicKey = signingKey.publicKey.rawRepresentation
            let signature = try! signingKey.signature(for: accessoryX + identifier + publicKey)
            let sub = TLV8([.init(.identifier, identifier), .init(.publicKey, publicKey), .init(.signature, signature)])
            let sealed = try! ChaChaPoly.seal(sub.encoded(), using: key, nonce: nonce("PS-Msg06"))
            return reply([.init(.seqNo, Data([6])), .init(.encryptedData, sealed.ciphertext + sealed.tag)])

        default:
            return nil
        }
    }

    /// Auth replies are PS_Next frames (type 4).
    private func reply(_ items: [TLV8.Item]) -> Data {
        let payload = OPACK.encode(["_pd": .data(TLV8(items).encoded())])
        return Data([4, UInt8(payload.count >> 16), UInt8((payload.count >> 8) & 0xFF), UInt8(payload.count & 0xFF)]) + payload
    }

    private func hkdf(_ salt: String, _ info: String) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: sessionKey), salt: Data(salt.utf8), info: Data(info.utf8), outputByteCount: 32)
    }

    private func nonce(_ label: String) -> ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: Data(count: 4) + Data(label.utf8))
    }
}
