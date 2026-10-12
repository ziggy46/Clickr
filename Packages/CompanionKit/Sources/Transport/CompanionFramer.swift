import Foundation
import Network

/// Splits the TCP stream into Companion frames so NWConnection hands us one whole frame per
/// receive. The frame type travels in the message metadata.
final class CompanionFramer: NWProtocolFramerImplementation {
    static let definition = NWProtocolFramer.Definition(implementation: CompanionFramer.self)
    static var label: String { "Companion" }

    init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var header: FrameHeader?
            let gotHeader = framer.parseInput(
                minimumIncompleteLength: FrameHeader.length,
                maximumLength: FrameHeader.length
            ) { buffer, _ in
                guard let buffer, buffer.count >= FrameHeader.length else { return 0 }
                header = FrameHeader(bytes: buffer)
                return FrameHeader.length
            }
            guard gotHeader, let header else {
                return FrameHeader.length
            }

            let message = NWProtocolFramer.Message(frameType: header.type)
            // Returns false when the payload hasn't fully arrived; the framer finishes the
            // delivery itself once it has, then calls us again.
            if !framer.deliverInputNoCopy(length: header.payloadLength, message: message, isComplete: true) {
                return 0
            }
        }
    }

    func handleOutput(
        framer: NWProtocolFramer.Instance,
        message: NWProtocolFramer.Message,
        messageLength: Int,
        isComplete: Bool
    ) {
        let header = FrameHeader(type: message.frameType, payloadLength: messageLength)
        framer.writeOutput(data: header.bytes)
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            framer.markFailed(error: .posix(.EIO))
        }
    }
}

extension NWProtocolFramer.Message {
    private static let frameTypeKey = "CompanionFrameType"

    convenience init(frameType: FrameType) {
        self.init(definition: CompanionFramer.definition)
        self[Self.frameTypeKey] = frameType.rawValue
    }

    var frameType: FrameType {
        FrameType(rawValue: self[Self.frameTypeKey] as? UInt8 ?? 0)
    }
}
