import SwiftUI

/// Per-publisher colour palette. The table mapping every
/// activity id → its compact-pill brand tint. `accentColor(for:)`
/// in the sibling `NotchView+BrandColors` file routes through
/// here when the activity itself publishes a neutral tint and
/// we need a brand colour to fall back on.
extension NotchView {
    static func brandColor(forID id: String) -> Color? {
        switch id {
        // System HUDs match the system bezel's monochrome
        // palette — the digit + icon + accent trace all read
        // as one neutral overlay on top of the menu bar.
        // Coloured pills are reserved for app activities
        // (Espresso tan, Worktree green, etc).
        case "halo.volume":     return .white
        case "halo.brightness": return .white
        case "halo.nowplaying": return Color(red: 0.96, green: 0.41, blue: 0.62)
        case "halo.airpods":    return Color(red: 0.78, green: 0.78, blue: 0.82)
        case "halo.bluetoothaudio":
                                return Color(red: 0.36, green: 0.66, blue: 1.00)
        case "halo.stats":      return Color(red: 0.35, green: 0.83, blue: 0.85)
        case "halo.battery":    return Color(red: 0.30, green: 0.83, blue: 0.50)
        case "halo.vpn":        return Color(red: 0.30, green: 0.83, blue: 0.50)
        case "halo.calendar":   return Color(red: 1.00, green: 0.36, blue: 0.34)
        case "halo.github":     return Color(red: 0.55, green: 0.45, blue: 0.95)
        case "halo.docker":     return Color(red: 0.07, green: 0.56, blue: 0.91)
        case "halo.ext.crypto":
            // Bitcoin orange (#F7931A) — recognisable as
            // "crypto" without binding to any one coin's
            // brand. The compact pill cycles tickers, the
            // tint anchors the slot.
            return Color(red: 0.97, green: 0.58, blue: 0.10)
        // Suite-app publishers already carry a brand tint via
        // tintHex; fall through to use `activity.tint`.
        default:                return nil
        }
    }
}
