import AppKit
import SwiftUI

// MARK: - Now Playing

/// Rich playback view: album cover thumbnail on the left,
/// title + artist + scrubber in the middle, prev/play-pause/
/// next on the right. Position refreshes on its own 1s timer
/// while visible so the scrubber moves smoothly even without
/// a fresh publish.
struct NowPlayingExpandedView: View {
    let activity: LiveActivityCoordinator.Resolved

    @State private var livePosition: Double = 0
    @State private var positionTimer: Timer?

    private var media: LiveActivityCoordinator.MediaInfo? {
        activity.media
    }

    var body: some View {
        HStack(spacing: 12) {
            artwork
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6,
                                            style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(media?.title ?? "—")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(media?.artist ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.haloSecondary)
                    .lineLimit(1)
                scrubber
            }
            // Controls stack: play/pause row, then the
            // "position / duration" read-out underneath so
            // the user knows where the scrubber sits without
            // having to glance at the compact pill.
            VStack(spacing: 4) {
                controls
                timeReadout
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { startTicking() }
        .onDisappear { positionTimer?.invalidate() }
        .onChange(of: media?.title) { _, _ in
            livePosition = media?.positionSeconds ?? 0
        }
    }

    /// `00:42 / 03:14` — current position / total duration
    /// under the play / pause row. Uses
    /// `NotchView.dimmedUnitsText` so leading zeros and the
    /// `:` / `/` separators tone down to 50%, matching the
    /// compact pill. Hour-long content (YouTube videos,
    /// podcasts, audiobooks) shifts to H:MM:SS so it never
    /// reads `83:45` — same rule the compact pill uses.
    private var timeReadout: some View {
        let duration = media?.durationSeconds ?? 0
        let useHours = duration >= 3600
        let pos = Self.formatTime(livePosition,
                                  hours: useHours)
        let dur = Self.formatTime(duration,
                                  hours: useHours)
        return NotchView
            .dimmedUnitsText(
                "\(pos) / \(dur)",
                baseColor: NotchView.pillTextColor(for: activity))
            .font(.system(size: 10,
                          weight: .medium,
                          design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            // Same slot-machine roll as the compact pill —
            // `dimmedUnitsText` now returns a single
            // AttributedString-backed Text, so the numeric
            // transition fires across the whole readout
            // instead of crossfading per-character runs.
            .contentTransition(.numericText())
    }

    private static func formatTime(
        _ seconds: Double, hours: Bool
    ) -> String {
        let total = max(0, Int(seconds.rounded()))
        if hours {
            let h = total / 3600
            let m = (total % 3600) / 60
            let s = total % 60
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    @ViewBuilder
    private var artwork: some View {
        if let img = media?.artwork {
            Image(nsImage: img)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.haloSurfaceFaint)
                Image(systemName: "music.note")
                    .font(.system(size: 18))
                    .foregroundStyle(.haloTertiary)
            }
        }
    }

    private var scrubber: some View {
        let duration = media?.durationSeconds ?? 0
        let progress: Double = {
            guard duration > 0 else { return 0 }
            return min(1, max(0, livePosition / duration))
        }()
        let tint = NotchView.pillTextColor(for: activity)
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.haloSurfaceSoft)
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, proxy.size.width
                                      * CGFloat(progress)))
            }
        }
        .frame(height: 3)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            ControlButton(symbol: "backward.fill") {
                postControl(.previous)
            }
            ControlButton(
                symbol: (media?.isPlaying ?? false)
                    ? "pause.fill" : "play.fill",
                large: true
            ) {
                postControl(.playPause)
            }
            ControlButton(symbol: "forward.fill") {
                postControl(.next)
            }
        }
    }

    // MARK: - Behaviour

    private enum Control { case playPause, next, previous }

    private func postControl(_ c: Control) {
        guard let source = media?.source else { return }
        switch (source, c) {
        case ("Spotify", .playPause): SpotifyScripter.playPause()
        case ("Spotify", .next):      SpotifyScripter.next()
        case ("Spotify", .previous):  SpotifyScripter.previous()
        case ("Music",   .playPause): MusicScripter.playPause()
        case ("Music",   .next):      MusicScripter.next()
        case ("Music",   .previous):  MusicScripter.previous()
        default:
            // MediaRemote control commands need yet another
            // private symbol set — wire on demand.
            break
        }
    }

    /// 1s tick that advances the scrubber locally so it looks
    /// alive between publishes. Re-sync with the publisher's
    /// reading every time the parent activity refreshes.
    private func startTicking() {
        livePosition = media?.positionSeconds ?? 0
        positionTimer = Timer.scheduledTimer(
            withTimeInterval: 1, repeats: true
        ) { _ in
            Task { @MainActor in
                guard media?.isPlaying ?? false else { return }
                livePosition += 1
            }
        }
    }
}

private struct ControlButton: View {
    let symbol: String
    var large: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: large ? 16 : 12,
                              weight: .semibold))
                .frame(width: large ? 28 : 22,
                       height: large ? 28 : 22)
                .foregroundStyle(.white.opacity(large ? 1 : 0.85))
                .background(
                    Circle().fill(
                        large ? Color.haloSurfaceSoft
                              : Color.haloSurfaceFaint))
        }
        .buttonStyle(.plain)
    }
}

