import Foundation
import Network
import TestSupport
import Testing
@testable import Transport

// OPACK for {"_pd": TLV{Method: 0, SeqNo: 1}, "_pwTy": 1, "_x": 0}, made with pyatv's opack.pack.
private let psStartPayload = Data(hex: "e3435f706476000100060101455f7077547909425f7808")

/// Reads `count` frames from the connection, failing if they don't all arrive in time.
private func frames(_ count: Int, from connection: CompanionConnection, timeout: Duration = .seconds(5)) async throws -> [Frame] {
    try await withThrowingTaskGroup(of: [Frame].self) { group in
        group.addTask {
            var result: [Frame] = []
            for try await frame in connection.frames {
                result.append(frame)
                if result.count == count { break }
            }
            return result
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw CancellationError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

@Suite struct FrameHeaderTests {
    @Test func encodesTypeAndBigEndianLength() {
        #expect(FrameHeader(type: .psStart, payloadLength: 23).bytes == Data([0x03, 0x00, 0x00, 0x17]))
        #expect(FrameHeader(type: .eOPACK, payloadLength: 0x01_02_03).bytes == Data([0x08, 0x01, 0x02, 0x03]))
        #expect(FrameHeader(type: .noOp, payloadLength: 0).bytes == Data([0x01, 0x00, 0x00, 0x00]))
    }

    @Test func decodes() {
        let header = FrameHeader(bytes: [0x04, 0xFF, 0xFF, 0xFF])
        #expect(header.type == .psNext)
        #expect(header.payloadLength == FrameHeader.maxPayloadLength)
    }

    @Test func roundTrips() {
        for length in [0, 1, 255, 256, 65_535, 65_536, 0xFF_FFFF] {
            let header = FrameHeader(type: .pvNext, payloadLength: length)
            #expect(FrameHeader(bytes: header.bytes) == header)
        }
    }

    @Test func keepsUnknownTypes() {
        #expect(FrameHeader(bytes: [200, 0, 0, 1]).type.rawValue == 200)
    }
}

@Suite(.serialized) struct CompanionConnectionTests {
    @Test func writesHeaderThenPayload() async throws {
        let server = try await LoopbackServer.start(.record)
        defer { server.stop() }
        let connection = CompanionConnection(endpoint: server.endpoint)
        try await connection.connect()

        try await connection.send(Frame(type: .psStart, payload: psStartPayload))
        let bytes = try await server.waitForBytes(4 + psStartPayload.count)
        #expect(bytes == Data([0x03, 0x00, 0x00, 0x17]) + psStartPayload)
        await connection.close()
    }

    @Test func roundTripsFramesThroughEcho() async throws {
        let server = try await LoopbackServer.start(.echo)
        defer { server.stop() }
        let connection = CompanionConnection(endpoint: server.endpoint)
        try await connection.connect()

        let large = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let sent = [
            Frame(type: .psStart, payload: psStartPayload),
            Frame(type: .noOp),
            Frame(type: FrameType(rawValue: 200), payload: Data([1, 2, 3, 4, 5])),
            Frame(type: .eOPACK, payload: large),
            Frame(type: .pvNext, payload: Data([0xAB])),
        ]
        for frame in sent {
            try await connection.send(frame)
        }
        #expect(try await frames(sent.count, from: connection) == sent)
        await connection.close()
    }

    @Test func reassemblesSplitAndBatchedFrames() async throws {
        let server = try await LoopbackServer.start(.script([
            Data([0x07, 0x00]),                      // header split in two...
            Data([0x00, 0x03]),
            Data([0xAA, 0xBB]),                      // ...and the payload too
            Data([0xCC]),
            Data([0x08, 0x00, 0x00, 0x01, 0xFF,      // two whole frames in one write
                  0x01, 0x00, 0x00, 0x00]),
        ], thenClose: false))
        defer { server.stop() }
        let connection = CompanionConnection(endpoint: server.endpoint)
        try await connection.connect()

        #expect(try await frames(3, from: connection) == [
            Frame(type: .uOPACK, payload: Data([0xAA, 0xBB, 0xCC])),
            Frame(type: .eOPACK, payload: Data([0xFF])),
            Frame(type: .noOp),
        ])
        await connection.close()
    }

    @Test func streamEndsWhenRemoteCloses() async throws {
        let server = try await LoopbackServer.start(.script([Data([0x04, 0x00, 0x00, 0x01, 0x42])], thenClose: true))
        defer { server.stop() }
        let connection = CompanionConnection(endpoint: server.endpoint)
        try await connection.connect()

        var received: [Frame] = []
        for try await frame in connection.frames {
            received.append(frame)
        }
        #expect(received == [Frame(type: .psNext, payload: Data([0x42]))])
    }

    @Test func connectFailsWhenNothingIsListening() async throws {
        let server = try await LoopbackServer.start(.record)
        let endpoint = server.endpoint
        server.stop()
        try await Task.sleep(for: .milliseconds(100))

        let connection = CompanionConnection(endpoint: endpoint, connectTimeout: 2)
        await #expect(throws: CompanionConnection.ConnectionError.self) {
            try await connection.connect()
        }
    }

    @Test func sendBeforeConnectThrows() async {
        let connection = CompanionConnection(endpoint: .hostPort(host: "127.0.0.1", port: 9))
        await #expect(throws: CompanionConnection.ConnectionError.notConnected) {
            try await connection.send(Frame(type: .noOp))
        }
    }
}
