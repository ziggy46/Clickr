import Foundation

/// Companion frame type, the first byte of every frame. A struct rather than an enum so
/// frames with types we don't know about still pass through.
public struct FrameType: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    // Values from pyatv's FrameType.
    public static let unknown = FrameType(rawValue: 0)
    public static let noOp = FrameType(rawValue: 1)
    public static let psStart = FrameType(rawValue: 3)
    public static let psNext = FrameType(rawValue: 4)
    public static let pvStart = FrameType(rawValue: 5)
    public static let pvNext = FrameType(rawValue: 6)
    public static let uOPACK = FrameType(rawValue: 7)
    public static let eOPACK = FrameType(rawValue: 8)
    public static let pOPACK = FrameType(rawValue: 9)
    public static let paRequest = FrameType(rawValue: 10)
    public static let paResponse = FrameType(rawValue: 11)
    public static let sessionStartRequest = FrameType(rawValue: 16)
    public static let sessionStartResponse = FrameType(rawValue: 17)
    public static let sessionData = FrameType(rawValue: 18)
    public static let familyIdentityRequest = FrameType(rawValue: 32)
    public static let familyIdentityResponse = FrameType(rawValue: 33)
    public static let familyIdentityUpdate = FrameType(rawValue: 34)

    public var description: String {
        switch self {
        case .noOp: "NoOp"
        case .psStart: "PS_Start"
        case .psNext: "PS_Next"
        case .pvStart: "PV_Start"
        case .pvNext: "PV_Next"
        case .uOPACK: "U_OPACK"
        case .eOPACK: "E_OPACK"
        case .pOPACK: "P_OPACK"
        default: "FrameType(\(rawValue))"
        }
    }
}

public struct Frame: Hashable, Sendable {
    public var type: FrameType
    public var payload: Data

    public init(type: FrameType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }
}

/// The 4-byte frame header: type, then a 3-byte big-endian payload length.
/// Once encryption is on, the length includes the 16-byte auth tag and the header is the AAD.
public struct FrameHeader: Hashable, Sendable {
    public static let length = 4
    public static let maxPayloadLength = 0xFF_FFFF

    public var type: FrameType
    public var payloadLength: Int

    public init(type: FrameType, payloadLength: Int) {
        precondition((0...Self.maxPayloadLength).contains(payloadLength), "payload too large for a frame")
        self.type = type
        self.payloadLength = payloadLength
    }

    public init<Bytes: Collection<UInt8>>(bytes: Bytes) {
        precondition(bytes.count >= Self.length)
        var it = bytes.makeIterator()
        let type = it.next()!
        let length = (Int(it.next()!) << 16) | (Int(it.next()!) << 8) | Int(it.next()!)
        self.init(type: FrameType(rawValue: type), payloadLength: length)
    }

    public var bytes: Data {
        Data([
            type.rawValue,
            UInt8(truncatingIfNeeded: payloadLength >> 16),
            UInt8(truncatingIfNeeded: payloadLength >> 8),
            UInt8(truncatingIfNeeded: payloadLength),
        ])
    }
}
