import Foundation

/// MRP playback commands (CommandInfo.Command in pyatv's protobufs), the ones Clickr sends.
public enum PlaybackCommand: Int, Sendable, Hashable, CaseIterable {
    case play = 1
    case pause = 2
    case togglePlayPause = 3
    case nextTrack = 5
    case previousTrack = 6
    case skipForward = 18
    case skipBackward = 19
    case seekToPlaybackPosition = 45
}

/// What the playing app says about one command: whether it's available right now, and for
/// skips, the intervals it prefers.
public struct CommandInfo: Sendable, Equatable {
    public var enabled: Bool
    public var preferredIntervals: [Double]

    public init(enabled: Bool, preferredIntervals: [Double] = []) {
        self.enabled = enabled
        self.preferredIntervals = preferredIntervals
    }

    /// Reads a CommandInfo protobuf (command 1, enabled 2, preferredIntervals 4). A missing
    /// `enabled` means false, as in pyatv. Commands Clickr doesn't use are skipped.
    static func parse(_ message: ProtoMessage) -> (PlaybackCommand, CommandInfo)? {
        guard let raw = message.uint(1), let command = PlaybackCommand(rawValue: Int(raw)) else { return nil }
        return (command, CommandInfo(enabled: message.bool(2) ?? false, preferredIntervals: message.doubles(4)))
    }
}

/// What the now playing card's controls ask for. Each turns into a command the way pyatv's
/// remote control does it, given what's playing.
public enum PlaybackAction: Sendable, Equatable {
    case playPause
    case skipForward
    case skipBackward
    case nextTrack
    case previousTrack
    case seek(to: Double)

    public struct Request: Sendable, Equatable {
        public let command: PlaybackCommand
        public var skipInterval: Float?
        public var position: Double?
    }

    /// pyatv's skip interval when the app doesn't suggest one.
    public static let defaultSkipInterval: Double = 15

    /// The command to send, or nil when the app doesn't support this action right now (the
    /// card hides or disables the control).
    public func request(for nowPlaying: NowPlaying) -> Request? {
        switch self {
        case .playPause:
            // TogglePlayPause when the app offers it, otherwise Play or Pause by state.
            if nowPlaying.supports(.togglePlayPause) { return Request(command: .togglePlayPause) }
            switch nowPlaying.state {
            case .playing: return Request(command: .pause)
            case .paused: return Request(command: .play)
            default: return nil
            }
        case .skipForward, .skipBackward:
            let command: PlaybackCommand = self == .skipForward ? .skipForward : .skipBackward
            guard nowPlaying.supports(command) else { return nil }
            return Request(command: command, skipInterval: Float(Self.skipInterval(command, in: nowPlaying)))
        case .nextTrack:
            return nowPlaying.supports(.nextTrack) ? Request(command: .nextTrack) : nil
        case .previousTrack:
            return nowPlaying.supports(.previousTrack) ? Request(command: .previousTrack) : nil
        case .seek(let position):
            guard nowPlaying.supports(.seekToPlaybackPosition) else { return nil }
            let upper = nowPlaying.duration ?? .greatestFiniteMagnitude
            return Request(command: .seekToPlaybackPosition, position: min(max(position, 0), upper))
        }
    }

    /// The app's first preferred interval, as pyatv picks it, or 15 seconds.
    public static func skipInterval(_ command: PlaybackCommand, in nowPlaying: NowPlaying) -> Double {
        nowPlaying.commands[command]?.preferredIntervals.first ?? defaultSkipInterval
    }
}

extension PlaybackAction.Request {
    init(command: PlaybackCommand) {
        self.init(command: command, skipInterval: nil, position: nil)
    }
}
