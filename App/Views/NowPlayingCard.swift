import MRP
import SwiftUI

/// What's playing on the TV (Section 5.2 item 2, and 5.3 for the fallback). Only shown
/// when the TV reports something.
struct NowPlayingCard: View {
    let nowPlaying: NowPlaying
    let artwork: NSImage?
    @Environment(\.remoteTheme) private var theme

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
            if let duration = nowPlaying.duration, duration > 0 {
                // Redraws once a second while playing so the bar moves on its own.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    progressBar(fraction: (nowPlaying.position(at: context.date) ?? 0) / duration)
                }
            }
        }
        .padding(10)
        .surface(theme, in: RoundedRectangle(cornerRadius: theme.isGlass ? 18 : 10, style: .continuous),
                 glassTint: 0.10, fallbackFill: .white.opacity(0.06), edge: theme.isGlass ? 0.14 : nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Now playing: \(nowPlaying.title ?? "unknown")\(subtitle.map { ", \($0)" } ?? "")")
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

    private func progressBar(fraction: Double) -> some View {
        let height: CGFloat = theme.isGlass ? 4 : 3
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(theme.isGlass ? 0.2 : 0.16))
                Capsule()
                    .fill(theme.isGlass ? Color.white : Color.accentColor)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
    }
}
