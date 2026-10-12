import Foundation
import TestSupport
import Testing
@testable import MRP

private let unique = "5E1F2B6C-0A9D-4C3E-8F71-2D4B6A8C0E1F"

@Suite struct PlaybackCommandTests {
    let vectors = MRPVectors.shared

    private func encoded(_ inner: ProtoWriter, identifier: String) -> String {
        MRPMessage.encode(.sendCommand, identifier: identifier, uniqueIdentifier: unique, inner: inner).hex
    }

    @Test func commandsMatchPyatv() {
        #expect(encoded(MRPRequests.sendCommand(.togglePlayPause), identifier: "55555555-5555-5555-5555-555555555555")
                == vectors.commands["toggle_play_pause"])
        #expect(encoded(MRPRequests.sendCommand(.skipForward, skipInterval: 15), identifier: "66666666-6666-6666-6666-666666666666")
                == vectors.commands["skip_forward_15"])
        #expect(encoded(MRPRequests.sendCommand(.skipBackward, skipInterval: 10), identifier: "77777777-7777-7777-7777-777777777777")
                == vectors.commands["skip_backward_10"])
        #expect(encoded(MRPRequests.sendCommand(.nextTrack), identifier: "88888888-8888-8888-8888-888888888888")
                == vectors.commands["next_track"])
        #expect(encoded(MRPRequests.sendCommand(.seekToPlaybackPosition, playbackPosition: 123.5), identifier: "99999999-9999-9999-9999-999999999999")
                == vectors.commands["seek_to_123_5"])
    }

    @Test func readsTheCommandResult() throws {
        let result = try MRPMessage(decoding: Data(hex: vectors.command_result))
        #expect(result.kind == .sendCommandResult)
        #expect(result.identifier == "55555555-5555-5555-5555-555555555555")
        #expect(result.inner?.uint(1) == 0)  // sendError: none
    }

    @Test func trackerReadsSupportedCommands() throws {
        var tracker = NowPlayingTracker()
        // pyatv's vector carries no playback state, so add one for the player to count.
        tracker.handle(try MRPMessage(decoding: Data(hex: vectors.set_state_commands)))
        var state = ProtoWriter()
        state.varint(6, 1)
        var path = ProtoWriter()
        var client = ProtoWriter()
        client.string(2, "com.example.video")
        path.message(2, client)
        var player = ProtoWriter()
        player.string(1, "MediaRemote-DefaultPlayer")
        path.message(3, player)
        state.message(9, path)
        tracker.handle(try MRPMessage(decoding: MRPMessage.encode(.setState, inner: state)))
        var nowPlaying = ProtoWriter()
        nowPlaying.message(1, client)
        tracker.handle(try MRPMessage(decoding: MRPMessage.encode(.setNowPlayingClient, inner: nowPlaying)))

        let current = try #require(tracker.current)
        #expect(current.supports(.togglePlayPause))
        #expect(current.supports(.skipForward))
        #expect(current.commands[.skipForward]?.preferredIntervals == [15, 30])
        #expect(!current.supports(.skipBackward))
        #expect(current.supports(.seekToPlaybackPosition))
        #expect(!current.supports(.nextTrack))
        // A SetState without a command list leaves the old one alone.
        #expect(current.commands.count == 4)

        // The client's defaults fill in what the player doesn't list, but don't override it.
        tracker.handle(try MRPMessage(decoding: Data(hex: vectors.default_commands)))
        let withDefaults = try #require(tracker.current)
        #expect(withDefaults.supports(.nextTrack))
        #expect(!withDefaults.supports(.skipBackward))
    }

    @Test func missingEnabledMeansOff() throws {
        var info = ProtoWriter()
        info.varint(1, 18)
        let parsed = try #require(CommandInfo.parse(try ProtoMessage(decoding: info.data)))
        #expect(parsed.0 == .skipForward)
        #expect(!parsed.1.enabled)
    }

    @Test func readsPackedAndUnpackedIntervals() throws {
        var unpacked = ProtoWriter()
        unpacked.double(4, 10)
        unpacked.double(4, 20)
        #expect(try ProtoMessage(decoding: unpacked.data).doubles(4) == [10, 20])

        var packedBytes = Data()
        for value in [15.0, 45.0] {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { packedBytes.append(contentsOf: $0) }
        }
        var packed = ProtoWriter()
        packed.bytes(4, packedBytes)
        #expect(try ProtoMessage(decoding: packed.data).doubles(4) == [15, 45])
    }
}

@Suite struct PlaybackActionTests {
    private func playing(_ state: NowPlaying.State = .playing, _ commands: [PlaybackCommand: CommandInfo] = [:]) -> NowPlaying {
        NowPlaying(state: state, duration: 600, commands: commands)
    }

    @Test func playPauseUsesToggleWhenOffered() {
        let toggle = playing(.paused, [.togglePlayPause: CommandInfo(enabled: true)])
        #expect(PlaybackAction.playPause.request(for: toggle)?.command == .togglePlayPause)
        // Otherwise it depends on the state, as in pyatv.
        #expect(PlaybackAction.playPause.request(for: playing(.playing))?.command == .pause)
        #expect(PlaybackAction.playPause.request(for: playing(.paused))?.command == .play)
        #expect(PlaybackAction.playPause.request(for: playing(.loading)) == nil)
        // A disabled toggle doesn't count.
        let disabled = playing(.playing, [.togglePlayPause: CommandInfo(enabled: false)])
        #expect(PlaybackAction.playPause.request(for: disabled)?.command == .pause)
    }

    @Test func skipsUseThePreferredInterval() {
        let video = playing(.playing, [
            .skipForward: CommandInfo(enabled: true, preferredIntervals: [30, 15]),
            .skipBackward: CommandInfo(enabled: true),
        ])
        #expect(PlaybackAction.skipForward.request(for: video) == .init(command: .skipForward, skipInterval: 30, position: nil))
        #expect(PlaybackAction.skipBackward.request(for: video) == .init(command: .skipBackward, skipInterval: 15, position: nil))
        #expect(PlaybackAction.skipForward.request(for: playing()) == nil)
    }

    @Test func seekNeedsSupportAndStaysInRange() {
        let seekable = playing(.playing, [.seekToPlaybackPosition: CommandInfo(enabled: true)])
        #expect(PlaybackAction.seek(to: 125).request(for: seekable)?.position == 125)
        #expect(PlaybackAction.seek(to: -5).request(for: seekable)?.position == 0)
        #expect(PlaybackAction.seek(to: 900).request(for: seekable)?.position == 600)
        #expect(PlaybackAction.seek(to: 10).request(for: playing()) == nil)
    }

    @Test func tracksNeedSupport() {
        let music = playing(.playing, [.nextTrack: CommandInfo(enabled: true), .previousTrack: CommandInfo(enabled: false)])
        #expect(PlaybackAction.nextTrack.request(for: music)?.command == .nextTrack)
        #expect(PlaybackAction.previousTrack.request(for: music) == nil)
    }
}
