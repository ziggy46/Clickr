import CryptoKit
import Foundation
import MRP
import Network
import os
import Pairing
import Plist
import TLV8

/// What Clickr tells the TV about itself when setting up the AirPlay session.
public struct AirPlayIdentity: Sendable {
    public var name: String
    public var model: String
    public var osName: String
    public var osVersion: String
    public var osBuild: String
    public var deviceID: String
    public var macAddress: String

    public init(name: String, model: String, osName: String, osVersion: String, osBuild: String, deviceID: String, macAddress: String) {
        self.name = name
        self.model = model
        self.osName = osName
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.deviceID = deviceID
        self.macAddress = macAddress
    }
}

/// An AirPlay 2 "remote control only" session that tunnels MRP (MediaRemote) messages,
/// which is how the TV shares now-playing info. Follows pyatv:
///
///   control TCP: POST /pair-verify ×2 (plain), then HAP framing; SETUP → event port;
///   event TCP (answer every request with 200); RECORD; SETUP with a seed → data port;
///   data TCP: MRP in data-stream frames; POST /feedback every 2 s on control.
public actor AirPlayRemoteControl {
    public enum AirPlayError: Error, Equatable {
        case status(Int, String)
        case badResponse(String)
        case noAddress
        case timeout(String)
        case closed
        /// The TV refused a playback command (MRP SendError).
        case commandFailed(Int, sendError: Int)
    }

    /// MRP messages the TV pushes (anything that isn't a reply to our requests). Finishes
    /// when the session ends.
    public nonisolated let messages: AsyncStream<MRPMessage>
    private let messagesContinuation: AsyncStream<MRPMessage>.Continuation

    private let controlEndpoint: NWEndpoint
    private let credentials: PairingCredentials
    private let identity: AirPlayIdentity
    private let log = Logger(subsystem: "com.ziggy46.clickr", category: "AirPlay")

    private var control: HAPChannel?
    private var event: HAPChannel?
    private var data: HAPChannel?
    private var tasks: [Task<Void, Never>] = []
    private var isClosed = false

    // Control connection: replies come back in request order.
    private var controlBuffer = Data()
    private var responseWaiters: [(id: UUID, continuation: CheckedContinuation<HTTPMessage, Error>)] = []

    // RTSP session values, random per session as in pyatv.
    private var cseq = 0
    private let sessionID = UInt32.random(in: .min ... .max)
    private let dacpID = String(UInt64.random(in: .min ... .max), radix: 16, uppercase: true)
    private let activeRemote = UInt32.random(in: .min ... .max)
    private var rtspURI = ""

    private var eventBuffer = Data()

    // Data channel.
    private var dataBuffer = Data()
    private var dataSeqno = UInt64.random(in: 0x1_0000_0000 ..< 0x2_0000_0000)
    private var pendingRequests: [String: CheckedContinuation<MRPMessage, Error>] = [:]

    public init(endpoint: NWEndpoint, credentials: PairingCredentials, identity: AirPlayIdentity) {
        controlEndpoint = endpoint
        self.credentials = credentials
        self.identity = identity
        (messages, messagesContinuation) = AsyncStream.makeStream(of: MRPMessage.self)
    }

    // MARK: - Setup

    public func start() async throws {
        do {
            try await setUp()
        } catch {
            close()
            throw error
        }
    }

    private func setUp() async throws {
        let control = HAPChannel(endpoint: controlEndpoint)
        self.control = control
        try await control.connect()
        startReading(control) { me, chunk in me.controlReceived(chunk) }

        guard let remote = await control.remoteHost, let local = await control.localHost else {
            throw AirPlayError.noAddress
        }
        rtspURI = "rtsp://\(Self.uriHost(local))/\(sessionID)"
        log.info("AirPlay control connected to \(Self.address(remote), privacy: .public)")

        // Pair-verify with the pairing from Companion, as raw TLV8 over HTTP.
        var verify = PairVerify(credentials: credentials)
        let m2 = try await verifyStep(verify.startTLV())
        let m3 = try verify.respond(toTLV: try TLV8(decoding: m2.body))
        _ = try await verifyStep(m3)
        let controlKeys = try verify.keys(salt: "Control-Salt", outputInfo: "Control-Write-Encryption-Key", inputInfo: "Control-Read-Encryption-Key")
        await control.enableEncryption(outputKey: controlKeys.output, inputKey: controlKeys.input)

        // Event channel: required, though nothing on it is used.
        let session = try await rtsp("SETUP", body: .dict([
            "isRemoteControlOnly": .bool(true),
            "osName": .string(identity.osName),
            "sourceVersion": .string("550.10"),
            "timingProtocol": .string("None"),
            "model": .string(identity.model),
            "deviceID": .string(identity.deviceID),
            "osVersion": .string(identity.osVersion),
            "osBuildVersion": .string(identity.osBuild),
            "macAddress": .string(identity.macAddress),
            "sessionUUID": .string(UUID().uuidString),
            "name": .string(identity.name),
        ]))
        guard case .int(let eventPort)? = try Self.plist(session)["eventPort"] else { throw AirPlayError.badResponse("no eventPort") }
        let eventKeys = try verify.keys(salt: "Events-Salt", outputInfo: "Events-Read-Encryption-Key", inputInfo: "Events-Write-Encryption-Key")
        let event = try await openChannel(remote, port: eventPort, keys: eventKeys)
        self.event = event
        startReading(event) { me, chunk in me.eventReceived(chunk) }

        _ = try await rtsp("RECORD")

        // Data channel, keyed with a seed we choose (below 2^63 so it fits a plist int).
        let seed = Int64.random(in: 0 ... .max)
        let stream = try await rtsp("SETUP", body: .dict(["streams": .array([.dict([
            "controlType": .int(2),
            "channelID": .string(UUID().uuidString),
            "seed": .int(seed),
            "clientUUID": .string(UUID().uuidString),
            "type": .int(130),
            "wantsDedicatedSocket": .bool(true),
            "clientTypeUUID": .string("1910A70F-DBC0-4242-AF95-115DB30604E1"),
        ])])]))
        guard case .array(let streams)? = try Self.plist(stream)["streams"],
              case .int(let dataPort)? = streams.first?["dataPort"] else { throw AirPlayError.badResponse("no dataPort") }
        let dataKeys = try verify.keys(salt: "DataStream-Salt\(seed)", outputInfo: "DataStream-Output-Encryption-Key", inputInfo: "DataStream-Input-Encryption-Key")
        let data = try await openChannel(remote, port: dataPort, keys: dataKeys)
        self.data = data
        startReading(data) { me, chunk in me.dataReceived(chunk) }

        startKeepAlive()
        try await mrpHandshake()
        log.info("AirPlay remote control session ready")
    }

    private func mrpHandshake() async throws {
        _ = try await request(.deviceInfo, MRPRequests.deviceInfo(
            name: identity.name, uniqueIdentifier: UUID().uuidString.lowercased(), systemBuildVersion: identity.osBuild
        ))
        try await send(.setConnectionState, MRPRequests.setConnectionState())
        _ = try await request(.clientUpdatesConfig, MRPRequests.clientUpdatesConfig())
        _ = try await request(.getKeyboardSession, nil)
    }

    private func openChannel(_ host: NWEndpoint.Host, port: Int64, keys: (output: Data, input: Data)) async throws -> HAPChannel {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw AirPlayError.badResponse("bad port") }
        let channel = HAPChannel(endpoint: .hostPort(host: host, port: port))
        try await channel.connect()
        await channel.enableEncryption(outputKey: keys.output, inputKey: keys.input)
        return channel
    }

    // MARK: - MRP

    /// Sends a message and waits for the reply carrying the same identifier.
    public func request(_ kind: MRPMessage.Kind, _ inner: ProtoWriter?, timeout: Duration = .seconds(5)) async throws -> MRPMessage {
        let identifier = UUID().uuidString
        let message = MRPMessage.encode(kind, identifier: identifier, inner: inner)
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[identifier] = continuation
            Task {
                do {
                    try await self.sendFrame([message])
                } catch {
                    self.failRequest(identifier, error)
                }
                try? await Task.sleep(for: timeout)
                self.failRequest(identifier, AirPlayError.timeout(String(describing: kind)))
            }
        }
    }

    /// Sends a playback command and waits for the TV's result, like pyatv's
    /// send_and_receive. A nonzero sendError (no such command, app not responding...)
    /// throws.
    public func sendCommand(_ command: PlaybackCommand, skipInterval: Float? = nil, playbackPosition: Double? = nil) async throws {
        let reply = try await request(.sendCommand, MRPRequests.sendCommand(command, skipInterval: skipInterval, playbackPosition: playbackPosition))
        if let error = reply.inner?.uint(1), error != 0 {
            throw AirPlayError.commandFailed(command.rawValue, sendError: Int(error))
        }
    }

    public func send(_ kind: MRPMessage.Kind, _ inner: ProtoWriter?) async throws {
        try await sendFrame([MRPMessage.encode(kind, inner: inner)])
    }

    private func sendFrame(_ messages: [Data]) async throws {
        guard let data else { throw AirPlayError.closed }
        let frame = DataStreamFrame.sync(messages, seqno: dataSeqno)
        dataSeqno += 1
        try await data.send(frame.encoded())
    }

    private func failRequest(_ identifier: String, _ error: Error) {
        pendingRequests.removeValue(forKey: identifier)?.resume(throwing: error)
    }

    private func dataReceived(_ chunk: Data) {
        dataBuffer += chunk
        while let frame = DataStreamFrame.next(from: &dataBuffer) {
            if frame.isSync, let data {
                let reply = DataStreamFrame.reply(to: frame).encoded()
                Task { try? await data.send(reply) }
            }
            for raw in frame.mrpMessages() {
                guard let message = try? MRPMessage(decoding: raw) else { continue }
                if let identifier = message.identifier, let waiter = pendingRequests.removeValue(forKey: identifier) {
                    waiter.resume(returning: message)
                } else {
                    messagesContinuation.yield(message)
                }
            }
        }
    }

    // MARK: - HTTP and RTSP on the control connection

    private func verifyStep(_ tlv: TLV8) async throws -> HTTPMessage {
        let body = tlv.encoded()
        return try await exchange(HTTPRequest(method: "POST", uri: "/pair-verify", version: "HTTP/1.1", headers: [
            ("Content-Length", "\(body.count)"),
            ("User-Agent", "AirPlay/320.20"),
            ("Connection", "keep-alive"),
            ("X-Apple-HKP", "3"),
            ("Content-Type", "application/octet-stream"),
        ], body: body))
    }

    private func rtsp(_ method: String, uri: String? = nil, body: PlistValue? = nil) async throws -> HTTPMessage {
        let payload = body.map(BinaryPlist.encode) ?? Data()
        var headers: [(String, String)] = [("User-Agent", "AirPlay/550.10")]
        if !payload.isEmpty { headers.append(("Content-Length", "\(payload.count)")) }
        headers += [("CSeq", "\(cseq)"), ("DACP-ID", dacpID), ("Active-Remote", "\(activeRemote)"), ("Client-Instance", dacpID)]
        if !payload.isEmpty { headers.append(("Content-Type", "application/x-apple-binary-plist")) }
        cseq += 1
        let response = try await exchange(HTTPRequest(method: method, uri: uri ?? rtspURI, version: "RTSP/1.0", headers: headers, body: payload))
        if uri != "/feedback" {
            log.info("\(method, privacy: .public) -> \(response.statusCode ?? 0)")
        }
        return response
    }

    /// Sends a request on the control connection and waits for its response.
    private func exchange(_ request: HTTPRequest, timeout: Duration = .seconds(10)) async throws -> HTTPMessage {
        guard let control else { throw AirPlayError.closed }
        let id = UUID()
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPMessage, Error>) in
            responseWaiters.append((id, continuation))
            Task {
                do {
                    try await control.send(request.encoded())
                } catch {
                    self.failResponse(id, error)
                }
                try? await Task.sleep(for: timeout)
                self.failResponse(id, AirPlayError.timeout("\(request.method) \(request.uri)"))
            }
        }
        guard let status = response.statusCode, (200..<300).contains(status) else {
            throw AirPlayError.status(response.statusCode ?? 0, "\(request.method) \(request.uri)")
        }
        return response
    }

    private func failResponse(_ id: UUID, _ error: Error) {
        guard let index = responseWaiters.firstIndex(where: { $0.id == id }) else { return }
        responseWaiters.remove(at: index).continuation.resume(throwing: error)
    }

    private func controlReceived(_ chunk: Data) {
        controlBuffer += chunk
        while let response = HTTPMessage.next(from: &controlBuffer) {
            guard !responseWaiters.isEmpty else { continue }
            responseWaiters.removeFirst().continuation.resume(returning: response)
        }
    }

    private func eventReceived(_ chunk: Data) {
        eventBuffer += chunk
        while let request = HTTPMessage.next(from: &eventBuffer) {
            answerEvent(request)
        }
    }

    /// The TV sends requests on the event channel; pyatv answers each with 200.
    private func answerEvent(_ request: HTTPMessage) {
        guard let event else { return }
        var reply = "\(request.startLine.last ?? "RTSP/1.0") 200 OK\r\n"
        if request.headers["server"] == nil { reply += "Server: Clickr\r\n" }
        reply += "Content-Length: 0\r\nAudio-Latency: 0\r\n"
        if let server = request.headers["server"] { reply += "Server: \(server)\r\n" }
        if let cseq = request.headers["cseq"] { reply += "CSeq: \(cseq)\r\n" }
        reply += "\r\n"
        let data = Data(reply.utf8)
        Task { try? await event.send(data) }
    }

    /// `POST /feedback` every 2 s. Two failures in a row end the session.
    private func startKeepAlive() {
        tasks.append(Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                if failures == 0 { try? await Task.sleep(for: .seconds(2)) }
                guard !Task.isCancelled, let self else { return }
                do {
                    _ = try await self.rtsp("POST", uri: "/feedback")
                    failures = 0
                } catch {
                    failures += 1
                    if failures >= 2 {
                        await self.close()
                        return
                    }
                }
            }
        })
    }

    // MARK: - Lifecycle

    private func startReading(_ channel: HAPChannel, _ handle: @escaping @Sendable (isolated AirPlayRemoteControl, Data) -> Void) {
        tasks.append(Task { [weak self] in
            do {
                for try await chunk in channel.received {
                    guard let self else { return }
                    await self.deliver(chunk, to: handle)
                }
            } catch {
                await self?.logEnd(error)
            }
            await self?.close()
        })
    }

    private func deliver(_ chunk: Data, to handle: @Sendable (isolated AirPlayRemoteControl, Data) -> Void) {
        handle(self, chunk)
    }

    private func logEnd(_ error: Error) {
        log.info("AirPlay connection ended: \(String(describing: error), privacy: .public)")
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        tasks.forEach { $0.cancel() }
        for channel in [control, event, data].compactMap({ $0 }) {
            Task { await channel.close() }
        }
        control = nil
        event = nil
        data = nil
        responseWaiters.forEach { $0.continuation.resume(throwing: AirPlayError.closed) }
        responseWaiters = []
        pendingRequests.values.forEach { $0.resume(throwing: AirPlayError.closed) }
        pendingRequests = [:]
        messagesContinuation.finish()
    }

    // MARK: - Helpers

    private static func plist(_ response: HTTPMessage) throws -> PlistValue {
        try BinaryPlist.decode(response.body)
    }

    /// IPv6 goes in brackets, without the interface suffix.
    private static func uriHost(_ host: NWEndpoint.Host) -> String {
        guard case .ipv6 = host else { return address(host) }
        return "[\(address(host).split(separator: "%").first ?? "")]"
    }

    private static func address(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address): "\(address)"
        case .ipv6(let address): "\(address)"
        case .name(let name, _): name
        @unknown default: "\(host)"
        }
    }
}
