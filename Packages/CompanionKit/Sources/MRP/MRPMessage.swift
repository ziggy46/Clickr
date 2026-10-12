import Foundation

/// An MRP ProtocolMessage: a type, an optional identifier that replies echo, and the inner
/// message carried in a type-specific extension field.
public struct MRPMessage: Sendable, Equatable {
    /// ProtocolMessage.Type values used here, with the extension field each one uses.
    public enum Kind: Int, Sendable {
        case setState = 4
        case deviceInfo = 15
        case clientUpdatesConfig = 16
        case getKeyboardSession = 24
        case playbackQueueRequest = 32
        case deviceInfoUpdate = 37
        case setConnectionState = 38
        case setNowPlayingClient = 46
        case setNowPlayingPlayer = 47
        case removeClient = 53
        case removePlayer = 54
        case updateClient = 55
        case updateContentItem = 56
        case setDefaultSupportedCommands = 72

        var extensionField: Int? {
            switch self {
            case .setState: 9
            case .deviceInfo, .deviceInfoUpdate: 20
            case .clientUpdatesConfig: 21
            case .getKeyboardSession: nil
            case .playbackQueueRequest: 37
            case .setConnectionState: 42
            case .setNowPlayingClient: 50
            case .setNowPlayingPlayer: 51
            case .removeClient: 57
            case .removePlayer: 58
            case .updateClient: 59
            case .updateContentItem: 60
            case .setDefaultSupportedCommands: 75
            }
        }
    }

    public let type: Int
    public let identifier: String?
    /// The inner message, if this type has one and it was present.
    public let inner: ProtoMessage?

    public var kind: Kind? { Kind(rawValue: type) }

    public init(decoding data: Data) throws {
        let envelope = try ProtoMessage(decoding: data)
        type = Int(envelope.uint(1) ?? 0)
        identifier = envelope.string(2)
        inner = Kind(rawValue: type)?.extensionField.flatMap { envelope.message($0) }
    }

    /// Serializes a message the way pyatv does: type, identifier, errorCode 0 and
    /// uniqueIdentifier, then the extension (protobuf writes extensions after normal fields).
    public static func encode(
        _ kind: Kind,
        identifier: String? = nil,
        uniqueIdentifier: String = UUID().uuidString,
        inner: ProtoWriter? = nil
    ) -> Data {
        var envelope = ProtoWriter()
        envelope.varint(1, UInt64(kind.rawValue))
        if let identifier { envelope.string(2, identifier) }
        envelope.varint(4, 0)
        envelope.string(85, uniqueIdentifier)
        if let inner, let field = kind.extensionField {
            envelope.message(field, inner)
        }
        return envelope.data
    }
}

/// The messages Clickr sends, with the field values pyatv uses.
public enum MRPRequests {
    /// Who we are. Mostly pyatv's values, which the TV is known to accept.
    public static func deviceInfo(name: String, uniqueIdentifier: String, systemBuildVersion: String) -> ProtoWriter {
        var info = ProtoWriter()
        info.string(1, uniqueIdentifier)
        info.string(2, name)
        info.string(3, "iPhone")
        info.string(4, systemBuildVersion)
        info.string(5, "com.apple.TVRemote")
        info.string(6, "344.28")
        info.int(7, 1)          // protocolVersion
        info.varint(8, 108)     // lastSupportedMessageType
        info.bool(9, true)      // supportsSystemPairing
        info.bool(10, true)     // allowsPairing
        info.string(12, "com.apple.TVMusic")
        info.bool(13, true)     // supportsACL
        info.bool(14, true)     // supportsSharedQueue
        info.bool(15, true)     // supportsExtendedMotion
        info.varint(17, 2)      // sharedQueueVersion
        info.varint(21, 1)      // deviceClass: iPhone
        info.varint(22, 1)      // logicalDeviceCount
        return info
    }

    /// state = Connected.
    public static func setConnectionState() -> ProtoWriter {
        var message = ProtoWriter()
        message.varint(1, 2)
        return message
    }

    /// pyatv's subscription: everything except now-playing updates, which arrive anyway.
    public static func clientUpdatesConfig() -> ProtoWriter {
        var message = ProtoWriter()
        message.bool(1, true)   // artworkUpdates
        message.bool(2, false)  // nowPlayingUpdates
        message.bool(3, true)   // volumeUpdates
        message.bool(4, true)   // keyboardUpdates
        message.bool(5, true)   // outputDeviceUpdates
        return message
    }

    /// Asks for one queue item's artwork. Height -1 keeps the aspect ratio.
    public static func playbackQueueRequest(location: Int, width: Double, height: Double) -> ProtoWriter {
        var message = ProtoWriter()
        message.int(1, Int64(location))
        message.int(2, 1)       // length
        message.double(4, width)
        message.double(5, height)
        message.bool(13, true)  // returnContentItemAssetsInUserCompletion
        return message
    }
}
