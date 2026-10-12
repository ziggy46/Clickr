import Foundation

/// What's playing on the TV, as the card shows it.
public struct NowPlaying: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case playing, paused, stopped, loading, seeking
    }

    public var state: State
    public var title: String?
    public var artist: String?
    public var album: String?
    public var seriesName: String?
    public var appName: String?
    public var bundleID: String?
    /// Seconds.
    public var duration: Double?
    /// Seconds into the item when `elapsedTimestamp` was taken.
    public var elapsed: Double?
    public var elapsedTimestamp: Date?
    public var playbackRate: Float?
    public var artworkAvailable: Bool
    /// Identifies the queue item, so artwork can be fetched once per item.
    public var itemID: String?
    /// Where the item sits in the queue (for the artwork request).
    public var location: Int
    /// The playback commands the app reported, for the card's controls.
    public var commands: [PlaybackCommand: CommandInfo]

    public init(
        state: State, title: String? = nil, artist: String? = nil, album: String? = nil, seriesName: String? = nil,
        appName: String? = nil, bundleID: String? = nil, duration: Double? = nil, elapsed: Double? = nil,
        elapsedTimestamp: Date? = nil, playbackRate: Float? = nil, artworkAvailable: Bool = false,
        itemID: String? = nil, location: Int = 0, commands: [PlaybackCommand: CommandInfo] = [:]
    ) {
        self.state = state
        self.title = title
        self.artist = artist
        self.album = album
        self.seriesName = seriesName
        self.appName = appName
        self.bundleID = bundleID
        self.duration = duration
        self.elapsed = elapsed
        self.elapsedTimestamp = elapsedTimestamp
        self.playbackRate = playbackRate
        self.artworkAvailable = artworkAvailable
        self.itemID = itemID
        self.location = location
        self.commands = commands
    }

    /// Whether the app currently accepts `command`.
    public func supports(_ command: PlaybackCommand) -> Bool {
        commands[command]?.enabled == true
    }

    /// The position now, moving on from the last report while playing (as pyatv does).
    public func position(at date: Date = Date()) -> Double? {
        guard let elapsedTimestamp else { return nil }
        let elapsed = elapsed ?? 0
        guard state == .playing, let rate = playbackRate, rate != 0 else { return elapsed }
        return elapsed + date.timeIntervalSince(elapsedTimestamp)
    }
}

/// Keeps track of the TV's now-playing clients and players from pushed MRP messages, the
/// way pyatv's player_state does, and works out what's currently playing.
public struct NowPlayingTracker: Sendable {
    private struct Player: Sendable {
        var playbackState: UInt64?
        var items: [ProtoMessage] = []
        var location = 0
        var supportedCommands: [ProtoMessage] = []
    }

    private struct Client: Sendable {
        var displayName: String?
        var players: [String: Player] = [:]
        var activePlayerID: String?
        /// SetDefaultSupportedCommands: used for commands the player doesn't list itself.
        var defaultCommands: [ProtoMessage] = []
    }

    private static let defaultPlayer = "MediaRemote-DefaultPlayer"

    private var clients: [String: Client] = [:]
    private var activeClientID: String?

    public init() {}

    /// Applies one message. Returns whether it was one the tracker uses.
    @discardableResult
    public mutating func handle(_ message: MRPMessage) -> Bool {
        guard let kind = message.kind, let inner = message.inner else { return false }
        switch kind {
        case .setState:
            let path = inner.message(9)
            update(path) { player in
                if let state = inner.uint(6) { player.playbackState = state }
                // Most SetStates leave this out; only replace the list when it's there.
                if inner.has(2) { player.supportedCommands = inner.message(2)?.messages(1) ?? [] }
                if let queue = inner.message(3) {
                    player.items = queue.messages(2)
                    player.location = Int(queue.int(1) ?? 0)
                }
            }
        case .updateContentItem:
            let updates = inner.messages(1)
            update(inner.message(2)) { player in
                for update in updates {
                    guard let id = update.string(1), let newMetadata = update.message(2) else { continue }
                    for index in player.items.indices where player.items[index].string(1) == id {
                        var metadata = player.items[index].message(2) ?? ProtoMessage()
                        metadata.merge(newMetadata)
                        player.items[index].set(2, message: metadata)
                    }
                }
            }
        case .setDefaultSupportedCommands:
            let id = clientID(for: inner.message(9)?.message(2))
            clients[id]?.defaultCommands = inner.message(2)?.messages(1) ?? []
        case .setNowPlayingClient:
            guard let client = inner.message(1) else { return false }
            activeClientID = clientID(for: client)
        case .setNowPlayingPlayer:
            guard let path = inner.message(1) else { return false }
            let id = clientID(for: path.message(2))
            clients[id]?.activePlayerID = path.message(3)?.string(1) ?? ""
        case .updateClient:
            guard let client = inner.message(1) else { return false }
            let id = clientID(for: client)
            if let name = client.string(7) { clients[id]?.displayName = name }
        case .removeClient:
            guard let client = inner.message(1) else { return false }
            let id = client.string(2) ?? ""
            clients[id] = nil
            if activeClientID == id { activeClientID = nil }
        case .removePlayer:
            guard let path = inner.message(1) else { return false }
            let id = path.message(2)?.string(2) ?? ""
            let playerID = path.message(3)?.string(1) ?? ""
            clients[id]?.players[playerID] = nil
            if clients[id]?.activePlayerID == playerID { clients[id]?.activePlayerID = nil }
        default:
            return false
        }
        return true
    }

    /// What's playing, or nil when nothing is (the card hides).
    public var current: NowPlaying? {
        guard let activeClientID, let client = clients[activeClientID] else { return nil }
        let playerID = client.activePlayerID ?? (client.players[Self.defaultPlayer] != nil ? Self.defaultPlayer : nil)
        guard let playerID, let player = client.players[playerID], let rawState = player.playbackState else { return nil }

        let item = player.items.indices.contains(player.location) ? player.items[player.location] : nil
        let metadata = item?.message(2)
        let state: NowPlaying.State
        switch rawState {
        case 1: state = .playing
        case 2:
            guard metadata != nil else { return nil }
            state = .paused
        case 3: state = .stopped
        case 4: state = .loading
        case 5: state = .seeking
        default: state = .paused
        }

        return NowPlaying(
            state: state,
            title: metadata?.string(1),
            artist: metadata?.string(7),
            album: metadata?.string(6),
            seriesName: metadata?.string(63),
            appName: client.displayName,
            bundleID: activeClientID.isEmpty ? nil : activeClientID,
            duration: metadata?.double(14).flatMap { $0.isNaN ? nil : $0 },
            elapsed: metadata?.double(35),
            elapsedTimestamp: metadata?.double(74).flatMap { $0 == 0 ? nil : Date(timeIntervalSinceReferenceDate: $0) },
            playbackRate: metadata?.float(39),
            artworkAvailable: metadata?.bool(19) == true || metadata?.has(70) == true,
            itemID: item?.string(1),
            location: player.location,
            commands: Self.commands(player: player.supportedCommands, client: client.defaultCommands)
        )
    }

    // MARK: - Helpers

    /// pyatv takes the first match in the player's list, then the client's defaults.
    /// Applying both in reverse leaves exactly those entries in the dictionary.
    private static func commands(player: [ProtoMessage], client: [ProtoMessage]) -> [PlaybackCommand: CommandInfo] {
        var result: [PlaybackCommand: CommandInfo] = [:]
        for message in (player + client).reversed() {
            if let (command, info) = CommandInfo.parse(message) { result[command] = info }
        }
        return result
    }

    /// Clients are keyed by bundle identifier only (the origin is ignored, as in pyatv).
    /// The first time a client is seen, its display name is recorded.
    private mutating func clientID(for client: ProtoMessage?) -> String {
        let id = client?.string(2) ?? ""
        if clients[id] == nil {
            clients[id] = Client(displayName: client?.string(7))
        }
        return id
    }

    private mutating func update(_ path: ProtoMessage?, _ change: (inout Player) -> Void) {
        let id = clientID(for: path?.message(2))
        let playerID = path?.message(3)?.string(1) ?? ""
        var player = clients[id]?.players[playerID] ?? Player()
        change(&player)
        clients[id]?.players[playerID] = player
    }
}
