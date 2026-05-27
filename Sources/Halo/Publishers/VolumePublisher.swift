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

    /// Candidate (selector, element) pairs for reading volume
    /// on the current device. Probed in priority order — the
    /// first one that responds via `AudioObjectHasProperty`
    /// becomes the read source, and listeners are registered
    /// on EVERY pair that responds so a change reported on
    /// any of them re-publishes the HUD.
    ///
    /// Why so many candidates: macOS exposes volume on
    /// different (selector, element) pairs depending on the
    /// device. Built-in speakers + USB DACs put it on the
    /// master element under `kAudioDevicePropertyVolumeScalar`.
    /// Bluetooth speakers + AirPods often skip the master and
    /// only expose per-channel scalars on elements 1 + 2.
    /// `'vmvm'` (cross-device "virtual main") works for some
    /// AirPods firmware versions but returns 0 on others.
    /// Trying them all in order guarantees we read SOMETHING
    /// sane on every device the system menu-bar slider would.
    private var volumeCandidates: [(AudioObjectPropertySelector,
                                    AudioObjectPropertyElement)] {
        [
            (kVirtualMainVolume,
             kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyVolumeScalar,
             kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyVolumeScalar, 1),  // left
            (kAudioDevicePropertyVolumeScalar, 2),  // right
        ]
    }

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

        // Volume listeners — register on every candidate the
        // device actually responds to so we catch the change
        // event whichever element/selector the audio driver
        // chooses to fire on.
        for (selector, element) in volumeCandidates {
            var a = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            guard AudioObjectHasProperty(device, &a)
            else { continue }
            AudioObjectAddPropertyListenerBlock(
                device, &a, DispatchQueue.main
            ) { [weak self] _, _ in
                Task { @MainActor in
                    self?.publishCurrent()
                }
            }
        }

        // Mute listener — both master and per-channel mute
        // selectors, same rationale as volume.
        for element: AudioObjectPropertyElement in
            [kAudioObjectPropertyElementMain, 1, 2] {
            var a = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            guard AudioObjectHasProperty(device, &a)
            else { continue }
            AudioObjectAddPropertyListenerBlock(
                device, &a, DispatchQueue.main
            ) { [weak self] _, _ in
                Task { @MainActor in
                    self?.publishCurrent()
                }
            }
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
        // Try master selectors first — single read, single value.
        for (selector, element) in volumeCandidates
            where element == kAudioObjectPropertyElementMain {
            if let v = readScalar(
                selector: selector, element: element) {
                return v
            }
        }
        // Per-channel fallback — average over whichever
        // channels respond. Bluetooth devices that don't
        // expose a master element typically expose
        // VolumeScalar on element 1 (left) + 2 (right); the
        // mean tracks the system menu-bar slider closely
        // enough for a HUD readout.
        var sum: Float = 0
        var count: Float = 0
        for element: AudioObjectPropertyElement in [1, 2] {
            if let v = readScalar(
                selector: kAudioDevicePropertyVolumeScalar,
                element: element) {
                sum += v
                count += 1
            }
        }
        return count > 0 ? sum / count : 0
    }

    private func readScalar(
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> Float? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element)
        guard AudioObjectHasProperty(device, &addr)
        else { return nil }
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(
            device, &addr, 0, nil, &size, &vol)
        return status == noErr ? vol : nil
    }

    private func readMute() -> Bool {
        for element: AudioObjectPropertyElement in
            [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            guard AudioObjectHasProperty(device, &addr)
            else { continue }
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(
                device, &addr, 0, nil, &size, &muted)
            if status == noErr { return muted != 0 }
        }
        return false
    }
}
