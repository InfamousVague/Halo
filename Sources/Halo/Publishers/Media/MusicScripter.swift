import AppKit
import Foundation

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

