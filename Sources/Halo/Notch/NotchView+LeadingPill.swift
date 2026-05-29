import AppKit
import SwiftUI

/// Builds the left-hand half of the compact pill — the part that
/// owns the icon / album cover / title. Each activity gets its own
/// case here; the trailing read-out (time, percent, etc.) lives in
/// the sibling `NotchView+TrailingPill` file.
extension NotchView {
    @ViewBuilder
    func leadingContent(
        for a: LiveActivityCoordinator.Resolved
    ) -> some View {
        if a.id == "halo.nowplaying",
           let media = a.media,
           (media.source == "YouTube"
            || media.source == "YouTube Music"),
           !media.title.isEmpty {
            // YouTube always uses the red logo on the
            // compact pill, even after the thumbnail loads.
            // An 18pt thumbnail is too small to read — the
            // logo + title pair is the clearer cue. The
            // thumbnail surfaces in the expanded card where
            // it has room to render at full size.
            HStack(spacing: 6) {
                Self.youTubeLogo
                MarqueeText(
                    text: media.title,
                    font: .system(size: 13,
                                  weight: .medium),
                    fontSize: 13,
                    color: .white,
                    maxWidth: 120)
            }
            .id("lead-yt-\(media.title)")
            .transition(.opacity)
        } else if let artwork = a.media?.artwork {
            // Album cover + song title side by side. The
            // cover stays the same small rounded thumbnail
            // (reads like a Spotify / Music card); the title
            // sits in the publisher's brand colour so the
            // pill reads as "this song from this app" at a
            // glance.
            HStack(spacing: 6) {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(
                        cornerRadius: 3,
                        style: .continuous))
                if let title = a.media?.title,
                   !title.isEmpty {
                    // Cap at 120pt and ping-pong if the title
                    // doesn't fit — long track names ("I Had
                    // Some Help (Feat. Morgan Wallen)") used
                    // to push the pill across the screen.
                    // Title stays white so it reads as the
                    // primary data; the source-app tint
                    // belongs on the icons / time read-out.
                    MarqueeText(
                        text: title,
                        font: .system(size: 13,
                                      weight: .medium),
                        fontSize: 13,
                        color: .white,
                        maxWidth: 120)
                }
            }
            .id("lead-art-\(a.media?.title ?? "")")
            .transition(.opacity)
        } else if a.id == "halo.nowplaying",
                  let media = a.media,
                  media.artwork == nil,
                  !media.title.isEmpty,
                  NowPlayingPublisher.titleRendersOnLeading(
                    media),
                  let img = a.compactLeadingImage {
            // Source-icon-without-artwork pattern (YouTube,
            // SoundCloud, Bandcamp, Twitch, Vimeo, Spotify
            // Web): brand source icon on the left next to the
            // track title. YouTube renders a composited red
            // play-rectangle (a single tinted SF Symbol just
            // becomes a solid red square; the white play
            // triangle has to be a separate layer on top of
            // the red rectangle).
            HStack(spacing: 6) {
                if media.source == "YouTube"
                   || media.source == "YouTube Music" {
                    Self.youTubeLogo
                } else {
                    Image(nsImage: tintImage(
                        img,
                        color: Self.pillIconColor(for: a)))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                }
                MarqueeText(
                    text: media.title,
                    font: .system(size: 13,
                                  weight: .medium),
                    fontSize: 13,
                    color: .white,
                    maxWidth: 120)
            }
            .id("lead-srcmedia-\(media.source)-\(media.title)")
            .transition(.opacity)
        } else if a.id == "worktree",
                  let info = a.worktree,
                  let img = a.compactLeadingImage {
            // Worktree splits its label across both wings:
            // Git icon + project name on the LEFT (data the
            // user reads first — which repo am I in?), branch
            // name on the RIGHT (data they act on — what
            // branch?). Same layout pattern as Now Playing's
            // artwork + title.
            let projectName = info.displayName
                ?? ((info.repoPath as NSString)
                        .lastPathComponent)
            HStack(spacing: 6) {
                Image(nsImage: tintImage(
                    img, color: Self.pillIconColor(for: a)))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .opacity(0.9)
                Text(projectName)
                    .font(.system(size: 13,
                                  weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 140,
                           alignment: .leading)
            }
            .id("lead-worktree-\(projectName)")
            .animation(nil, value: a.compactTrailingText)
        } else if a.id == "halo.ext.crypto",
                  let info = a.crypto,
                  !info.tickers.isEmpty {
            // Crypto compact pill: real coin logo + brand-
            // coloured ticker symbol side by side, same
            // layout pattern Worktree (icon + project) and
            // Now Playing (artwork + title) use. Logo isn't
            // template-tinted — keeps BTC's native orange,
            // ETH's diamond, etc.
            let coin = info.tickers[
                min(info.currentIndex,
                    info.tickers.count - 1)]
            HStack(spacing: 5) {
                if let img = a.compactLeadingImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .clipShape(Circle())
                }
                Text(coin.symbol)
                    .font(.system(size: 13,
                                  weight: .bold,
                                  design: .rounded))
                    .foregroundStyle(coin.brandColor)
                    .lineLimit(1)
                    .fixedSize()
            }
            .id("lead-crypto-\(coin.symbol)")
            .animation(nil, value: a.compactTrailingText)
        } else if let img = a.compactLeadingImage {
            // Tinted-near-white scheme — each pill picks up a
            // hint of its publisher's brand colour (Espresso
            // tan, Spotify green, etc.) without losing the
            // readable B&W feel. 90% opacity so the icon reads
            // as supporting content next to the 100% trailing
            // text.
            //
            // `tintImage` builds a fresh NSImage every render,
            // so when the trailing text ticks (Espresso's 1Hz
            // countdown) the parent's spring would otherwise
            // crossfade the icon — that read as the icon
            // "flashing" on every second. Opt out of that
            // animation explicitly; the icon itself doesn't
            // need to animate on text changes.
            Image(nsImage: tintImage(
                img, color: Self.pillIconColor(for: a)))
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .opacity(0.9)
                .id("lead-\(a.id)")
                .animation(nil, value: a.compactTrailingText)
        }
    }
}
