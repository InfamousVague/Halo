import Foundation

/// Tiny UserDefaults facade for Halo's launcher-wide preferences.
/// Phase 0 has one knob (enabled / disabled); future phases add
/// per-section toggles (music, HUDs, calendar, etc.) here.
enum HaloSettings {
    private static let enabledKey = "halo.enabled"

    static var enabled: Bool {
        // Absence of a key means "first launch" → default on.
        if UserDefaults.standard.object(forKey: enabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
    }
}
