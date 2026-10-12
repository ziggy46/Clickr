import Foundation
import Network
import os

/// A TCP connection to an Apple TV's Companion port that sends and receives whole frames.
///
/// Encryption sits on top of this (Milestone 6): the cipher encrypts payloads before `send`
/// and decrypts what comes out of `frames`, rebuilding the header for the AAD.
public actor CompanionConnection {
    public enum ConnectionError: Error, Equatable {
        case alreadyStarted
        case notConnected
        case payloadTooLarge(Int)
        case failed(String)
        case cancelled
    }

    nonisolated let queue = DispatchSerialQueue(label: "Clickr.CompanionConnection")
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Every frame received, in order. Finishes when the connection closes, or throws if it fails.
    public nonisolated let frames: AsyncThrowingStream<Frame, Error>

    private let log = Logger(subsystem: "com.ziggy46.clickr", category: "Transport")
    private let connection: NWConnection
    private let framesContinuation: AsyncThrowingStream<Frame, Error>.Continuation
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var started = false
    private var isReady = false

    public init(endpoint: NWEndpoint, connectTimeout: Int = 5) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = connectTimeout
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = false
        let framer = NWProtocolFramer.Options(definition: CompanionFramer.definition)
        parameters.defaultProtocolStack.applicationProtocols.insert(framer, at: 0)

        connection = NWConnection(to: endpoint, using: parameters)
        (frames, framesContinuation) = AsyncThrowingStream.makeStream(of: Frame.self, throwing: Error.self)
    }

    /// Connects and returns once the connection is ready.
    public func connect() async throws {
        guard !started else { throw ConnectionError.alreadyStarted }
        started = true

        connection.stateUpdateHandler = { [weak self] state in
            self?.assumeIsolated { $0.stateChanged(state) }
        }
        try await withCheckedThrowingContinuation { continuation in
            connectContinuation = continuation
            connection.start(queue: queue)
        }
    }

    public func send(_ frame: Frame) async throws {
        guard isReady else { throw ConnectionError.notConnected }
        guard frame.payload.count <= FrameHeader.maxPayloadLength else {
            throw ConnectionError.payloadTooLarge(frame.payload.count)
        }

        let message = NWProtocolFramer.Message(frameType: frame.type)
        let context = NWConnection.ContentContext(identifier: "CompanionFrame", metadata: [message])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: frame.payload,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: ConnectionError.failed(String(describing: error)))
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    public func close() {
        connection.cancel()
    }

    // MARK: - Connection events

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
            connectContinuation?.resume()
            connectContinuation = nil
            receiveNext()
        case .waiting(let error), .failed(let error):
            // While connecting, "waiting" means it can't reach the TV (refused, no route),
            // so give up instead of letting NWConnection retry forever.
            fail(ConnectionError.failed(String(describing: error)))
        case .cancelled:
            isReady = false
            connectContinuation?.resume(throwing: ConnectionError.cancelled)
            connectContinuation = nil
            framesContinuation.finish()
        default:
            break
        }
    }

    private func fail(_ error: ConnectionError) {
        log.error("Connection failed: \(String(describing: error), privacy: .public)")
        isReady = false
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
        framesContinuation.finish(throwing: error)
        connection.cancel()
    }

    private func receiveNext() {
        connection.receiveMessage { [weak self] content, context, _, error in
            self?.assumeIsolated { $0.received(content, context: context, error: error) }
        }
    }

    private func received(_ content: Data?, context: NWConnection.ContentContext?, error: NWError?) {
        if let error {
            fail(.failed(String(describing: error)))
            return
        }
        if let message = context?.protocolMetadata(definition: CompanionFramer.definition) as? NWProtocolFramer.Message {
            framesContinuation.yield(Frame(type: message.frameType, payload: content ?? Data()))
        } else if context?.isFinal == true {
            // The TV closed its side.
            connection.cancel()
            return
        }
        receiveNext()
    }
}
