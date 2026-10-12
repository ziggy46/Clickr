import Discovery
import Foundation
import OPACK
import os
import Pairing
import Store
import Transport

/// One Apple TV: pairing now, and from Milestone 6 the encrypted connection and commands.
public actor AppleTVSession {
    public enum SessionError: Error, Equatable {
        /// finishPairing was called without a pairing in progress.
        case notPairing
        /// The TV didn't answer in time.
        case timeout
        /// The TV answered with a frame we didn't expect.
        case unexpectedFrame(UInt8)
        /// The connection closed before the TV answered.
        case connectionClosed
    }

    public nonisolated let device: DiscoveredDevice
    private let store: CredentialStore
    private let log = Logger(subsystem: "com.ziggy46.clickr", category: "Session")

    private var currentState: ConnectionState
    private var stateContinuations: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

    private var connection: CompanionConnection?
    private var pairSetup: PairSetup?
    private var transactionID = UInt64.random(in: 0...0xFFFF)

    // Frames from the reader task wait here until someone asks for one.
    private var bufferedFrames: [Frame] = []
    private var frameWaiter: (id: UUID, continuation: CheckedContinuation<Frame, Error>)?
    private var connectionEnded: Error?

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

    /// Sends the PIN, finishes pair-setup and saves the credentials. On any failure the
    /// pairing attempt is over; call beginPairing again (the TV shows a new PIN).
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
        // Milestone 6 connects with pair-verify from here.
        setState(.disconnected)
    }

    /// Stops a pairing in progress; the TV takes the PIN off the screen.
    public func cancelPairing() {
        pairSetup = nil
        close()
    }

    // MARK: - Connection

    private func open() async throws {
        let connection = CompanionConnection(endpoint: device.endpoint)
        self.connection = connection
        bufferedFrames = []
        connectionEnded = nil
        do {
            try await connection.connect()
        } catch {
            self.connection = nil
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

    private func close() {
        guard let connection else { return }
        self.connection = nil
        Task { await connection.close() }
        ended(SessionError.connectionClosed, for: connection)
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
        if let connectionEnded { throw connectionEnded }

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
        if let waiter = frameWaiter {
            frameWaiter = nil
            waiter.continuation.resume(returning: frame)
        } else {
            bufferedFrames.append(frame)
        }
    }

    private func ended(_ error: Error, for source: CompanionConnection) {
        guard source === connection || connection == nil else { return }
        connectionEnded = error
        if let waiter = frameWaiter {
            frameWaiter = nil
            waiter.continuation.resume(throwing: error)
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
