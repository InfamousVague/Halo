import AppKit
import SwiftUI

// MARK: - Bindings

// (`Color.haloBrand` — the warm-gold "active" accent the toggle
// rows and selected nav rail use — lives in
// `Sources/Halo/Styles/Colors.swift` alongside the other tokens.)

/// Bundles every UserDefaults toggle the drawer mutates into
/// one observable object so the SwiftUI view can read / write
/// without each row needing its own custom Binding factory.
@MainActor
@Observable
final class SettingsBindings {
    private weak var notchHost: NotchHost?

    init(notchHost: NotchHost) {
        self.notchHost = notchHost
    }

    var enabled: Bool {
        get { HaloSettings.enabled }
        set {
            HaloSettings.setEnabled(newValue)
            if newValue { notchHost?.enable() }
            else { notchHost?.disable() }
        }
    }
    var symmetry: Bool {
        get { HaloSettings.symmetryEnabled }
        set {
            HaloSettings.setSymmetryEnabled(newValue)
            // Symmetry affects the island's frame math — poke
            // the coordinator so SwiftUI re-runs `islandFrame`
            // and the pill resizes on the next tick.
            notchHost?.coordinator.refreshNow()
        }
    }
    var volume: Bool {
        get { HaloSettings.volumeHUDEnabled }
        set {
            HaloSettings.setVolumeHUDEnabled(newValue)
            notchHost?.restartPublishers()
        }
    }
    var brightness: Bool {
        get { HaloSettings.brightnessHUDEnabled }
        set {
            HaloSettings.setBrightnessHUDEnabled(newValue)
            notchHost?.restartPublishers()
        }
    }
    var nowPlaying: Bool {
        get { HaloSettings.nowPlayingEnabled }
        set {
            HaloSettings.setNowPlayingEnabled(newValue)
            notchHost?.restartPublishers()
        }
    }
    var airpods: Bool {
        get { HaloSettings.airpodsEnabled }
        set {
            HaloSettings.setAirpodsEnabled(newValue)
            notchHost?.restartPublishers()
        }
    }
    var bluetoothAudio: Bool {
        get { HaloSettings.bluetoothAudioEnabled }
        set {
            HaloSettings.setBluetoothAudioEnabled(newValue)
            notchHost?.restartPublishers()
        }
    }
    var stats: Bool {
        get { HaloSettings.statsEnabled }
        set {
            HaloSettings.setStatsEnabled(newValue)
            notchHost?.restartPublishers()
        }
    }
    var battery: Bool {
        get { HaloSettings.batteryEnabled }
        set {
            HaloSettings.setBatteryEnabled(newValue)
            notchHost?.restartPublishers()
        }
    }
    var vpn: Bool {
        get { HaloSettings.vpnEnabled }
        set {
            HaloSettings.setVPNEnabled(newValue)
            notchHost?.restartPublishers()
        }
    }
    var calendar: Bool {
        get { HaloSettings.calendarEnabled }
        set {
            HaloSettings.setCalendarEnabled(newValue)
            notchHost?.restartPublishers()
        }
    }
    var github: Bool {
        get { HaloSettings.githubEnabled }
        set {
            HaloSettings.setGithubEnabled(newValue)
            notchHost?.restartPublishers()
        }
    }
    var docker: Bool {
        get { HaloSettings.dockerEnabled }
        set {
            HaloSettings.setDockerEnabled(newValue)
            notchHost?.restartPublishers()
        }
    }

    func suiteSlotEnabled(_ id: String) -> Bool {
        HaloSettings.suiteSlotEnabled(id)
    }
    func setSuiteSlotEnabled(_ id: String, _ on: Bool) {
        HaloSettings.setSuiteSlotEnabled(id, on)
        notchHost?.coordinator.refreshNow()
    }

    func extensionEnabled(_ id: String) -> Bool {
        HaloSettings.extensionEnabled(id)
    }
    func setExtensionEnabled(_ id: String, _ on: Bool) {
        HaloSettings.setExtensionEnabled(id, on)
        // Extensions are publishers — tearing them down + re-
        // creating only what's currently enabled matches the
        // pattern the built-in publisher toggles use.
        notchHost?.restartPublishers()
    }
}
