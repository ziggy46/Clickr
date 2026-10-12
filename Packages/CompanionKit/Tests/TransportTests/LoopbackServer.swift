import Foundation
import Network

/// A plain TCP server on 127.0.0.1 (no framer) for exercising CompanionConnection
/// without an Apple TV.
final class LoopbackServer: @unchecked Sendable {
    enum Behavior {
        /// Send every byte straight back.
        case echo
        /// Keep what arrives in `received`.
        case record
        /// Write these chunks one at a time with a short pause between them, then optionally hang up.
        case script([Data], thenClose: Bool)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackServer")
    private let behavior: Behavior
    private var connections: [NWConnection] = []
    private var receivedBytes = Data()
    private var startContinuation: CheckedContinuation<Void, Error>?

    private init(behavior: Behavior) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.behavior = behavior
    }

    static func start(_ behavior: Behavior) async throws -> LoopbackServer {
        let server = try LoopbackServer(behavior: behavior)
        try await server.startListening()
        return server
    }

    var endpoint: NWEndpoint {
        .hostPort(host: "127.0.0.1", port: listener.port!)
    }

    var received: Data {
        queue.sync { receivedBytes }
    }

    func stop() {
        queue.sync {
            connections.forEach { $0.cancel() }
            listener.cancel()
        }
    }

    /// Polls until at least `count` bytes have arrived.
    func waitForBytes(_ count: Int, timeout: Duration = .seconds(5)) async throws -> Data {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let data = received
            if data.count >= count { return data }
            try await Task.sleep(for: .milliseconds(10))
        }
        return received
    }

    private func startListening() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.startContinuation?.resume()
                    self.startContinuation = nil
                case .failed(let error):
                    self.startContinuation?.resume(throwing: error)
                    self.startContinuation = nil
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        switch behavior {
        case .echo, .record:
            receive(on: connection)
        case .script(let chunks, let thenClose):
            sendChunks(chunks[...], on: connection, thenClose: thenClose)
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { return }
            if let data, !data.isEmpty {
                switch self.behavior {
                case .echo: connection.send(content: data, completion: .idempotent)
                case .record: self.receivedBytes.append(data)
                case .script: break
                }
            }
            if !isComplete { self.receive(on: connection) }
        }
    }

    private func sendChunks(_ chunks: ArraySlice<Data>, on connection: NWConnection, thenClose: Bool) {
        guard let chunk = chunks.first else {
            if thenClose {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
            }
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] _ in
            self?.queue.asyncAfter(deadline: .now() + .milliseconds(50)) {
                self?.sendChunks(chunks.dropFirst(), on: connection, thenClose: thenClose)
            }
        })
    }
}
