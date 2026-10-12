import CryptoKit
import Foundation
import Network
import OPACK
import TLV8
import TestSupport
import Transport
@testable import Session

/// A pretend Apple TV on 127.0.0.1. It plays the TV's side of pair-setup and pair-verify,
/// then answers encrypted Companion requests, so the whole session can be tested without
/// real hardware.
final class FakeAppleTV: @unchecked Sendable {
    let pin: String
    let identifier = Data("FA:KE:TV:00:00:01".utf8)
    let signingKey = Curve25519.Signing.PrivateKey()

    /// Set to make pair-verify fail the way a TV that forgot us does (error in M4).
    var rejectsVerify = false
    /// Whether a text field has focus (a search screen is open).
    var hasTextField = true
    /// What FetchAttentionState reports.
    var isAsleep = false
    /// Events the client registered for with `_interest`.
    private(set) var registeredEvents: [String] = []
    /// What's in the TV's focused text field.
    private(set) var fieldText = ""
    /// `_tiC` operations received, as "insert:<text>" or "clear".
    private(set) var textOperations: [String] = []
    let textSessionID = Data((0..<16).map { UInt8($0) })
    /// The controller name the client sent in M5, once it has.
    private(set) var pairedName: String?
    /// Every E_OPACK request identifier, in order.
    private(set) var requests: [String] = []
    /// `_hidC` commands as (state, code): 1 = down, 2 = up.
    private(set) var hidCommands: [(state: UInt64, code: UInt64)] = []

    private var clientLTPK: Data?
    private var clientID: Data?

    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeAppleTV")
    private var connections: [Link] = []
    private var startContinuation: CheckedContinuation<Void, Error>?

    init(pin: String) throws {
        self.pin = pin
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var endpoint: NWEndpoint { .hostPort(host: "127.0.0.1", port: listener.port!) }

    struct Snapshot {
        let requests: [String]
        let hid: [(state: UInt64, code: UInt64)]
        let name: String?
        let fieldText: String
        let textOperations: [String]
    }

    /// What the TV has recorded so far, read on its queue.
    func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(requests: requests, hid: hidCommands, name: pairedName, fieldText: fieldText, textOperations: textOperations)
        }
    }

    /// A text field gains focus with `text` in it; pushes `_tiStarted`.
    func showKeyboard(text: String) {
        queue.sync {
            hasTextField = true
            fieldText = text
            connections.last?.sendEvent("_tiStarted", ["_tiD": .data(textSessionArchive())])
        }
    }

    /// The text field loses focus; pushes `_tiStopped`.
    func hideKeyboard() {
        queue.sync {
            hasTextField = false
            connections.last?.sendEvent("_tiStopped", [:])
        }
    }

    /// Pushes a TVSystemStatus event (1 asleep, 3 awake).
    func setAsleep(_ asleep: Bool) {
        queue.sync {
            isAsleep = asleep
            connections.last?.sendEvent("TVSystemStatus", ["state": .int(asleep ? 1 : 3)])
        }
    }

    var events: [String] {
        queue.sync { registeredEvents }
    }

    /// A `_tiStart` reply archive, shaped like the paths pyatv reads.
    fileprivate func textSessionArchive() -> Data {
        BinaryPlist.encode(.dict([
            "$version": .int(100_000),
            "$archiver": .string("RTIKeyedArchiver"),
            "$top": .dict(["sessionUUID": .uid(1), "documentState": .uid(2)]),
            "$objects": .array([
                .string("$null"),
                .data(textSessionID),
                .dict(["docSt": .uid(3)]),
                .dict(["contextBeforeInput": .uid(4)]),
                .string(fieldText),
            ]),
        ]))
    }

    fileprivate func applyTextOperation(_ archive: Data) {
        guard let plist = try? BinaryPlist.decode(archive),
              TextInputArchive.resolve(plist, path: ["textOperations", "targetSessionUUID", "NS.uuidbytes"]) == .data(textSessionID)
        else { return }
        if case .string(let text)? = TextInputArchive.resolve(plist, path: ["textOperations", "keyboardOutput", "insertionText"]) {
            fieldText += text
            textOperations.append("insert:\(text)")
        } else if TextInputArchive.resolve(plist, path: ["textOperations", "textToAssert"]) == .string("") {
            fieldText = ""
            textOperations.append("clear")
        }
    }

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
                let link = Link(connection: connection, tv: self)
                self.connections.append(link)
                connection.start(queue: self.queue)
                link.receive()
            }
            listener.start(queue: queue)
        }
    }

    /// Hangs up every open connection, like a TV dropping off the network.
    func dropConnections() {
        queue.sync {
            connections.forEach { $0.connection.cancel() }
            connections = []
        }
    }

    func stop() {
        dropConnections()
        listener.cancel()
    }

    /// One client connection and its handshake state.
    private final class Link {
        let connection: NWConnection
        unowned let tv: FakeAppleTV
        var buffer = Data()
        var srp: FakeSRPServer?
        var setupKey = Data()
        var verifyEphemeral: Curve25519.KeyAgreement.PrivateKey?
        var clientEphemeral = Data()
        var verifyShared = Data()
        var cipher: FrameCipher?

        init(connection: NWConnection, tv: FakeAppleTV) {
            self.connection = connection
            self.tv = tv
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self, error == nil else { return }
                if let data { self.buffer.append(data) }
                while self.buffer.count >= 4 {
                    let bytes = [UInt8](self.buffer.prefix(4))
                    let length = Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
                    guard self.buffer.count >= 4 + length else { break }
                    var payload = Data(self.buffer.dropFirst(4).prefix(length))
                    self.buffer = Data(self.buffer.dropFirst(4 + length))
                    if self.cipher != nil, !payload.isEmpty {
                        guard let plain = try? self.cipher!.open(payload, type: FrameType(rawValue: bytes[0])) else {
                            self.connection.cancel()
                            return
                        }
                        payload = plain
                    }
                    self.handle(type: bytes[0], payload: payload)
                }
                if !isComplete { self.receive() }
            }
        }

        private func send(type: FrameType, _ message: OPACKValue, encrypted: Bool) {
            var payload = OPACK.encode(message)
            if encrypted, cipher != nil {
                payload = try! cipher!.seal(payload, type: type)
            }
            let header = FrameHeader(type: type, payloadLength: payload.count)
            connection.send(content: header.bytes + payload, completion: .idempotent)
        }

        fileprivate func sendEvent(_ identifier: String, _ content: OPACKValue) {
            send(type: .eOPACK, ["_i": .string(identifier), "_t": 1, "_c": content], encrypted: true)
        }

        private func reply(_ type: FrameType, _ items: [TLV8.Item]) {
            send(type: type, ["_pd": .data(TLV8(items).encoded())], encrypted: false)
        }

        private func handle(type: UInt8, payload: Data) {
            guard let message = try? OPACK.decode(payload) else { return }
            if type == FrameType.eOPACK.rawValue {
                handleRequest(message)
                return
            }
            guard let pd = message["_pd"]?.dataValue, let tlv = try? TLV8(decoding: pd) else { return }
            switch (type, tlv[.seqNo]?.first) {
            case (3, 1): pairSetupM1()
            case (4, 3): pairSetupM3(tlv)
            case (4, 5): pairSetupM5(tlv)
            case (5, 1): pairVerifyM1(tlv)
            case (6, 3): pairVerifyM3(tlv)
            default: break
            }
        }

        // MARK: Pair-setup

        private func pairSetupM1() {
            let srp = FakeSRPServer(pin: tv.pin, salt: Self.random(16), privateKey: Self.random(32))
            self.srp = srp
            reply(.psNext, [.init(.seqNo, Data([2])), .init(.salt, srp.salt), .init(.publicKey, srp.publicKey)])
        }

        private func pairSetupM3(_ tlv: TLV8) {
            guard let srp, let A = tlv[.publicKey], let proof = tlv[.proof] else { return }
            let session = srp.session(clientPublicKey: A)
            guard proof == session.clientProof else {
                reply(.psNext, [.init(.seqNo, Data([4])), .init(.error, Data([2]))])
                return
            }
            setupKey = session.sessionKey
            reply(.psNext, [.init(.seqNo, Data([4])), .init(.proof, session.serverProof)])
        }

        private func pairSetupM5(_ tlv: TLV8) {
            let key = Self.hkdf(setupKey, "Pair-Setup-Encrypt-Salt", "Pair-Setup-Encrypt-Info")
            guard let encrypted = tlv[.encryptedData],
                  let inner = try? TLV8(decoding: Self.open(encrypted, key: key, nonce: "PS-Msg05")) else { return }
            tv.pairedName = inner[.name].flatMap { try? OPACK.decode($0) }?["name"]?.stringValue
            tv.clientLTPK = inner[.publicKey]
            tv.clientID = inner[.identifier]

            let accessoryX = Self.hkdf(setupKey, "Pair-Setup-Accessory-Sign-Salt", "Pair-Setup-Accessory-Sign-Info").withUnsafeBytes { Data($0) }
            let publicKey = tv.signingKey.publicKey.rawRepresentation
            let signature = try! tv.signingKey.signature(for: accessoryX + tv.identifier + publicKey)
            let sub = TLV8([.init(.identifier, tv.identifier), .init(.publicKey, publicKey), .init(.signature, signature)])
            reply(.psNext, [.init(.seqNo, Data([6])), .init(.encryptedData, Self.seal(sub.encoded(), key: key, nonce: "PS-Msg06"))])
        }

        // MARK: Pair-verify

        private func pairVerifyM1(_ tlv: TLV8) {
            guard let clientPublic = tlv[.publicKey] else { return }
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            verifyEphemeral = ephemeral
            clientEphemeral = clientPublic
            verifyShared = try! ephemeral.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: clientPublic)).withUnsafeBytes { Data($0) }

            let ourPublic = ephemeral.publicKey.rawRepresentation
            let signature = try! tv.signingKey.signature(for: ourPublic + tv.identifier + clientPublic)
            let sub = TLV8([.init(.identifier, tv.identifier), .init(.signature, signature)])
            let key = Self.hkdf(verifyShared, "Pair-Verify-Encrypt-Salt", "Pair-Verify-Encrypt-Info")
            reply(.pvNext, [.init(.seqNo, Data([2])), .init(.publicKey, ourPublic), .init(.encryptedData, Self.seal(sub.encoded(), key: key, nonce: "PV-Msg02"))])
        }

        private func pairVerifyM3(_ tlv: TLV8) {
            let key = Self.hkdf(verifyShared, "Pair-Verify-Encrypt-Salt", "Pair-Verify-Encrypt-Info")
            guard let encrypted = tlv[.encryptedData], let ephemeral = verifyEphemeral,
                  let inner = try? TLV8(decoding: Self.open(encrypted, key: key, nonce: "PV-Msg03")),
                  let id = inner[.identifier], let signature = inner[.signature],
                  let clientLTPK = tv.clientLTPK, id == tv.clientID,
                  (try? Curve25519.Signing.PublicKey(rawRepresentation: clientLTPK))?
                    .isValidSignature(signature, for: clientEphemeral + id + ephemeral.publicKey.rawRepresentation) == true,
                  !tv.rejectsVerify
            else {
                reply(.pvNext, [.init(.seqNo, Data([4])), .init(.error, Data([2]))])
                return
            }
            reply(.pvNext, [.init(.seqNo, Data([4]))])
            // The TV encrypts with ServerEncrypt and reads with ClientEncrypt.
            cipher = FrameCipher(
                outputKey: Self.hkdf(verifyShared, "", "ServerEncrypt-main").withUnsafeBytes { Data($0) },
                inputKey: Self.hkdf(verifyShared, "", "ClientEncrypt-main").withUnsafeBytes { Data($0) }
            )
        }

        // MARK: Requests

        private func handleRequest(_ message: OPACKValue) {
            guard let identifier = message["_i"]?.stringValue, let xid = message["_x"] else { return }
            if message["_t"] == 1 {
                // Events get no reply.
                if identifier == "_tiC", let archive = message["_c"]?["_tiD"]?.dataValue {
                    tv.applyTextOperation(archive)
                }
                if identifier == "_interest", case .array(let names)? = message["_c"]?["_regEvents"] {
                    tv.registeredEvents += names.compactMap(\.stringValue)
                }
                return
            }
            tv.requests.append(identifier)
            var content: OPACKValue = [:]
            switch identifier {
            case "_sessionStart":
                content = ["_sid": 0x1234]
            case "_tiStart" where tv.hasTextField:
                content = ["_tiD": .data(tv.textSessionArchive())]
            case "FetchAttentionState":
                content = ["state": .int(tv.isAsleep ? 1 : 3)]
            case "_hidC":
                tv.hidCommands.append((message["_c"]?["_hBtS"]?.intValue ?? 0, message["_c"]?["_hidC"]?.intValue ?? 0))
            default:
                break
            }
            send(type: .eOPACK, ["_c": content, "_t": 3, "_x": xid], encrypted: true)
        }

        // MARK: Helpers

        static func random(_ count: Int) -> Data {
            Data((0..<count).map { _ in UInt8.random(in: 1...255) })
        }

        static func hkdf(_ secret: Data, _ salt: String, _ info: String) -> SymmetricKey {
            HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(salt.utf8), info: Data(info.utf8), outputByteCount: 32)
        }

        static func nonce(_ label: String) -> ChaChaPoly.Nonce {
            try! ChaChaPoly.Nonce(data: Data(count: 4) + Data(label.utf8))
        }

        static func seal(_ data: Data, key: SymmetricKey, nonce label: String) -> Data {
            let box = try! ChaChaPoly.seal(data, using: key, nonce: nonce(label))
            return box.ciphertext + box.tag
        }

        static func open(_ data: Data, key: SymmetricKey, nonce label: String) throws -> Data {
            try ChaChaPoly.open(ChaChaPoly.SealedBox(nonce: nonce(label), ciphertext: data.dropLast(16), tag: data.suffix(16)), using: key)
        }
    }
}
