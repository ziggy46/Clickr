import Discovery
import Foundation
import Network
import Store
import TestSupport
import Testing
@testable import Session

/// Vectors/text_input.json: pyatv's pre-encoded RTI payloads and a sample `_tiStart` reply.
struct TextInputVector: Decodable {
    let session_uuid, insert_text, insert_payload, clear_payload, start_reply, start_reply_text: String

    static let shared: TextInputVector = {
        let url = Bundle.module.url(forResource: "text_input", withExtension: "json", subdirectory: "Vectors")!
        return try! JSONDecoder().decode(TextInputVector.self, from: Data(contentsOf: url))
    }()
}

@Suite struct TextInputArchiveTests {
    let vector = TextInputVector.shared

    @Test func insertMatchesPyatv() throws {
        let ours = TextInputArchive.insert(vector.insert_text, session: Data(hex: vector.session_uuid))
        #expect(try BinaryPlist.decode(ours) == BinaryPlist.decode(Data(hex: vector.insert_payload)))
    }

    @Test func clearMatchesPyatv() throws {
        let ours = TextInputArchive.clear(session: Data(hex: vector.session_uuid))
        #expect(try BinaryPlist.decode(ours) == BinaryPlist.decode(Data(hex: vector.clear_payload)))
    }

    @Test func readsSessionFromStartReply() throws {
        let session = try #require(try TextInputArchive.session(from: Data(hex: vector.start_reply)))
        #expect(session.id.hex == vector.session_uuid)
        #expect(session.currentText == vector.start_reply_text)
    }

    @Test func noSessionMeansNoTextField() throws {
        let archive = BinaryPlist.encode(.dict(["$top": .dict([:]), "$objects": .array([.string("$null")])]))
        #expect(try TextInputArchive.session(from: archive) == nil)
    }
}

@Suite struct BinaryPlistTests {
    @Test(arguments: [
        PlistValue.null, .bool(true), .bool(false),
        .int(0), .int(255), .int(256), .int(70_000), .int(5_000_000_000), .int(-1),
        .string(""), .string("ascii"), .string("Café ’s Room"), .string(String(repeating: "x", count: 40)),
        .data(Data()), .data(Data(repeating: 7, count: 300)),
        .uid(0), .uid(300),
        .array([.int(1), .string("two"), .array([])]),
        .dict(["b": .int(2), "a": .dict(["nested": .uid(4)])]),
        .array((0..<300).map { .int(Int64($0)) }),
    ])
    func roundTrips(_ value: PlistValue) throws {
        #expect(try BinaryPlist.decode(BinaryPlist.encode(value)) == value)
    }

    @Test func foundationReadsOurOutput() throws {
        let data = BinaryPlist.encode(.dict(["name": .string("Clickr"), "count": .int(3), "items": .array([.data(Data([1, 2]))])]))
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        #expect(parsed?["name"] as? String == "Clickr")
        #expect(parsed?["count"] as? Int == 3)
        #expect((parsed?["items"] as? [Data])?.first == Data([1, 2]))
    }

    @Test func rejectsGarbage() {
        #expect(throws: BinaryPlist.DecodingError.self) { try BinaryPlist.decode(Data("not a plist".utf8)) }
    }
}

private func device(at endpoint: NWEndpoint) -> DiscoveredDevice {
    DiscoveredDevice(name: "Fake TV", endpoint: endpoint, txt: ["rpMd": "AppleTV11,1", "rpMRtID": "FAKE-TV"])!
}

private func connectedSession() async throws -> (FakeAppleTV, AppleTVSession) {
    let tv = try FakeAppleTV(pin: "4821")
    try await tv.start()
    let session = AppleTVSession(device: device(at: tv.endpoint), store: InMemoryCredentialStore())
    try await session.beginPairing()
    try await session.finishPairing(pin: "4821")
    await session.connect()
    for await state in await session.state where state == .connected { break }
    return (tv, session)
}

/// `_tiC` is an event with no reply, so give the fake TV a moment to apply it.
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Suite(.serialized) struct TypingTests {
    @Test func typesAppendsAndRetypes() async throws {
        let (tv, session) = try await connectedSession()
        defer { tv.stop() }

        try await session.sendText("Star")
        #expect(await eventually { tv.snapshot().fieldText == "Star" })
        try await session.sendText("Star Wars")
        #expect(await eventually { tv.snapshot().fieldText == "Star Wars" })
        // Not an extension of what's there: clear and type it all.
        try await session.sendText("Andor")
        #expect(await eventually { tv.snapshot().fieldText == "Andor" })
        try await session.sendText("")
        #expect(await eventually { tv.snapshot().fieldText == "" })
        #expect(await eventually { tv.snapshot().textOperations == ["insert:Star", "insert: Wars", "clear", "insert:Andor", "clear"] })
        await session.disconnect()
    }

    @Test func picksUpTextAlreadyOnTheTV() async throws {
        let (tv, session) = try await connectedSession()
        defer { tv.stop() }
        var updates = await session.updates.makeAsyncIterator()
        tv.showKeyboard(text: "Sta")
        #expect(await updates.next() == .keyboardShown(text: "Sta"))

        try await session.sendText("Star")
        #expect(await eventually { tv.snapshot().textOperations == ["insert:r"] })
        await session.disconnect()
    }

    @Test func rapidTypingEndsOnTheLatestText() async throws {
        let (tv, session) = try await connectedSession()
        defer { tv.stop() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for length in 1...12 {
                group.addTask { try await session.sendText(String("The Mandalorian".prefix(length))) }
                try await Task.sleep(for: .milliseconds(2))
            }
            try await group.waitForAll()
        }
        try await session.sendText("The Mandalorian")
        #expect(await eventually { tv.snapshot().fieldText == "The Mandalorian" })
        await session.disconnect()
    }

    @Test func noFocusedFieldThrows() async throws {
        let (tv, session) = try await connectedSession()
        defer { tv.stop() }
        var updates = await session.updates.makeAsyncIterator()
        tv.hideKeyboard()
        #expect(await updates.next() == .keyboardHidden)

        await #expect(throws: AppleTVSession.SessionError.noTextField) {
            try await session.sendText("hello")
        }
        await session.disconnect()
    }
}
