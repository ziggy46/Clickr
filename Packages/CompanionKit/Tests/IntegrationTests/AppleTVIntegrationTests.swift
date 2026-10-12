import Foundation
import Network
import Testing
import Transport

// These need a real Apple TV on the network and are skipped otherwise. Run with:
//
//   CLICKR_TV_HOST=<tv ip> CLICKR_TV_PORT=<companion port> swift test --filter IntegrationTests
//
// Get the port with `dns-sd -L "<TV name>" _companion-link._tcp local.`

private let environment = ProcessInfo.processInfo.environment
private let tvHost = environment["CLICKR_TV_HOST"]
private let tvPort = environment["CLICKR_TV_PORT"].flatMap(UInt16.init) ?? 49153

@Suite(.enabled(if: tvHost != nil, "set CLICKR_TV_HOST to run against a real Apple TV"))
struct AppleTVIntegrationTests {
    /// Milestone 2: send a hand-built PS_Start and parse the reply frame.
    /// The TV shows a pairing PIN until the connection closes.
    @Test func pairSetupStartGetsAReply() async throws {
        let endpoint = NWEndpoint.hostPort(host: .init(tvHost!), port: .init(rawValue: tvPort)!)
        let connection = CompanionConnection(endpoint: endpoint)
        try await connection.connect()
        defer { Task { await connection.close() } }

        // OPACK for {"_pd": TLV{Method: 0, SeqNo: 1}, "_pwTy": 1, "_x": 0}, made with pyatv.
        let payload = Data([
            0xE3, 0x43, 0x5F, 0x70, 0x64, 0x76, 0x00, 0x01, 0x00, 0x06, 0x01, 0x01, 0x45, 0x5F,
            0x70, 0x77, 0x54, 0x79, 0x09, 0x42, 0x5F, 0x78, 0x08,
        ])
        try await connection.send(Frame(type: .psStart, payload: payload))

        let reply = try await withThrowingTaskGroup(of: Frame?.self) { group in
            group.addTask {
                for try await frame in connection.frames { return frame }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }

        let frame = try #require(reply, "no reply within 5 s")
        print("Reply \(frame.type), \(frame.payload.count) bytes: \(frame.payload.map { String(format: "%02x", $0) }.joined())")
        // Every frame after the first in pair-setup uses PS_Next, replies included.
        #expect(frame.type == .psNext)
        #expect(!frame.payload.isEmpty)
    }
}
