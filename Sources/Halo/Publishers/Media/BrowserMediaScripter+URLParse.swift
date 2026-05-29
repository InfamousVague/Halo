import AppKit
import Foundation

/// URL → `MediaInfo` routing. Each known media host has a
/// distinct rule for pulling a clean track title out of the
/// (often noisy) browser tab title — this is where YouTube's
/// "(Official Video)" suffix, SoundCloud's "by Artist" pattern,
/// and Spotify Web's tab title get normalised into a uniform
/// `title + artist` payload.
extension BrowserMediaScripter {
    /// Recognise a media URL and pull a clean track title out
    /// of the (often noisy) browser tab title. Returns nil for
    /// non-media tabs so the caller falls through to the next
    /// browser / source.
    static func parse(
        browser: String, url: String, title: String,
        parts: [String]
    ) -> LiveActivityCoordinator.MediaInfo? {
        let host = host(of: url).lowercased()
        let path = path(of: url).lowercased()
        let (kind, source): (MediaKind, String)
        switch (host, path) {
        case (let h, let p) where
            h.contains("music.youtube.com"):
            (kind, source) = (.youtube, "YouTube Music")
        case (let h, _) where
            h.contains("youtube.com")
            || h == "youtu.be":
            // YouTube proper — only count actual watch /
            // shorts pages, not the homepage / channel /
            // search results.
            guard path.hasPrefix("/watch")
                || path.hasPrefix("/shorts/")
                || path.hasPrefix("/embed/")
                || host == "youtu.be"
            else { return nil }
            (kind, source) = (.youtube, "YouTube")
        case (let h, _) where h.contains("soundcloud.com"):
            (kind, source) = (.generic, "SoundCloud")
        case (let h, _) where h.contains("bandcamp.com"):
            (kind, source) = (.generic, "Bandcamp")
        case (let h, _) where h.contains("twitch.tv"):
            // Only stream pages, not browse / categories.
            guard !path.isEmpty,
                  path != "/",
                  !path.hasPrefix("/directory")
            else { return nil }
            (kind, source) = (.generic, "Twitch")
        case (let h, _) where h.contains("vimeo.com"):
            (kind, source) = (.generic, "Vimeo")
        case (let h, _) where
            h.contains("open.spotify.com"):
            (kind, source) = (.generic, "Spotify Web")
        default:
            return nil
        }

        // Safari surfaces video state via `do JavaScript`.
        // `js` JSON shape: `{p: bool paused, c: position,
        // d: duration}`.
        var isPlaying = true
        var position: Double?
        var duration: Double?
        if parts.count >= 3, !parts[2].isEmpty {
            if let data = parts[2].data(using: .utf8),
               let obj = try? JSONSerialization
                    .jsonObject(with: data)
                    as? [String: Any] {
                if let paused = obj["p"] as? Bool {
                    isPlaying = !paused
                }
                if let c = obj["c"] as? Double, c > 0 {
                    position = c
                }
                if let d = obj["d"] as? Double, d > 0 {
                    duration = d
                }
            }
        }

        // YouTube duration fallback — if Safari JS didn't
        // surface a duration (the "Allow JavaScript from
        // Apple Events" toggle is OFF, or we're on a Chromium
        // browser where we don't even ask), scrape it from
        // the page HTML. Cache by video ID so we only hit
        // the network once per video.
        let videoID = (kind == .youtube)
            ? extractYouTubeVideoID(from: url) : nil
        if duration == nil, let videoID {
            duration = cachedOrFetchYouTubeDuration(
                videoID: videoID)
        }

        // YouTube position estimate — when JS didn't surface
        // a currentTime, we tick a wall-clock from the moment
        // we first saw this video ID. It's a rough estimate
        // (won't reflect a pause or scrub since we can't
        // observe either), but it gives the user a moving
        // readout on the right side of the pill instead of
        // just the static total length.
        //
        // Accuracy improves dramatically once 'Allow
        // JavaScript from Apple Events' is enabled in
        // Safari → Develop → Developer Settings (or the
        // Chromium equivalent) — at that point the JS path
        // returns the real `<video>.currentTime` and this
        // estimate is bypassed.
        if position == nil, let videoID,
           let dur = duration, dur > 0 {
            position = estimatedYouTubePosition(
                videoID: videoID, duration: dur)
        }

        // YouTube thumbnail — fetch the video's still image
        // from `img.youtube.com` (no API key required). The
        // compact pill keeps the red YouTube logo, but the
        // expanded card uses this as the cover art.
        var artwork: NSImage?
        if let videoID {
            artwork = cachedOrFetchYouTubeThumbnail(
                videoID: videoID)
        }

        let cleanTitle = strip(title: title, kind: kind)
        guard !cleanTitle.isEmpty else { return nil }
        return .init(
            title: cleanTitle,
            artist: nil,
            album: nil,
            artwork: artwork,
            positionSeconds: position,
            durationSeconds: duration,
            isPlaying: isPlaying,
            source: source)
    }

    // MARK: - YouTube duration scrape

    /// Tick-cached duration per video ID. Populated by an
    /// async URLSession fetch that grep's
    /// `"lengthSeconds":"NNN"` out of the YouTube page HTML;
    /// the parse path checks here synchronously, so the first
    /// publish for a fresh video returns nil and the NEXT
    /// publish tick (~1.5s later) sees the cached value.
    nonisolated(unsafe)
        static var youtubeDurationCache:
            [String: Double] = [:]
    nonisolated(unsafe)
        static var youtubeFetchPending: Set<String> = []

    /// Wall-clock seen-at per video ID. Used by the position
    /// estimate fallback — we treat the moment we first saw
    /// a video as t=0 and assume continuous forward playback.
    /// Bounded to 50 entries so a long browsing session
    /// doesn't accumulate state forever.
    nonisolated(unsafe)
        static var youtubeFirstSeenAt:
            [String: Date] = [:]

    /// Per-video thumbnail cache. NSImage is reference-typed
    /// so re-reading the same cached entry on subsequent
    /// publishes is free — same reference identity preserved,
    /// no rerender churn.
    nonisolated(unsafe)
        static var youtubeThumbnailCache:
            [String: NSImage] = [:]
    nonisolated(unsafe)
        static var youtubeThumbnailPending:
            Set<String> = []

}
