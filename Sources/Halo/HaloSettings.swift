import Foundation

/// Tiny UserDefaults facade for Halo's launcher-wide preferences.
/// Each Phase 1 publisher gets its own toggle so users can
/// disable the ones that overlap with other tools they run
/// (e.g. someone with an existing volume HUD switches ours off
/// rather than getting two bezels at once).
enum HaloSettings {
    private static let enabledKey = "halo.enabled"
    private static let volumeHUDKey = "halo.publisher.volume"
    private static let brightnessHUDKey = "halo.publisher.brightness"
    private static let nowPlayingKey = "halo.publisher.nowplaying"
    private static let airpodsKey = "halo.publisher.airpods"

    static var enabled: Bool {
        defaultOn(forKey: enabledKey)
    }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
    }

    static var volumeHUDEnabled: Bool {
        defaultOn(forKey: volumeHUDKey)
    }

    static func setVolumeHUDEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: volumeHUDKey)
    }

    static var brightnessHUDEnabled: Bool {
        defaultOn(forKey: brightnessHUDKey)
    }

    static func setBrightnessHUDEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: brightnessHUDKey)
    }

    static var nowPlayingEnabled: Bool {
        defaultOn(forKey: nowPlayingKey)
    }

    static func setNowPlayingEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: nowPlayingKey)
    }

    static var airpodsEnabled: Bool {
        defaultOn(forKey: airpodsKey)
    }

    static func setAirpodsEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: airpodsKey)
    }

    /// Absence of a key means "first launch" → default on; once
    /// the user toggles, we honour their explicit choice.
    private static func defaultOn(forKey key: String) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: key)
    }
}
