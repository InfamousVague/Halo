import AppKit
import SwiftUI

/// Branding helpers — every colour, image, and accent decision the
/// notch makes about a given activity. Pure functions of the activity
/// payload; no instance state. Lives in an extension so the main
/// `NotchView` body stays focused on layout, not lookup tables.
extension NotchView {
    static func accentColor(
        for a: LiveActivityCoordinator.Resolved
    ) -> Color {
        if a.id == "halo.nowplaying", let media = a.media {
            return mediaSourceColor(media.source)
        }
        // The compact pill tint is white across publishers —
        // detect that and route to the per-id brand color.
        if let brand = brandColor(forID: a.id) { return brand }
        return a.tint
    }

    /// Brand colour for the app currently driving the
    /// now-playing pill. `source` matches the string the
    /// scripters / MediaRemote bridge sets on `MediaInfo`.
    /// Unknown sources fall back to the generic music pink.
    private static func mediaSourceColor(_ source: String) -> Color {
        switch source {
        case "Spotify", "Spotify Web":
            // Spotify green (#1DB954).
            return Color(red: 0.11, green: 0.73, blue: 0.33)
        case "Music":
            // Apple Music red (#FA243C).
            return Color(red: 0.98, green: 0.14, blue: 0.24)
        case "YouTube", "YouTube Music":
            // YouTube red (#FF0000).
            return Color(red: 1.00, green: 0.00, blue: 0.00)
        case "SoundCloud":
            // SoundCloud orange (#FF5500).
            return Color(red: 1.00, green: 0.33, blue: 0.00)
        case "Bandcamp":
            // Bandcamp cyan (#1DA0C3).
            return Color(red: 0.11, green: 0.63, blue: 0.76)
        case "Twitch":
            // Twitch purple (#9146FF).
            return Color(red: 0.57, green: 0.27, blue: 1.00)
        case "Vimeo":
            // Vimeo cyan (#1AB7EA).
            return Color(red: 0.10, green: 0.72, blue: 0.92)
        case "MediaRemote":
            // Generic media bridge — we don't know who's
            // playing. Use the original neutral music pink so
            // the pill stays branded as "audio" rather than
            // jumping colours per track.
            return Color(red: 0.96, green: 0.41, blue: 0.62)
        default:
            return Color(red: 0.96, green: 0.41, blue: 0.62)
        }
    }

    /// Default brand-tint used for the leading icon, the
    /// trailing text, and the time read-out in the expanded
    /// music card. Most activities return the publisher's
    /// brand colour straight up — see `pillIconColor` /
    /// `pillTrailingTextColor` for the per-id overrides.
    static func pillTextColor(
        for a: LiveActivityCoordinator.Resolved
    ) -> Color {
        accentColor(for: a)
    }

    /// Tint for the leading-pill icon and the expanded-card
    /// header glyph. Same as the publisher's brand colour
    /// for most apps; Worktree overrides to the Git brand
    /// orange `#F1502F` so the official Jason Long logo
    /// reads in its native colour instead of being painted
    /// over with the worktree-green hex.
    static func pillIconColor(
        for a: LiveActivityCoordinator.Resolved
    ) -> Color {
        if a.id == "worktree" { return gitBrandColor }
        return pillTextColor(for: a)
    }

    /// Colour for the compact pill's trailing data text.
    /// Same brand colour as the icon for most apps; Worktree's
    /// branch name stays white because it's primary data
    /// (the thing the user actually reads) and matching the
    /// rest of the suite's "white primary text" convention
    /// keeps the glance hierarchy consistent.
    static func pillTrailingTextColor(
        for a: LiveActivityCoordinator.Resolved
    ) -> Color {
        if a.id == "worktree" { return .white }
        return pillTextColor(for: a)
    }
}
