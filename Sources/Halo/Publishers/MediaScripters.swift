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
        guard isRunning("com.spotify.client") else { return nil }
        let script = """
        tell application id "com.spotify.client"
            if it is running then
                try
                    set t to current track
                    set st to (player state as text)
                    set pos to player position
                    return (name of t) & "|||" ¬
                        & (artist of t) & "|||" ¬
                        & (album of t) & "|||" ¬
                        & (artwork url of t) & "|||" ¬
                        & st & "|||" ¬
                        & pos & "|||" ¬
                        & (duration of t)
                on error
                    return ""
                end try
            end if
        end tell
        return ""
        """
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
        let script = """
        tell application id "com.apple.Music"
            if it is running then
                try
                    set t to current track
                    set st to (player state as text)
                    set pos to player position
                    return (name of t) & "|||" ¬
                        & (artist of t) & "|||" ¬
                        & (album of t) & "|||" ¬
                        & st & "|||" ¬
                        & pos & "|||" ¬
                        & (duration of t)
                on error
                    return ""
                end try
            end if
        end tell
        return ""
        """
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
        NSLog("[halo] AppleScript error: \(err)")
        return nil
    }
    return result.stringValue
}
