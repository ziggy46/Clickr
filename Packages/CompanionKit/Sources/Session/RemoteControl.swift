/// Where the connection to the selected Apple TV stands.
public enum ConnectionState: Sendable, Hashable {
    case disconnected
    case connecting
    case needsPairing
    case connected
}

/// A remote button, sent as a `_hidC` command.
public enum RemoteButton: Sendable, Hashable, CaseIterable {
    case up, down, left, right
    case menu
    case select
    case home
    case volumeUp, volumeDown
    case playPause

    /// HID code from pyatv's `HidCommand`.
    public var hidCode: Int {
        switch self {
        case .up: 1
        case .down: 2
        case .left: 3
        case .right: 4
        case .menu: 5
        case .select: 6
        case .home: 7
        case .volumeUp: 8
        case .volumeDown: 9
        case .playPause: 14
        }
    }
}
