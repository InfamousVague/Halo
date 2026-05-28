import AppKit

/// AppleScript bridges to Spotify + Music for reading + driving
/// playback. Required because macOS 14.4+ gated MediaRemote
/// behind a private entitlement; without it the framework
/// returns empty payloads, so Spotify in particular goes dark
/// in any third-party Now Playing display.
///
/// Each scripter does:
///   • `readNowPlaying()` → MediaInfo when the app is running
///     AND has a track loaded; nil otherwise (caller falls
///     through to the next source).
///   • `playPause()` / `next()` / `previous()` — control
///     commands the expanded card's buttons fire.
///
/// AppleScript requires AppleEvents permission. macOS prompts
/// the user the first time; we silently no-op if denied.

@MainActor
enum SpotifyScripter {
    static func readNowPlaying() -> LiveActivityCoordinator.MediaInfo? {
        let running = isRunning("com.spotify.client")
        NowPlayingDebugLog.append(
            "\(Date()) Spotify isRunning=\(running)\n")
        guard running else { return nil }
        // Single-line script body so we don't depend on
        // AppleScript line-continuations (the `¬` character
        // gets eaten by Swift's literal handling in some
        // encodings, surfacing as a parse error at the next
        // token).
        let script = #"""
        tell application id "com.spotify.client"
            if it is running then
                try
                    set t to current track
                    return (name of t as text) & "|||" & (artist of t as text) & "|||" & (album of t as text) & "|||" & (artwork url of t as text) & "|||" & (player state as text) & "|||" & (player position as text) & "|||" & (duration of t as text)
                on error
                    return ""
                end try
            end if
        end tell
        return ""
        """#
        guard let raw = runAppleScript(script),
              !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "|||")
        guard parts.count >= 7 else { return nil }
        let title = parts[0]
        let artist = parts[1].isEmpty ? nil : parts[1]
        let album = parts[2].isEmpty ? nil : parts[2]
        let artworkURL = parts[3]
        let state = parts[4]   // "playing" / "paused" / "stopped"
        let position = Double(parts[5])
        // Spotify reports duration in ms; convert to seconds.
        let duration = Double(parts[6]).map { $0 / 1000 }
        guard !title.isEmpty else { return nil }
        let isPlaying = (state == "playing")
        let artwork = loadArtwork(url: artworkURL)
        return .init(
            title: title,
            artist: artist,
            album: album,
            artwork: artwork,
            positionSeconds: position,
            durationSeconds: duration,
            isPlaying: isPlaying,
            source: "Spotify")
    }

    static func playPause() {
        _ = runAppleScript(
            #"tell application id "com.spotify.client" to playpause"#)
    }
    static func next() {
        _ = runAppleScript(
            #"tell application id "com.spotify.client" to next track"#)
    }
    static func previous() {
        _ = runAppleScript(
            #"tell application id "com.spotify.client" to previous track"#)
    }

    /// Cache one artwork per URL so we don't refetch a JPEG
    /// every poll tick while a track stays the same.
    nonisolated(unsafe) private static var artworkCache:
        (url: String, image: NSImage)?

    private static func loadArtwork(url: String) -> NSImage? {
        guard !url.isEmpty else { return nil }
        if let cached = artworkCache, cached.url == url {
            return cached.image
        }
        guard let u = URL(string: url),
              let data = try? Data(contentsOf: u),
              let img = NSImage(data: data) else { return nil }
        artworkCache = (url, img)
        return img
    }
}

@MainActor
enum MusicScripter {
    static func readNowPlaying() -> LiveActivityCoordinator.MediaInfo? {
        guard isRunning("com.apple.Music") else { return nil }
        let script = #"""
        tell application id "com.apple.Music"
            if it is running then
                try
                    set t to current track
                    return (name of t as text) & "|||" & (artist of t as text) & "|||" & (album of t as text) & "|||" & (player state as text) & "|||" & (player position as text) & "|||" & (duration of t as text)
                on error
                    return ""
                end try
            end if
        end tell
        return ""
        """#
        guard let raw = runAppleScript(script),
              !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "|||")
        guard parts.count >= 6 else { return nil }
        let title = parts[0]
        let artist = parts[1].isEmpty ? nil : parts[1]
        let album = parts[2].isEmpty ? nil : parts[2]
        let state = parts[3]
        let position = Double(parts[4])
        // Music.app reports duration in seconds (unlike
        // Spotify's milliseconds).
        let duration = Double(parts[5])
        guard !title.isEmpty else { return nil }
        let isPlaying = (state == "playing")
        return .init(
            title: title,
            artist: artist,
            album: album,
            artwork: nil,  // Music artwork requires a separate
                           // call returning raw picture data;
                           // skipped for now.
            positionSeconds: position,
            durationSeconds: duration,
            isPlaying: isPlaying,
            source: "Music")
    }

    static func playPause() {
        _ = runAppleScript(
            #"tell application id "com.apple.Music" to playpause"#)
    }
    static func next() {
        _ = runAppleScript(
            #"tell application id "com.apple.Music" to next track"#)
    }
    static func previous() {
        _ = runAppleScript(
            #"tell application id "com.apple.Music" to previous track"#)
    }
}

// MARK: - Browser media

/// Detects media playing inside a browser tab — YouTube,
/// YouTube Music, SoundCloud, Bandcamp, Twitch, Vimeo,
/// Spotify Web — via AppleScript queries of the running
/// browsers' active tabs. MediaRemote ought to surface this
/// (browsers register via Media Session API), but macOS 14.4+
/// gates the framework behind a private entitlement; this
/// fallback fills the gap.
///
/// Strategy per browser:
///   1. Query the frontmost window's active tab's URL + title.
///   2. Match the URL against a list of known media patterns.
///   3. Parse a (title, artist) tuple out of the tab title.
///   4. For Safari, also \`do JavaScript\` to read the
///      \`<video>\` element's paused / currentTime / duration
///      so we know if the user actually has playback running.
///      Chrome-family browsers require "Allow JavaScript from
///      Apple Events" in the Develop menu; we don't push the
///      user to enable it, so for those we infer "playing" from
///      the tab being present (good enough for the pill).
@MainActor
enum BrowserMediaScripter {
    static func readNowPlaying()
        -> LiveActivityCoordinator.MediaInfo?
    {
        // Try browsers in rough usage-popularity order. The
        // first one that turns up a media tab wins — if the
        // user has YouTube open in two browsers we surface
        // whichever they're more likely to be using.
        for browser in browsers {
            guard isRunning(browser.bundleID) else { continue }
            guard let raw = runAppleScript(browser.script),
                  !raw.isEmpty else { continue }
            let parts = raw.components(separatedBy: "|||")
            guard parts.count >= 2 else { continue }
            let url = parts[0]
            let title = parts[1]
            guard let info = parse(
                browser: browser.name,
                url: url, title: title, parts: parts
            ) else { continue }
            return info
        }
        return nil
    }

    /// Browser definitions — bundle id + the (browser-specific)
    /// AppleScript that returns `"<url>|||<title>"` for the
    /// active tab of the frontmost window. Safari also asks for
    /// the playing-state JSON via `do JavaScript`.
    private struct Browser {
        let name: String
        let bundleID: String
        let script: String
    }

    private static let browsers: [Browser] = [
        Browser(
            name: "Safari",
            bundleID: "com.apple.Safari",
            script: #"""
            tell application "Safari"
                try
                    set t to current tab of front window
                    set u to URL of t
                    set n to name of t
                    set js to ""
                    try
                        set js to (do JavaScript "JSON.stringify({p: !document.querySelector('video') || document.querySelector('video').paused, c: document.querySelector('video') ? document.querySelector('video').currentTime : 0, d: document.querySelector('video') ? document.querySelector('video').duration : 0})" in t)
                    end try
                    return u & "|||" & n & "|||" & js
                on error
                    return ""
                end try
            end tell
            """#),
        Browser(
            name: "Chrome",
            bundleID: "com.google.Chrome",
            script: chromiumScript("Google Chrome")),
        Browser(
            name: "Arc",
            bundleID: "company.thebrowser.Browser",
            script: chromiumScript("Arc")),
        Browser(
            name: "Brave",
            bundleID: "com.brave.Browser",
            script: chromiumScript("Brave Browser")),
        Browser(
            name: "Edge",
            bundleID: "com.microsoft.edgemac",
            script: chromiumScript("Microsoft Edge")),
    ]

    /// Same shape as Safari's script but using each Chromium
    /// browser's `active tab` syntax. We don't request JS
    /// execution from Chromium browsers — they require the
    /// "Allow JavaScript from Apple Events" toggle which most
    /// users haven't enabled, and silently failing JS would
    /// just slow the scripter down.
    private static func chromiumScript(_ app: String) -> String {
        #"""
        tell application "\#(app)"
            try
                set t to active tab of front window
                set u to URL of t
                set n to title of t
                return u & "|||" & n
            on error
                return ""
            end try
        end tell
        """#
    }

    /// Recognise a media URL and pull a clean track title out
    /// of the (often noisy) browser tab title. Returns nil for
    /// non-media tabs so the caller falls through to the next
    /// browser / source.
    private static func parse(
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

        let cleanTitle = strip(title: title, kind: kind)
        guard !cleanTitle.isEmpty else { return nil }
        return .init(
            title: cleanTitle,
            artist: nil,
            album: nil,
            artwork: nil,
            positionSeconds: position,
            durationSeconds: duration,
            isPlaying: isPlaying,
            source: source)
    }

    private enum MediaKind { case youtube, generic }

    /// Strip the browser's standard suffix decoration from the
    /// tab title — ` - YouTube`, ` | SoundCloud`, etc. — and
    /// drop the leading "(N)" unread-notification badge YouTube
    /// inserts when comments / subs have updates.
    private static func strip(title: String,
                              kind: MediaKind) -> String {
        var s = title.trimmingCharacters(in: .whitespaces)
        // YouTube: "(2) Track Name - YouTube" → "Track Name"
        if s.hasPrefix("(") {
            if let close = s.firstIndex(of: ")") {
                let after = s.index(after: close)
                s = String(s[after...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        let suffixes = [
            " - YouTube", " - YouTube Music",
            " | SoundCloud", " | Free Listening on SoundCloud",
            " on Bandcamp", " | Bandcamp",
            " - Twitch", " on Twitch",
            " on Vimeo", " | Vimeo",
            " - Spotify",
        ]
        for sfx in suffixes {
            if s.hasSuffix(sfx) {
                s = String(s.dropLast(sfx.count))
                break
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func host(of url: String) -> String {
        URL(string: url)?.host ?? ""
    }
    private static func path(of url: String) -> String {
        URL(string: url)?.path ?? ""
    }
}

// MARK: - Helpers

@MainActor
private func isRunning(_ bundleID: String) -> Bool {
    NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier == bundleID
    }
}

@MainActor
private func runAppleScript(_ source: String) -> String? {
    guard let script = NSAppleScript(source: source) else { return nil }
    var err: NSDictionary?
    let result = script.executeAndReturnError(&err)
    if let err {
        NowPlayingDebugLog.append(
            "\(Date()) AppleScript err: \(err)\n")
        return nil
    }
    return result.stringValue
}
