import Foundation
import Network
import os

/// A TCP connection to an Apple TV's Companion port that sends and receives whole frames.
///
/// After pair-verify, `enableEncryption` turns on the frame cipher: `send` encrypts payloads
/// and `frames` yields decrypted ones. A frame that fails to decrypt closes the connection.
public actor CompanionConnection {
    public enum ConnectionError: Error, Equatable {
        case alreadyStarted
        case notConnected
        case payloadTooLarge(Int)
        case failed(String)
        case cancelled
        case decryptionFailed
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
    private var cipher: FrameCipher?

    public init(endpoint: NWEndpoint, connectTimeout: Int = 5) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = connectTimeout
        // Notice a TV that went away (unplugged, Wi-Fi dropped) within about half a minute.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
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

    /// Encrypts every frame from here on, in both directions.
    public func enableEncryption(outputKey: Data, inputKey: Data) {
        cipher = FrameCipher(outputKey: outputKey, inputKey: inputKey)
    }

    public func send(_ frame: Frame) async throws {
        guard isReady else { throw ConnectionError.notConnected }
        var payload = frame.payload
        if cipher != nil {
            payload = try cipher!.seal(payload, type: frame.type)
        }
        guard payload.count <= FrameHeader.maxPayloadLength else {
            throw ConnectionError.payloadTooLarge(frame.payload.count)
        }

        // Sealing and handing the frame to NWConnection happen without a suspension in
        // between, so nonces go out in counter order.
        let message = NWProtocolFramer.Message(frameType: frame.type)
        let context = NWConnection.ContentContext(identifier: "CompanionFrame", metadata: [message])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: payload,
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
            var payload = content ?? Data()
            if cipher != nil {
                do {
                    payload = try cipher!.open(payload, type: message.frameType)
                } catch {
                    fail(.decryptionFailed)
                    return
                }
            }
            framesContinuation.yield(Frame(type: message.frameType, payload: payload))
        } else if context?.isFinal == true {
            // The TV closed its side.
            connection.cancel()
            return
        }
        receiveNext()
    }
}
