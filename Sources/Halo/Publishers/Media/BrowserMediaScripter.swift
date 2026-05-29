import AppKit
import Foundation

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
            let jsPart = parts.count >= 3 ? parts[2] : ""
            NowPlayingDebugLog.append(
                "\(Date()) \(browser.name): " +
                "url=\(url.prefix(80)) " +
                "title=\(title.prefix(80)) " +
                "js=\(jsPart.isEmpty ? "<EMPTY>" : jsPart)\n")
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

    enum MediaKind { case youtube, generic }

    /// Strip the browser's standard suffix decoration from the
    /// tab title — ` - YouTube`, ` | SoundCloud`, etc. — and
    /// drop the leading "(N)" unread-notification badge YouTube
    /// inserts when comments / subs have updates.
    static func strip(title: String,
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

    static func host(of url: String) -> String {
        URL(string: url)?.host ?? ""
    }
    static func path(of url: String) -> String {
        URL(string: url)?.path ?? ""
    }
}
