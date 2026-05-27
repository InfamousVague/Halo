import AppKit
import CoreAudio

/// "There's a Bluetooth speaker / headphones connected" pill.
/// Watches CoreAudio's default output device and publishes a
/// pill whenever the active output is a Bluetooth-transport
/// device that ISN'T AirPods or Beats (those keep their own
/// dedicated pill via `AirPodsPublisher`, which can read the
/// BLE proximity-pairing advertisements for per-bud battery).
///
/// For everything else — JBL Flip, Sonos Roam, Bose
/// QuietComfort, generic AVRCP speakers — we publish the
/// device name, an inferred SF-Symbol icon (speaker /
/// headphones / soundbar / earbuds), and a best-effort
/// battery percent scraped from `system_profiler
/// SPBluetoothDataType -json`.
///
/// `system_profiler` is the only cross-vendor source of BT
/// device battery on macOS — IORegistry exposes it for Apple's
/// own accessories but generic AVRCP devices don't put it
/// there. The shell-out is slow (~200ms) so we cache the
/// result and only refresh on device-change + every 90s while
/// the device stays connected.
///
/// Priority 40 — same as AirPods, well below transient HUDs
/// (90) and Now Playing (60). The pill appears in the
/// ambient rotation when a Bluetooth speaker is the active
/// output.
@MainActor
final class BluetoothAudioPublisher: HaloPublisher {
    let id = "halo.bluetoothaudio"

    private weak var coordinator: LiveActivityCoordinator?
    private var device: AudioDeviceID = kAudioObjectUnknown
    private var refreshTimer: Timer?
    /// Last reading we published — used to dedupe identical
    /// publishes (re-reading every 90s shouldn't churn the
    /// activity rotation unless the battery actually changed).
    private var lastInfo: LiveActivityCoordinator
        .BluetoothAudioInfo?

    init(coordinator: LiveActivityCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        // Watch default-output changes so we react when the
        // user switches AirPods → JBL via the menu-bar volume
        // slider, or unplugs HDMI and falls back to BT.
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor in self?.rebind() }
        }
        rebind()
        // Refresh the battery (which requires a shell-out)
        // every 90s while the device is still active. Plenty
        // for a battery that drains over hours.
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: 90, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.publishCurrent() }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        coordinator?.clear(id: id)
    }

    // MARK: - Bind / publish

    private func rebind() {
        device = currentDefaultOutput()
        publishCurrent()
    }

    private func publishCurrent() {
        guard device != kAudioObjectUnknown,
              transportType(device) == kAudioDeviceTransportTypeBluetooth,
              let name = deviceName(device)
        else {
            lastInfo = nil
            coordinator?.clear(id: id)
            return
        }
        // AirPods + Beats have their own dedicated pill
        // (per-bud battery via BLE advertisements). Skip them
        // here so the user doesn't see two competing pills
        // for the same device.
        let lower = name.lowercased()
        if lower.contains("airpod") || lower.contains("beats") {
            lastInfo = nil
            coordinator?.clear(id: id)
            return
        }

        // Battery lookup is async (system_profiler shell-out
        // off the main actor) — publish a tentative payload
        // without battery now, then re-publish when the
        // battery resolves. This keeps the pill responsive on
        // first connect even if system_profiler is slow.
        let symbol = inferSymbol(name: name)
        publish(name: name,
                batteryPercent: lastInfo?.batteryPercent,
                symbol: symbol)
        Task.detached { [weak self] in
            let pct = await Self.readBluetoothBattery(name: name)
            await MainActor.run {
                guard let self else { return }
                // Only republish if the battery value actually
                // changed (avoid bumping the focus window for
                // a no-op refresh).
                guard pct != self.lastInfo?.batteryPercent
                else { return }
                self.publish(name: name,
                             batteryPercent: pct,
                             symbol: symbol)
            }
        }
    }

    private func publish(name: String,
                         batteryPercent: Int?,
                         symbol: String) {
        let info = LiveActivityCoordinator.BluetoothAudioInfo(
            name: name,
            batteryPercent: batteryPercent,
            symbol: symbol)
        lastInfo = info
        let payload = LiveActivityCoordinator.Resolved(
            id: id,
            compactLeadingImage:
                LiveActivityCoordinator.symbolImage(symbol),
            // Compact pill shows battery when known, falls
            // back to the device name when not. Cap the name
            // at 20 chars so a long "Sonos Living Room
            // Sound 2" doesn't blow out the pill width.
            compactTrailingText: batteryPercent.map {
                "\($0)%"
            } ?? Self.trim(name, max: 20),
            compactTrailingImage: nil,
            tint: .white,
            priority: 40,
            bluetoothAudio: info)
        coordinator?.inject(payload)
    }

    /// SF Symbol best guess from the device's name. Apple
    /// product naming is consistent enough that a substring
    /// check covers the common form factors.
    private func inferSymbol(name: String) -> String {
        let n = name.lowercased()
        if n.contains("homepod") { return "homepod.fill" }
        if n.contains("soundbar") {
            return "hifispeaker.fill"
        }
        if n.contains("headphone") || n.contains("hd ") ||
           n.contains("wh-") || n.contains("xm5") ||
           n.contains("qc ") || n.contains("quietcomfort") {
            return "headphones"
        }
        if n.contains("buds") || n.contains("earbud") {
            return "earbuds"
        }
        if n.contains("car") || n.contains("auto") {
            return "car.fill"
        }
        return "hifispeaker.fill"
    }

    private static func trim(_ s: String,
                             max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }

    // MARK: - CoreAudio reads

    private func currentDefaultOutput() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &id)
        return status == noErr ? id : kAudioObjectUnknown
    }

    private func transportType(_ d: AudioDeviceID) -> UInt32 {
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(
            d, &addr, 0, nil, &size, &t)
        return t
    }

    private func deviceName(_ d: AudioDeviceID) -> String? {
        var ref: Unmanaged<CFString>? = nil
        var size = UInt32(
            MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            d, &addr, 0, nil, &size, &ref)
        guard status == noErr,
              let cf = ref?.takeRetainedValue()
        else { return nil }
        return cf as String
    }

    // MARK: - system_profiler battery scrape

    /// Spawns `system_profiler -json SPBluetoothDataType` and
    /// hunts for `device_batteryLevelMain` on the entry whose
    /// `device_name` matches our active output. JSON because
    /// the plain-text format changes between macOS releases;
    /// JSON's stable across 13–15.
    nonisolated static func readBluetoothBattery(
        name: String
    ) async -> Int? {
        await Task.detached(priority: .utility) { () -> Int? in
            let p = Process()
            p.executableURL = URL(
                fileURLWithPath:
                    "/usr/sbin/system_profiler")
            p.arguments = [
                "-json", "SPBluetoothDataType",
            ]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            // Cap the wait so a hung system_profiler doesn't
            // block the publish — 5s is more than enough on
            // any reasonable Mac.
            let deadline = Date().addingTimeInterval(5)
            while p.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if p.isRunning { p.terminate(); return nil }
            let data = pipe.fileHandleForReading
                .readDataToEndOfFile()
            return parseBattery(data: data,
                                deviceName: name)
        }.value
    }

    /// Walks the (somewhat awkward) SPBluetoothDataType JSON
    /// structure looking for the device by name and returns
    /// its `device_batteryLevelMain` as an Int (the field is
    /// a string like `"75%"`). Robust to missing keys.
    nonisolated static func parseBattery(
        data: Data, deviceName: String
    ) -> Int? {
        guard let any = try? JSONSerialization
                .jsonObject(with: data),
              let root = any as? [String: Any],
              let bt = root["SPBluetoothDataType"]
                as? [[String: Any]]
        else { return nil }
        let needle = deviceName.lowercased()
        for section in bt {
            // The "device_connected" key is an array of
            // dictionaries, each with one key — the device's
            // human-readable name.
            guard let connected = section["device_connected"]
                    as? [[String: Any]]
            else { continue }
            for entry in connected {
                for (name, value) in entry {
                    guard name.lowercased() == needle,
                          let info = value as? [String: Any]
                    else { continue }
                    if let pct = extractPercent(
                        info["device_batteryLevelMain"]) {
                        return pct
                    }
                    // Some over-ear headphones split L/R; use
                    // the lowest of the two so the pill shows
                    // the urgent value.
                    let l = extractPercent(
                        info["device_batteryLevelLeft"])
                    let r = extractPercent(
                        info["device_batteryLevelRight"])
                    if let mn = [l, r].compactMap({ $0 }).min() {
                        return mn
                    }
                    if let c = extractPercent(
                        info["device_batteryLevelCase"]) {
                        return c
                    }
                }
            }
        }
        return nil
    }

    nonisolated private static func extractPercent(
        _ v: Any?
    ) -> Int? {
        if let s = v as? String {
            // "75%" → 75
            let trimmed = s.trimmingCharacters(
                in: CharacterSet(charactersIn: "% "))
            return Int(trimmed)
        }
        if let n = v as? Int { return n }
        return nil
    }
}
