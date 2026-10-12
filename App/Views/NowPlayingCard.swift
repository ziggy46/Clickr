import MRP
import SwiftUI

/// What's playing on the TV (Section 5.2 item 2, and 5.3 for the fallback). Only shown
/// when the TV reports something. With playback controls on, it adds play/pause and skip
/// (or previous/next track) buttons, and the progress bar can be dragged to seek, for
/// whatever the playing app supports.
struct NowPlayingCard: View {
    let nowPlaying: NowPlaying
    let artwork: NSImage?
    /// Called for the controls; nil hides them.
    var perform: ((PlaybackAction) -> Void)?
    @Environment(\.remoteTheme) private var theme

    /// Where the user is dragging the progress bar to, in seconds.
    @State private var scrubPosition: Double?
    /// After a seek, show the target until the TV reports the new position (or a moment
    /// passes), so the bar doesn't jump back and then forward.
    @State private var seekTarget: (position: Double, until: Date)?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                artworkView
                VStack(alignment: .leading, spacing: 2) {
                    Text(nowPlaying.title ?? nowPlaying.appName ?? "Playing")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Now playing: \(nowPlaying.title ?? "unknown")\(subtitle.map { ", \($0)" } ?? "")")

            // Redraws once a second while playing so the bar and times move on their own.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let position = displayedPosition(at: context.date)
                VStack(spacing: 6) {
                    if let duration = nowPlaying.duration, duration > 0 {
                        progressBar(position: position, duration: duration)
                    }
                    if let perform {
                        controls(position: position, perform: perform)
                    }
                }
            }
        }
        .padding(10)
        .surface(theme, in: RoundedRectangle(cornerRadius: theme.isGlass ? 18 : 10, style: .continuous),
                 glassTint: 0.10, fallbackFill: .white.opacity(0.06), edge: theme.isGlass ? 0.14 : nil)
        .onChange(of: nowPlaying.elapsedTimestamp) { seekTarget = nil }
        .onChange(of: nowPlaying.itemID) {
            seekTarget = nil
            scrubPosition = nil
        }
    }

    private func displayedPosition(at date: Date) -> Double {
        if let scrubPosition { return scrubPosition }
        if let seekTarget, date < seekTarget.until { return seekTarget.position }
        return nowPlaying.position(at: date) ?? 0
    }

    // MARK: - Controls

    private func controls(position: Double, perform: @escaping (PlaybackAction) -> Void) -> some View {
        HStack(spacing: 0) {
            timeLabel(nowPlaying.duration == nil ? nil : Self.format(position))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                sideButton(skip: .skipBackward, track: .previousTrack, perform: perform)
                controlButton(
                    symbol: nowPlaying.state == .playing ? "pause.fill" : "play.fill",
                    label: nowPlaying.state == .playing ? "Pause" : "Play",
                    size: 17,
                    action: PlaybackAction.playPause.request(for: nowPlaying) == nil ? nil : { perform(.playPause) }
                )
                sideButton(skip: .skipForward, track: .nextTrack, perform: perform)
            }
            timeLabel(nowPlaying.duration.map { "-" + Self.format(max($0 - position, 0)) })
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Skip back or forward if the app offers it (videos usually do), otherwise previous or
    /// next track (music). Kept as an empty slot when neither works, so play/pause stays
    /// in the middle.
    @ViewBuilder
    private func sideButton(skip: PlaybackAction, track: PlaybackAction, perform: @escaping (PlaybackAction) -> Void) -> some View {
        let forward = skip == .skipForward
        if skip.request(for: nowPlaying) != nil {
            let command: PlaybackCommand = forward ? .skipForward : .skipBackward
            let seconds = Int(PlaybackAction.skipInterval(command, in: nowPlaying))
            controlButton(
                symbol: Self.skipSymbol(forward: forward, seconds: seconds),
                label: forward ? "Skip forward \(seconds) seconds" : "Skip back \(seconds) seconds",
                size: 15,
                action: { perform(skip) }
            )
        } else if track.request(for: nowPlaying) != nil {
            controlButton(
                symbol: forward ? "forward.fill" : "backward.fill",
                label: forward ? "Next track" : "Previous track",
                size: 14,
                action: { perform(track) }
            )
        } else {
            controlButton(symbol: forward ? "forward.fill" : "backward.fill", label: "", size: 14, action: nil)
                .hidden()
        }
    }

    private func controlButton(symbol: String, label: String, size: CGFloat, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .opacity(action == nil ? 0.35 : 1)
        .accessibilityLabel(label)
    }

    private func timeLabel(_ text: String?) -> some View {
        Text(text ?? "")
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
    }

    /// SF Symbols has numbered skip icons for the common intervals.
    private static func skipSymbol(forward: Bool, seconds: Int) -> String {
        let base = forward ? "goforward" : "gobackward"
        return [5, 10, 15, 30, 45, 60, 75, 90].contains(seconds) ? "\(base).\(seconds)" : base
    }

    /// 1:05, or 1:02:05 past an hour.
    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// "Episode 3 · TV app" style: who or what it's from, then the app.
    private var subtitle: String? {
        let parts = [nowPlaying.artist ?? nowPlaying.seriesName, nowPlaying.appName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var artworkView: some View {
        let size: CGFloat = theme.isGlass ? 38 : 36
        let shape = RoundedRectangle(cornerRadius: theme.isGlass ? 10 : 6, style: .continuous)
        return Group {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    theme.isGlass ? Color.white.opacity(0.2) : Color(hex: 0x4A5A6A)
                    Image(systemName: "play.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.primaryText)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }

    // MARK: - Progress

    private var canSeek: Bool {
        perform != nil && PlaybackAction.seek(to: 0).request(for: nowPlaying) != nil
    }

    private func progressBar(position: Double, duration: Double) -> some View {
        let fraction = min(max(position / duration, 0), 1)
        let height: CGFloat = theme.isGlass ? 4 : 3
        // Thicker while dragging, so it's clear the drag took hold.
        let barHeight = scrubPosition == nil ? height : height + 2
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(theme.isGlass ? 0.2 : 0.16))
                Capsule()
                    .fill(theme.isGlass ? Color.white : Color.accentColor)
                    .frame(width: geometry.size.width * fraction)
            }
            .frame(height: barHeight)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(canSeek ? scrub(width: geometry.size.width, duration: duration) : nil)
        }
        // A taller strip than the bar itself, so it's easy to grab.
        .frame(height: canSeek ? 12 : height)
        .animation(.easeOut(duration: 0.12), value: scrubPosition == nil)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Self.format(position)) of \(Self.format(duration))")
        .accessibilityAdjustableAction { direction in
            guard canSeek, let perform else { return }
            let step = PlaybackAction.defaultSkipInterval
            let target = direction == .increment ? position + step : position - step
            seekTarget = (target, Date().addingTimeInterval(1.5))
            perform(.seek(to: target))
        }
    }

    private func scrub(width: CGFloat, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                scrubPosition = min(max(value.location.x / width, 0), 1) * duration
            }
            .onEnded { _ in
                guard let target = scrubPosition else { return }
                scrubPosition = nil
                seekTarget = (target, Date().addingTimeInterval(1.5))
                perform?(.seek(to: target))
            }
    }
}
