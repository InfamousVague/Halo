import Foundation

/// UserDefaults facade for every knob Halo exposes. Each
/// publisher and each suite-app slot has its own toggle so
/// users can mix Halo with other tools they already run (e.g.
/// keep ours for music, switch ours off for volume to avoid
/// two bezels overlapping).
enum HaloSettings {

    // MARK: - Master

    private static let enabledKey = "halo.enabled"

    static var enabled: Bool { defaultOn(forKey: enabledKey) }
    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
    }

    // MARK: - Built-in publishers (Halo's own system integrations)

    static var volumeHUDEnabled: Bool {
        defaultOn(forKey: "halo.publisher.volume")
    }
    static func setVolumeHUDEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "halo.publisher.volume")
    }

    static var brightnessHUDEnabled: Bool {
        defaultOn(forKey: "halo.publisher.brightness")
    }
    static func setBrightnessHUDEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "halo.publisher.brightness")
    }

    static var nowPlayingEnabled: Bool {
        defaultOn(forKey: "halo.publisher.nowplaying")
    }
    static func setNowPlayingEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "halo.publisher.nowplaying")
    }

    static var airpodsEnabled: Bool {
        defaultOn(forKey: "halo.publisher.airpods")
    }
    static func setAirpodsEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "halo.publisher.airpods")
    }

    static var statsEnabled: Bool {
        defaultOn(forKey: "halo.publisher.stats")
    }
    static func setStatsEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "halo.publisher.stats")
    }

    // MARK: - Suite apps (external publishers via the file store)

    /// Slot id matches the JSON filename the publisher writes
    /// to under `~/Library/Application Support/MattsSoftware/
    /// live-activity/`. New suite apps "appear" in settings
    /// automatically by being added to `suiteSlots` below.
    static let suiteSlots: [SuiteSlot] = [
        .init(id: "espresso", title: "Espresso",
              subtitle: "Keep-awake countdown",
              symbol: "cup.and.saucer.fill"),
        .init(id: "worktree", title: "Worktree",
              subtitle: "Current repo + branch",
              symbol: "arrow.triangle.branch"),
        .init(id: "port", title: "Port",
              subtitle: "Listening ports",
              symbol: "network"),
        .init(id: "peephole", title: "Peephole",
              subtitle: "Camera + mic activity",
              symbol: "eye.fill"),
        .init(id: "seasick", title: "Seasick",
              subtitle: "Active downloads",
              symbol: "arrow.down.circle.fill"),
    ]

    /// Visibility toggle for a single suite slot. Default-on
    /// so freshly-installed suite apps appear in the island
    /// without forcing the user to opt in for each.
    static func suiteSlotEnabled(_ id: String) -> Bool {
        defaultOn(forKey: "halo.suite.\(id)")
    }

    static func setSuiteSlotEnabled(_ id: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "halo.suite.\(id)")
    }

    // MARK: - Helpers

    /// Absence of a key means "first launch" → default on; once
    /// the user toggles, we honour their explicit choice.
    private static func defaultOn(forKey key: String) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: key)
    }
}

/// Metadata for one external (file-store) publisher slot —
/// used by the Settings UI to render the toggle row and by the
/// coordinator to know which slot ids to filter against.
struct SuiteSlot: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
}
