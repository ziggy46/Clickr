import Foundation
import Network

/// One TCP connection to the TV that can switch on HAP framing. Hands back plaintext as it
/// arrives; the callers parse HTTP messages or data-stream frames out of it.
actor HAPChannel {
    enum ChannelError: Error, Equatable {
        case failed(String)
        case closed
    }

    nonisolated let queue = DispatchSerialQueue(label: "Clickr.HAPChannel")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Plaintext as it arrives. Finishes (or throws) when the connection ends.
    nonisolated let received: AsyncThrowingStream<Data, Error>

    private let connection: NWConnection
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var framing: HAPFraming?
    private var connectContinuation: CheckedContinuation<Void, Error>?

    init(endpoint: NWEndpoint, connectTimeout: Int = 5) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = connectTimeout
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // IPv4 keeps the addresses simple for the RTSP URI and the extra channels.
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        parameters.includePeerToPeer = false
        connection = NWConnection(to: endpoint, using: parameters)
        (received, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
    }

    func connect() async throws {
        connection.stateUpdateHandler = { [weak self] state in
            self?.assumeIsolated { $0.stateChanged(state) }
        }
        try await withCheckedThrowingContinuation { continuation in
            connectContinuation = continuation
            connection.start(queue: queue)
        }
    }

    /// The TV's address and our own, once connected.
    var remoteHost: NWEndpoint.Host? {
        if case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint { host } else { nil }
    }

    var localHost: NWEndpoint.Host? {
        if case .hostPort(let host, _)? = connection.currentPath?.localEndpoint { host } else { nil }
    }

    func enableEncryption(outputKey: Data, inputKey: Data) {
        framing = HAPFraming(outputKey: outputKey, inputKey: inputKey)
    }

    func send(_ data: Data) async throws {
        var wire = data
        if framing != nil {
            wire = try framing!.seal(data)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: wire, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: ChannelError.failed(String(describing: error)))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func close() {
        connection.cancel()
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connectContinuation?.resume()
            connectContinuation = nil
            receive()
        case .waiting(let error), .failed(let error):
            connectContinuation?.resume(throwing: ChannelError.failed(String(describing: error)))
            connectContinuation = nil
            continuation.finish(throwing: ChannelError.failed(String(describing: error)))
            connection.cancel()
        case .cancelled:
            connectContinuation?.resume(throwing: ChannelError.closed)
            connectContinuation = nil
            continuation.finish()
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            self?.assumeIsolated { $0.handle(data, isComplete: isComplete, error: error) }
        }
    }

    private func handle(_ data: Data?, isComplete: Bool, error: NWError?) {
        if let error {
            continuation.finish(throwing: ChannelError.failed(String(describing: error)))
            connection.cancel()
            return
        }
        if let data, !data.isEmpty {
            do {
                let plaintext = framing != nil ? try framing!.open(data) : data
                if !plaintext.isEmpty { continuation.yield(plaintext) }
            } catch {
                continuation.finish(throwing: error)
                connection.cancel()
                return
            }
        }
        if isComplete {
            connection.cancel()
        } else {
            receive()
        }
    }
}
