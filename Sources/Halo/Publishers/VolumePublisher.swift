import AppKit
import CoreAudio

/// Cross-device "virtual main volume" selector. The plain
/// `kAudioDevicePropertyVolumeScalar` only works for devices
/// that expose a master element — AirPods, Bluetooth speakers,
/// and many USB DACs don't (volume lives on per-channel
/// elements). The virtual selector is what the system menu-bar
/// volume slider uses; it routes to whatever scheme the device
/// supports under the hood.
private let kVirtualMainVolume: AudioObjectPropertySelector =
    AudioObjectPropertySelector(0x766D766D)  // 'vmvm'

/// Watches the default output device's volume + mute and emits
/// a 2s-TTL HUD payload on every change. Same UX as the system
/// volume bezel, but rendered inside the island.
///
/// Implementation notes:
///   • CoreAudio's `AudioObjectAddPropertyListenerBlock` delivers
///     change events on the dispatch queue we hand it (main).
///     No timer needed.
///   • Volume reads use the `'vmvm'` virtual-main selector so
///     Bluetooth / AirPods / USB devices that don't expose a
///     master element still report a sane scalar.
///   • We re-bind when the user changes the default output
///     (AirPods connect, HDMI plugs in) by listening on the
///     system object for `kAudioHardwarePropertyDefaultOutputDevice`.
///   • Initial bind on `start()` is silent — we don't want a HUD
///     at app launch. Subsequent device changes DO emit one so
///     the user sees the new device's level.
@MainActor
final class VolumePublisher: HaloPublisher {
    let id = "halo.volume"

    private weak var coordinator: LiveActivityCoordinator?
    private var device: AudioDeviceID = kAudioObjectUnknown
    private var initialized = false

    init(coordinator: LiveActivityCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        rebindDevice(silent: true)
        // Listen on the system object for default-output changes
        // so we follow AirPods / HDMI / external DAC swaps.
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor in self?.rebindDevice(silent: false) }
        }
        initialized = true
    }

    func stop() {
        coordinator?.clear(id: id)
    }

    // MARK: - Device binding

    private func rebindDevice(silent: Bool) {
        var newDevice: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &newDevice)
        guard status == noErr,
              newDevice != kAudioObjectUnknown,
              newDevice != device
        else { return }
        device = newDevice

        // Volume listener on the cross-device virtual main —
        // catches changes on Bluetooth speakers / AirPods /
        // USB DACs where the per-device VolumeScalar isn't
        // exposed on the master element.
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kVirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            device, &volAddr, DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor in self?.publishCurrent() }
        }

        // Mute listener.
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            device, &muteAddr, DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor in self?.publishCurrent() }
        }

        // On a NON-initial bind (user actively switched device),
        // surface the new level so they know what they're at.
        if !silent { publishCurrent() }
    }

    // MARK: - Publish

    private func publishCurrent() {
        guard device != kAudioObjectUnknown else { return }
        let vol = readVolume()
        let muted = readMute()
        let pct = Int(round(vol * 100))
        let symbol: String
        switch (muted, vol) {
        case (true, _), (_, 0...0.001):
            symbol = "speaker.slash.fill"
        case (_, ..<0.34):
            symbol = "speaker.wave.1.fill"
        case (_, ..<0.67):
            symbol = "speaker.wave.2.fill"
        default:
            symbol = "speaker.wave.3.fill"
        }
        let payload = LiveActivityCoordinator.Resolved(
            id: id,
            compactLeadingImage:
                LiveActivityCoordinator.symbolImage(symbol),
            compactTrailingText: muted ? "Muted" : "\(pct)%",
            compactTrailingImage: nil,
            tint: .white,
            priority: 90)
        coordinator?.inject(payload, ttl: 2)
    }

    private func readVolume() -> Float {
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kVirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(
            device, &addr, 0, nil, &size, &vol)
        return vol
    }

    private func readMute() -> Bool {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(
            device, &addr, 0, nil, &size, &muted)
        return muted != 0
    }
}
