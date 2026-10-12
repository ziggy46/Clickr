import CryptoKit
import Discovery
import Foundation
import OPACK
import os
import Pairing
import Store
import Transport

/// Things the TV tells us while connected.
public enum TVUpdate: Sendable, Equatable {
    /// The TV went to sleep (true) or woke up (false).
    case asleep(Bool)
    /// A text field on the TV gained focus; `text` is what's already in it.
    case keyboardShown(text: String)
    /// The TV's text field lost focus.
    case keyboardHidden
}

/// One Apple TV: pairing, the encrypted connection, and remote commands.
public actor AppleTVSession {
    public enum SessionError: Error, Equatable {
        /// finishPairing was called without a pairing in progress.
        case notPairing
        /// A command was sent while not connected.
        case notConnected
        /// The TV didn't answer in time.
        case timeout
        /// The TV answered with a frame we didn't expect.
        case unexpectedFrame(UInt8)
        /// The connection closed before the TV answered.
        case connectionClosed
        /// The TV answered a request with an error (`_em`).
        case commandFailed(String)
        /// No text field has focus on the TV.
        case noTextField
    }

    public nonisolated let device: DiscoveredDevice
    private let store: CredentialStore
    private let log = Logger(subsystem: "com.ziggy46.clickr", category: "Session")

    private var currentState: ConnectionState
    private var stateContinuations: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

    private var connection: CompanionConnection?
    private var pairSetup: PairSetup?
    private var transactionID = UInt64.random(in: 0...0xFFFF)

    // Before encryption, auth replies wait here for nextFrame().
    private var bufferedFrames: [Frame] = []
    private var frameWaiter: (id: UUID, continuation: CheckedContinuation<Frame, Error>)?

    // After encryption, OPACK replies are matched to requests by `_x`.
    private var isMessaging = false
    private var pendingRequests: [UInt64: CheckedContinuation<OPACKValue, Error>] = [:]

    // Staying connected.
    private var wantsConnection = false
    private var connectLoop: Task<Void, Never>?
    private var lastPress: Task<Void, Error>?
    private var desiredText: String?
    private var textUpdate: Task<Void, Error>?
    /// The focused text field's session, kept current by `_tiStarted` / `_tiStopped` events.
    /// `currentText` is what we believe is in the field.
    private var textSession: TextInputArchive.Session?
    private var updateContinuations: [UUID: AsyncStream<TVUpdate>.Continuation] = [:]
    private static let backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10)]

    public init(device: DiscoveredDevice, store: CredentialStore) {
        self.device = device
        self.store = store
        let isPaired = ((try? store.credentials(for: device.id)) ?? nil) != nil
        currentState = isPaired ? .disconnected : .needsPairing
    }

    /// The current state right away, then every change.
    public var state: AsyncStream<ConnectionState> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConnectionState.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        stateContinuations[id] = continuation
        continuation.yield(currentState)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateContinuation(id) }
        }
        return stream
    }

    /// Power and keyboard changes, while connected.
    public var updates: AsyncStream<TVUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: TVUpdate.self)
        let id = UUID()
        updateContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeUpdateContinuation(id) }
        }
        return stream
    }

    private func publish(_ update: TVUpdate) {
        updateContinuations.values.forEach { $0.yield(update) }
    }

    private func removeUpdateContinuation(_ id: UUID) {
        updateContinuations[id] = nil
    }

    // MARK: - Connecting

    /// Connects (pair-verify, encryption, session start) and keeps reconnecting with backoff
    /// until `disconnect`. Calling it again retries right away.
    public func connect() {
        guard currentState != .needsPairing else { return }
        wantsConnection = true
        // Already connected, or a handshake is under way: leave it alone. Otherwise this
        // also cuts a backoff wait short.
        guard currentState != .connected, currentState != .connecting else { return }
        connectLoop?.cancel()
        connectLoop = Task { await runConnectLoop() }
    }

    public func disconnect() {
        wantsConnection = false
        connectLoop?.cancel()
        connectLoop = nil
        close()
        if currentState != .needsPairing { setState(.disconnected) }
    }

    private func runConnectLoop() async {
        var attempt = 0
        while wantsConnection, !Task.isCancelled {
            setState(.connecting)
            do {
                try await establish()
                return
            } catch let error where Self.meansNotPaired(error) {
                log.error("TV no longer accepts our pairing: \(String(describing: error), privacy: .public)")
                close()
                wantsConnection = false
                setState(.needsPairing)
                return
            } catch {
                close()
                guard !Task.isCancelled else { return }
                let delay = Self.backoff[min(attempt, Self.backoff.count - 1)]
                attempt += 1
                log.info("Connect failed (\(String(describing: error), privacy: .public)), retrying in \(String(describing: delay), privacy: .public)")
                setState(.disconnected)
                try? await Task.sleep(for: delay)
            }
        }
    }

    private func establish() async throws {
        guard let credentials = try store.credentials(for: device.id) else {
            throw PairVerify.VerifyError.wrongDevice
        }
        try await open()

        var verify = PairVerify(credentials: credentials)
        let m2 = try await exchange(.pvStart, verify.startRequest())
        let m3 = try verify.respond(to: m2)
        let m4 = try await exchange(.pvNext, m3)
        try verify.handleFinish(m4)
        let keys = try verify.transportKeys()
        await connection?.enableEncryption(outputKey: keys.output, inputKey: keys.input)
        isMessaging = true

        // The same opening pyatv uses (minus touch and text input, which come later).
        _ = try await request("_systemInfo", Self.systemInfo(for: credentials))
        let localSID = UInt64(UInt32.random(in: .min ... .max))
        _ = try await request("_sessionStart", ["_srvT": "com.apple.tvremoteservices", "_sid": .int(localSID)])
        do {
            _ = try await request("TVRCSessionStart", ["ProtocolVersionKey": "1.2"])
        } catch {
            log.debug("TVRCSessionStart not supported: \(String(describing: error), privacy: .public)")
        }
        await startWatchingTV()

        guard wantsConnection else {
            close()
            return
        }
        log.info("Connected to \(self.device.name, privacy: .public)")
        setState(.connected)
    }

    /// Asks for the power state and subscribes to changes, then starts the text input
    /// session so the TV reports text fields gaining and losing focus. Like pyatv, none of
    /// this is required for the remote to work, so failures are only logged.
    private func startWatchingTV() async {
        do {
            let reply = try await request("FetchAttentionState", [:])
            if let state = reply["_c"]?["state"]?.intValue {
                publish(.asleep(state == 1))
            }
        } catch {
            log.debug("FetchAttentionState failed: \(String(describing: error), privacy: .public)")
        }
        for event in ["SystemStatus", "TVSystemStatus"] {
            try? await sendEvent("_interest", ["_regEvents": [.string(event)]])
        }
        do {
            let reply = try await request("_tiStart", [:])
            updateTextSession(from: reply["_c"])
        } catch {
            log.debug("_tiStart failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Takes `_tiD` from a `_tiStart` reply or `_tiStarted` event. No `_tiD` means no field
    /// has focus.
    private func updateTextSession(from content: OPACKValue?) {
        if let archive = content?["_tiD"]?.dataValue, let session = try? TextInputArchive.session(from: archive) {
            textSession = session
            publish(.keyboardShown(text: session.currentText))
        } else {
            textSession = nil
            publish(.keyboardHidden)
        }
    }

    /// Pair-verify failures that mean the TV forgot us or isn't the TV we paired with.
    private static func meansNotPaired(_ error: Error) -> Bool {
        if error is PairVerify.VerifyError { return true }
        if let error = error as? PairSetup.PairingError, error == .wrongPIN { return true }
        return false
    }

    /// `_systemInfo` content, modeled on pyatv's. The identifiers are derived from our
    /// pairing ID so they stay the same for this pairing without storing anything else.
    static func systemInfo(for credentials: PairingCredentials) -> OPACKValue {
        let digest = Array(SHA256.hash(data: credentials.deviceID))
        let rpID = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        let publicID = digest[6..<12].map { String(format: "%02X", $0) }.joined(separator: ":")
        return [
            "_bf": 0,
            "_cf": 512,
            "_clFl": 128,
            "_i": .string(rpID),
            "_idsID": .string(String(decoding: credentials.deviceID, as: UTF8.self)),
            "_pubID": .string(publicID),
            "_sf": 256,
            "_sv": "170.18",
            "model": "Mac",
            "name": .string(PairSetup.displayName),
        ]
    }

    // MARK: - Commands

    /// Presses a button: HID down, then up 20 ms later, or 1 s later for a long press.
    /// Presses run one at a time, in order.
    public func press(_ button: RemoteButton, hold: Bool = false) async throws {
        let previous = lastPress
        let press = Task {
            _ = try? await previous?.value
            try await sendPress(button, hold: hold)
        }
        lastPress = press
        try await press.value
    }

    private func sendPress(_ button: RemoteButton, hold: Bool) async throws {
        guard currentState == .connected else { throw SessionError.notConnected }
        _ = try await request("_hidC", ["_hBtS": 1, "_hidC": .int(UInt64(button.hidCode))])
        try await Task.sleep(for: hold ? .seconds(1) : .milliseconds(20))
        _ = try await request("_hidC", ["_hBtS": 2, "_hidC": .int(UInt64(button.hidCode))])
    }

    /// Makes the focused text field on the TV contain `text`. Rapid calls are coalesced:
    /// only the latest text is applied once the previous update finishes.
    public func sendText(_ text: String) async throws {
        desiredText = text
        if let textUpdate {
            try await textUpdate.value
            return
        }
        let update = Task { try await applyLatestText() }
        textUpdate = update
        try await update.value
    }

    private func applyLatestText() async throws {
        defer { textUpdate = nil }
        while let target = desiredText {
            desiredText = nil
            try await applyText(target)
        }
    }

    /// Inserts what's missing from the focused field, or clears and retypes if the text
    /// changed some other way. The field's session and text come from `_tiStarted` events;
    /// if we have none yet, ask once with `_tiStart`.
    private func applyText(_ target: String) async throws {
        guard currentState == .connected else { throw SessionError.notConnected }
        if textSession == nil {
            updateTextSession(from: try await request("_tiStart", [:])["_c"])
        }
        guard let session = textSession else { throw SessionError.noTextField }

        if target.hasPrefix(session.currentText) {
            let missing = String(target.dropFirst(session.currentText.count))
            if !missing.isEmpty {
                try await sendEvent("_tiC", ["_tiV": 1, "_tiD": .data(TextInputArchive.insert(missing, session: session.id))])
            }
        } else {
            try await sendEvent("_tiC", ["_tiV": 1, "_tiD": .data(TextInputArchive.clear(session: session.id))])
            if !target.isEmpty {
                try await sendEvent("_tiC", ["_tiV": 1, "_tiD": .data(TextInputArchive.insert(target, session: session.id))])
            }
        }
        if textSession?.id == session.id {
            textSession = TextInputArchive.Session(id: session.id, currentText: target)
        }
    }

    /// Sends an E_OPACK event (no reply expected).
    private func sendEvent(_ identifier: String, _ content: OPACKValue) async throws {
        guard let connection, isMessaging else { throw SessionError.notConnected }
        let message: OPACKValue = ["_i": .string(identifier), "_t": 1, "_c": content, "_x": .int(transactionID)]
        transactionID += 1
        try await connection.send(Frame(type: .eOPACK, payload: OPACK.encode(message)))
    }

    /// Sends an E_OPACK request and waits for the matching response.
    private func request(_ identifier: String, _ content: OPACKValue, timeout: Duration = .seconds(5)) async throws -> OPACKValue {
        guard let connection, isMessaging else { throw SessionError.notConnected }
        let xid = transactionID
        transactionID += 1
        let message: OPACKValue = ["_i": .string(identifier), "_t": 2, "_c": content, "_x": .int(xid)]
        let frame = Frame(type: .eOPACK, payload: OPACK.encode(message))

        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OPACKValue, Error>) in
            // Registered before sending, so even an instant reply finds its request.
            pendingRequests[xid] = continuation
            Task {
                do {
                    try await connection.send(frame)
                } catch {
                    self.failRequest(xid, with: error)
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                self.failRequest(xid, with: SessionError.timeout)
            }
        }
        if let errorMessage = response["_em"]?.stringValue {
            throw SessionError.commandFailed(errorMessage)
        }
        return response
    }

    private func failRequest(_ xid: UInt64, with error: Error) {
        pendingRequests.removeValue(forKey: xid)?.resume(throwing: error)
    }

    private func handleMessage(_ frame: Frame) {
        guard frame.type == .eOPACK, !frame.payload.isEmpty,
              let message = try? OPACK.decode(frame.payload) else { return }
        switch message["_t"]?.intValue {
        case 3:
            if let xid = message["_x"]?.intValue, let continuation = pendingRequests.removeValue(forKey: xid) {
                continuation.resume(returning: message)
            }
        case 1:
            handleEvent(message["_i"]?.stringValue ?? "", content: message["_c"])
        default:
            log.debug("Ignoring message \(message["_i"]?.stringValue ?? "?", privacy: .public)")
        }
    }

    private func handleEvent(_ identifier: String, content: OPACKValue?) {
        switch identifier {
        case "SystemStatus", "TVSystemStatus":
            if let state = content?["state"]?.intValue {
                publish(.asleep(state == 1))
            }
        case "_tiStarted":
            updateTextSession(from: content)
        case "_tiStopped":
            textSession = nil
            publish(.keyboardHidden)
        default:
            log.debug("Event \(identifier, privacy: .public)")
        }
    }

    // MARK: - Pairing

    /// Connects and starts pair-setup. The TV shows a 4-digit PIN.
    public func beginPairing() async throws {
        cancelPairing()
        var setup = PairSetup()
        try await open()
        do {
            let reply = try await exchange(.psStart, setup.startRequest())
            try setup.handleStartResponse(reply)
            pairSetup = setup
            log.info("Pairing started with \(self.device.name, privacy: .public)")
        } catch {
            close()
            throw error
        }
    }

    /// Sends the PIN, finishes pair-setup, saves the credentials and connects. On any
    /// failure the pairing attempt is over; call beginPairing again (the TV shows a new PIN).
    public func finishPairing(pin: String) async throws {
        guard var setup = pairSetup, connection != nil else { throw SessionError.notPairing }
        pairSetup = nil
        defer { close() }

        // Separate statements on purpose: `setup` is a struct, and proofRequest stores the SRP
        // proof in it, so it has to run before handleProofResponse reads `setup`.
        let m3 = try setup.proofRequest(pin: pin)
        let m4 = try await exchange(.psNext, m3)
        try setup.handleProofResponse(m4)
        let m6 = try await exchange(.psNext, try setup.exchangeRequest())
        let credentials = try setup.handleExchangeResponse(m6)
        try store.save(credentials, for: device.id)
        log.info("Paired with \(self.device.name, privacy: .public)")
        setState(.disconnected)
    }

    /// Stops a pairing in progress; the TV takes the PIN off the screen.
    public func cancelPairing() {
        guard pairSetup != nil || (connection != nil && !isMessaging) else { return }
        pairSetup = nil
        close()
    }

    // MARK: - Connection

    private func open() async throws {
        close()
        textSession = nil
        let connection = CompanionConnection(endpoint: device.endpoint)
        self.connection = connection
        bufferedFrames = []
        do {
            try await connection.connect()
        } catch {
            if self.connection === connection { self.connection = nil }
            throw error
        }

        Task { [weak self] in
            do {
                for try await frame in connection.frames {
                    await self?.received(frame, from: connection)
                }
                await self?.ended(SessionError.connectionClosed, for: connection)
            } catch {
                await self?.ended(error, for: connection)
            }
        }
    }

    /// Closes on purpose. No reconnect.
    private func close() {
        guard let connection else { return }
        self.connection = nil
        isMessaging = false
        Task { await connection.close() }
        failWaiters(SessionError.connectionClosed)
    }

    /// The connection dropped on its own.
    private func ended(_ error: Error, for source: CompanionConnection) {
        guard source === connection else { return }
        connection = nil
        failWaiters(error)
        if isMessaging {
            isMessaging = false
            log.info("Connection to \(self.device.name, privacy: .public) dropped: \(String(describing: error), privacy: .public)")
            if wantsConnection {
                setState(.disconnected)
                connectLoop?.cancel()
                connectLoop = Task { await runConnectLoop() }
            }
        }
    }

    private func failWaiters(_ error: Error) {
        if let waiter = frameWaiter {
            frameWaiter = nil
            waiter.continuation.resume(throwing: error)
        }
        let requests = pendingRequests
        pendingRequests = [:]
        requests.values.forEach { $0.resume(throwing: error) }
    }

    /// Sends one auth message and waits for the reply. Auth replies always come back as
    /// PS_Next / PV_Next frames, and they don't echo `_x`.
    private func exchange(_ type: FrameType, _ message: OPACKValue) async throws -> OPACKValue {
        guard let connection, case .dictionary(var entries) = message else { throw SessionError.connectionClosed }
        entries.append(.init("_x", .int(transactionID)))
        transactionID += 1
        try await connection.send(Frame(type: type, payload: OPACK.encode(.dictionary(entries))))

        let reply = try await nextFrame(timeout: .seconds(10))
        let expected: FrameType = (type == .psStart || type == .psNext) ? .psNext : .pvNext
        guard reply.type == expected else { throw SessionError.unexpectedFrame(reply.type.rawValue) }
        return try OPACK.decode(reply.payload)
    }

    private func nextFrame(timeout: Duration) async throws -> Frame {
        if !bufferedFrames.isEmpty { return bufferedFrames.removeFirst() }
        guard connection != nil else { throw SessionError.connectionClosed }

        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            frameWaiter = (id, continuation)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.timeOut(id)
            }
        }
    }

    private func received(_ frame: Frame, from source: CompanionConnection) {
        guard source === connection else { return }
        if isMessaging {
            handleMessage(frame)
        } else if let waiter = frameWaiter {
            frameWaiter = nil
            waiter.continuation.resume(returning: frame)
        } else {
            bufferedFrames.append(frame)
        }
    }

    private func timeOut(_ id: UUID) {
        guard let waiter = frameWaiter, waiter.id == id else { return }
        frameWaiter = nil
        waiter.continuation.resume(throwing: SessionError.timeout)
    }

    // MARK: - State

    private func setState(_ state: ConnectionState) {
        guard state != currentState else { return }
        currentState = state
        stateContinuations.values.forEach { $0.yield(state) }
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations[id] = nil
    }
}
