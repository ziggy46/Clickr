import CryptoKit
import Foundation
import MRP
import Network
import Pairing
import Plist
import TLV8
@testable import AirPlay

/// A pretend Apple TV AirPlay receiver on 127.0.0.1, for the remote-control tunnel only.
final class FakeAirPlayServer: @unchecked Sendable {
    let tvKey = Curve25519.Signing.PrivateKey()
    let tvID = Data("FA:KE:TV:00:00:02".utf8)
    let clientCredentials: PairingCredentials

    /// What the TV saw, for the tests to check.
    struct Record {
        var setupIdentity: [String: PlistValue] = [:]
        var methods: [String] = []
        var eventReplies: [HTTPMessage] = []
        var feedbackCount = 0
        var mrpTypes: [Int] = []
        var dataSeqnos: [UInt64] = []
        var replies = 0
    }

    private(set) var record = Record()
    private let queue = DispatchQueue(label: "FakeAirPlayServer")
    private let control: NWListener
    private var listeners: [NWListener] = []
    private var links: [Link] = []
    private var shared = Data()
    private var seed: Int64 = 0

    init() throws {
        // A pairing the "TV" already knows about.
        let ourKey = Curve25519.Signing.PrivateKey()
        clientCredentials = PairingCredentials(
            deviceID: Data(UUID().uuidString.utf8),
            ourLTSK: ourKey.rawRepresentation,
            ourLTPK: ourKey.publicKey.rawRepresentation,
            theirLTPK: tvKey.publicKey.rawRepresentation,
            theirID: tvID
        )
        control = try Self.listener()
    }

    var endpoint: NWEndpoint { .hostPort(host: "127.0.0.1", port: control.port!) }

    func snapshot() -> Record { queue.sync { record } }

    func start() async throws {
        try await listen(control) { [weak self] link in self?.controlLink(link) }
    }

    func stop() {
        queue.sync {
            links.forEach { $0.connection.cancel() }
            ([control] + listeners).forEach { $0.cancel() }
        }
    }

    // MARK: - Control connection

    private func controlLink(_ link: Link) {
        var ephemeral: Curve25519.KeyAgreement.PrivateKey?
        var clientEphemeral = Data()
        link.onData = { [unowned self, unowned link] data in
            link.buffer += data
            while let request = HTTPMessage.next(from: &link.buffer) {
                let method = request.startLine.first ?? ""
                self.record.methods.append(method)
                switch (method, request.startLine.dropFirst().first) {
                case ("POST", "/pair-verify"):
                    let tlv = try! TLV8(decoding: request.body)
                    if tlv[.seqNo] == Data([1]) {
                        let key = Curve25519.KeyAgreement.PrivateKey()
                        ephemeral = key
                        clientEphemeral = tlv[.publicKey]!
                        self.shared = try! key.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: clientEphemeral)).withUnsafeBytes { Data($0) }
                        let ours = key.publicKey.rawRepresentation
                        let signature = try! self.tvKey.signature(for: ours + self.tvID + clientEphemeral)
                        let sealed = Self.seal(TLV8([.init(.identifier, self.tvID), .init(.signature, signature)]).encoded(),
                                               key: self.hkdf("Pair-Verify-Encrypt-Salt", "Pair-Verify-Encrypt-Info"), nonce: "PV-Msg02")
                        link.reply(200, body: TLV8([.init(.seqNo, Data([2])), .init(.publicKey, ours), .init(.encryptedData, sealed)]).encoded())
                    } else {
                        // Check the client's M3 signature before agreeing.
                        let inner = try! TLV8(decoding: Self.open(tlv[.encryptedData]!, key: self.hkdf("Pair-Verify-Encrypt-Salt", "Pair-Verify-Encrypt-Info"), nonce: "PV-Msg03"))
                        let signed = clientEphemeral + inner[.identifier]! + ephemeral!.publicKey.rawRepresentation
                        let valid = try! Curve25519.Signing.PublicKey(rawRepresentation: self.clientCredentials.ourLTPK).isValidSignature(inner[.signature]!, for: signed)
                        link.reply(valid ? 200 : 470, body: TLV8([.init(.seqNo, Data([4]))]).encoded())
                        link.framing = HAPFraming(outputKey: self.key("Control-Salt", "Control-Read-Encryption-Key"),
                                                  inputKey: self.key("Control-Salt", "Control-Write-Encryption-Key"))
                    }
                case ("SETUP", _):
                    let body = (try? BinaryPlist.decode(request.body)) ?? .dict([:])
                    if case .array(let streams)? = body["streams"] {
                        if case .int(let seed)? = streams.first?["seed"] { self.seed = seed }
                        let port = self.openData()
                        link.reply(200, cseq: request.headers["cseq"], plist: .dict(["streams": .array([.dict(["dataPort": .int(Int64(port))])])]))
                    } else {
                        if case .dict(let identity) = body { self.record.setupIdentity = identity }
                        let port = self.openEvent()
                        link.reply(200, cseq: request.headers["cseq"], plist: .dict(["eventPort": .int(Int64(port))]))
                    }
                case ("RECORD", _):
                    link.reply(200, cseq: request.headers["cseq"])
                case ("POST", "/feedback"):
                    self.record.feedbackCount += 1
                    link.reply(200, cseq: request.headers["cseq"])
                default:
                    link.reply(404, cseq: request.headers["cseq"])
                }
            }
        }
    }

    // MARK: - Event connection: send one request, collect the client's reply

    private func openEvent() -> UInt16 {
        openListener { [unowned self] link in
            link.framing = HAPFraming(outputKey: self.key("Events-Salt", "Events-Write-Encryption-Key"),
                                      inputKey: self.key("Events-Salt", "Events-Read-Encryption-Key"))
            link.onData = { [unowned self, unowned link] data in
                link.buffer += data
                while let reply = HTTPMessage.next(from: &link.buffer) {
                    self.record.eventReplies.append(reply)
                }
            }
            link.send(Data("POST /command RTSP/1.0\r\nCSeq: 7\r\nContent-Length: 0\r\n\r\n".utf8))
        }
    }

    // MARK: - Data connection: MRP

    private func openData() -> UInt16 {
        openListener { [unowned self] link in
            link.framing = HAPFraming(outputKey: self.key("DataStream-Salt\(self.seed)", "DataStream-Input-Encryption-Key"),
                                      inputKey: self.key("DataStream-Salt\(self.seed)", "DataStream-Output-Encryption-Key"))
            link.onData = { [unowned self, unowned link] data in
                link.buffer += data
                while let frame = DataStreamFrame.next(from: &link.buffer) {
                    guard frame.isSync else { self.record.replies += 1; continue }
                    self.record.dataSeqnos.append(frame.seqno)
                    link.send(DataStreamFrame.reply(to: frame).encoded())
                    for raw in frame.mrpMessages() {
                        guard let message = try? MRPMessage(decoding: raw) else { continue }
                        self.record.mrpTypes.append(message.type)
                        self.answer(message, on: link)
                    }
                }
            }
        }
    }

    private var tvSeqno: UInt64 = 500

    private func push(_ messages: [Data], on link: Link) {
        tvSeqno += 1
        link.send(DataStreamFrame.sync(messages, seqno: tvSeqno).encoded())
    }

    private func answer(_ message: MRPMessage, on link: Link) {
        switch message.kind {
        case .deviceInfo:
            var info = ProtoWriter()
            info.string(2, "Fake TV")
            info.varint(22, 1)
            push([MRPMessage.encode(.deviceInfo, identifier: message.identifier, inner: info)], on: link)
        case .clientUpdatesConfig, .getKeyboardSession:
            push([MRPMessage.encode(message.kind!, identifier: message.identifier)], on: link)
        case .setConnectionState:
            // Connected: push what's playing, two messages in one frame.
            var client = ProtoWriter()
            client.string(2, "com.example.video")
            client.string(7, "Video")
            var setClient = ProtoWriter()
            setClient.message(1, client)
            push([MRPMessage.encode(.setNowPlayingClient, inner: setClient), Self.playingState()], on: link)
        case .playbackQueueRequest:
            var item = ProtoWriter()
            item.string(1, "ITEM-1")
            item.bytes(3, Data(repeating: 0xAB, count: 1000))
            item.int(13, 200)
            item.int(14, 200)
            var queue = ProtoWriter()
            queue.message(2, item)
            var state = ProtoWriter()
            state.message(3, queue)
            push([MRPMessage.encode(.setState, identifier: message.identifier, inner: state)], on: link)
        default:
            break
        }
    }

    static func playingState() -> Data {
        var metadata = ProtoWriter()
        metadata.string(1, "Episode 3")
        metadata.string(7, "Some Show")
        metadata.double(14, 1800)
        metadata.bool(19, true)
        metadata.double(35, 30)
        metadata.float(39, 1)
        metadata.double(74, Date().timeIntervalSinceReferenceDate)
        var item = ProtoWriter()
        item.string(1, "ITEM-1")
        item.message(2, metadata)
        var queue = ProtoWriter()
        queue.int(1, 0)
        queue.message(2, item)
        var client = ProtoWriter()
        client.string(2, "com.example.video")
        var player = ProtoWriter()
        player.string(1, "MediaRemote-DefaultPlayer")
        var path = ProtoWriter()
        path.message(2, client)
        path.message(3, player)
        var state = ProtoWriter()
        state.message(3, queue)
        state.varint(6, 1)
        state.message(9, path)
        return MRPMessage.encode(.setState, inner: state)
    }

    // MARK: - Plumbing

    final class Link: @unchecked Sendable {
        let connection: NWConnection
        var buffer = Data()
        var framing: HAPFraming?
        var onData: ((Data) -> Void)?

        init(_ connection: NWConnection) {
            self.connection = connection
        }

        func send(_ data: Data) {
            let wire = framing != nil ? try! framing!.seal(data) : data
            connection.send(content: wire, completion: .idempotent)
        }

        func reply(_ status: Int, cseq: String? = nil, body: Data = Data(), plist: PlistValue? = nil) {
            let payload = plist.map(BinaryPlist.encode) ?? body
            var head = "\(cseq == nil ? "HTTP/1.1" : "RTSP/1.0") \(status) OK\r\nContent-Length: \(payload.count)\r\n"
            if let cseq { head += "CSeq: \(cseq)\r\n" }
            if plist != nil { head += "Content-Type: application/x-apple-binary-plist\r\n" }
            send(Data((head + "\r\n").utf8) + payload)
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
                guard let self, error == nil else { return }
                if let data, !data.isEmpty {
                    let plain = self.framing != nil ? (try? self.framing!.open(data)) ?? Data() : data
                    if !plain.isEmpty { self.onData?(plain) }
                }
                if !isComplete { self.receive() }
            }
        }
    }

    private static func listener() throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        return try NWListener(using: parameters)
    }

    private var startContinuation: CheckedContinuation<Void, Error>?

    private func listen(_ listener: NWListener, onConnection: @escaping @Sendable (Link) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startContinuation = continuation
            listener.stateUpdateHandler = { [unowned self] state in
                if case .ready = state { self.startContinuation?.resume(); self.startContinuation = nil }
                if case .failed(let error) = state { self.startContinuation?.resume(throwing: error); self.startContinuation = nil }
            }
            listener.newConnectionHandler = { [unowned self] connection in
                let link = Link(connection)
                self.links.append(link)
                connection.start(queue: self.queue)
                onConnection(link)
                link.receive()
            }
            listener.start(queue: queue)
        }
    }

    /// Opens another listener on the server queue and returns its port right away.
    private func openListener(_ onConnection: @escaping @Sendable (Link) -> Void) -> UInt16 {
        let listener = try! Self.listener()
        listeners.append(listener)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [unowned self] connection in
            let link = Link(connection)
            self.links.append(link)
            connection.start(queue: self.queue)
            onConnection(link)
            link.receive()
        }
        listener.start(queue: DispatchQueue(label: "FakeAirPlayServer.listener"))
        ready.wait()
        return listener.port!.rawValue
    }

    private func hkdf(_ salt: String, _ info: String) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared), salt: Data(salt.utf8), info: Data(info.utf8), outputByteCount: 32)
    }

    private func key(_ salt: String, _ info: String) -> Data {
        hkdf(salt, info).withUnsafeBytes { Data($0) }
    }

    private static func nonce(_ label: String) -> ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: Data(count: 4) + Data(label.utf8))
    }

    private static func seal(_ data: Data, key: SymmetricKey, nonce label: String) -> Data {
        let box = try! ChaChaPoly.seal(data, using: key, nonce: nonce(label))
        return box.ciphertext + box.tag
    }

    private static func open(_ data: Data, key: SymmetricKey, nonce label: String) throws -> Data {
        try ChaChaPoly.open(ChaChaPoly.SealedBox(nonce: nonce(label), ciphertext: data.dropLast(16), tag: data.suffix(16)), using: key)
    }
}
