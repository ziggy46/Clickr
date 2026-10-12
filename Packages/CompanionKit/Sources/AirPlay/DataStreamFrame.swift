import Foundation
import MRP
import Plist

/// A frame on the AirPlay data channel: a 32-byte big-endian header, then a binary plist
/// `{"params": {"data": <varint length + protobuf>...}}`. The TV acknowledges our "sync"
/// frames with "rply" frames and we must do the same for its "sync" frames.
struct DataStreamFrame: Sendable, Equatable {
    static let headerLength = 32

    var messageType: String   // "sync" or "rply"
    var command: String       // "comm" for our sends, empty in replies
    var seqno: UInt64
    var payload: Data

    var isSync: Bool { messageType == "sync" }

    /// Wraps MRP messages for sending.
    static func sync(_ messages: [Data], seqno: UInt64) -> DataStreamFrame {
        let inner = messages.reduce(Data()) { $0 + ProtoWriter.varint(UInt64($1.count)) + $1 }
        let payload = BinaryPlist.encode(.dict(["params": .dict(["data": .data(inner)])]))
        return DataStreamFrame(messageType: "sync", command: "comm", seqno: seqno, payload: payload)
    }

    /// Acknowledges a frame from the TV.
    static func reply(to frame: DataStreamFrame) -> DataStreamFrame {
        DataStreamFrame(messageType: "rply", command: "", seqno: frame.seqno, payload: Data())
    }

    func encoded() -> Data {
        var data = Data()
        data += Self.bigEndian(UInt64(Self.headerLength + payload.count), count: 4)
        data += Self.padded(messageType, to: 12)
        data += Self.padded(command, to: 4)
        data += Self.bigEndian(seqno, count: 8)
        data += Self.bigEndian(0, count: 4)
        data += payload
        return data
    }

    /// Takes one whole frame off the front of `buffer`, if there is one.
    static func next(from buffer: inout Data) -> DataStreamFrame? {
        guard buffer.count >= headerLength else { return nil }
        let bytes = [UInt8](buffer.prefix(headerLength))
        let size = Int(bytes[0..<4].reduce(0) { ($0 << 8) | UInt64($1) })
        guard size >= headerLength, buffer.count >= size else { return nil }
        let frame = DataStreamFrame(
            messageType: text(bytes[4..<16]),
            command: text(bytes[16..<20]),
            seqno: bytes[20..<28].reduce(0) { ($0 << 8) | UInt64($1) },
            payload: Data(buffer.dropFirst(headerLength).prefix(size - headerLength))
        )
        buffer = Data(buffer.dropFirst(size))
        return frame
    }

    /// The MRP messages inside the payload. Each normally has a varint length in front; a
    /// payload starting with 0x08 (the tag of ProtocolMessage.type) is one bare message.
    func mrpMessages() -> [Data] {
        guard !payload.isEmpty, let plist = try? BinaryPlist.decode(payload),
              case .data(let data)? = plist["params"]?["data"] else { return [] }
        if data.first == 0x08 { return [data] }
        var messages: [Data] = []
        var rest = data
        while !rest.isEmpty {
            var reader = [UInt8](rest)[...]
            var length: UInt64 = 0
            var shift: UInt64 = 0
            var consumed = 0
            while let byte = reader.first, shift < 64 {
                reader = reader.dropFirst()
                consumed += 1
                length |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
            }
            guard consumed > 0, rest.count >= consumed + Int(length) else { break }
            messages.append(Data(rest.dropFirst(consumed).prefix(Int(length))))
            rest = Data(rest.dropFirst(consumed + Int(length)))
        }
        return messages
    }

    private static func bigEndian(_ value: UInt64, count: Int) -> Data {
        Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) })
    }

    private static func padded(_ text: String, to length: Int) -> Data {
        Data(text.utf8.prefix(length)) + Data(count: max(0, length - text.utf8.count))
    }

    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}
