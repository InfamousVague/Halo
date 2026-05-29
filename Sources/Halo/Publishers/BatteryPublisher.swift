import AppKit
import IOKit
import IOKit.hid
import IOKit.ps

/// Mac battery + charging state via IOKit. No permission
/// required — `IOPSCopyPowerSourcesInfo` is read-only system
/// info.
///
/// Visibility rule: silent at 50–95% on battery (the system
/// menu-bar widget already shows this). Surfaces when charging,
/// when low (< 20%), or when full (100%) — moments the user
/// might want to act on.
@MainActor
final class BatteryPublisher: HaloPublisher {
    let id = "halo.battery"

    private weak var coordinator: LiveActivityCoordinator?
    private var timer: Timer?

    init(coordinator: LiveActivityCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        publishCurrent()
        // 30s tick is plenty — battery percent rarely changes
        // faster than that on a real workload.
        timer = Timer.scheduledTimer(
            withTimeInterval: 30, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.publishCurrent() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        coordinator?.clear(id: id)
    }

    private func publishCurrent() {
        guard let info = readPrimarySource() else {
            coordinator?.clear(id: id)
            return
        }
        // Default visibility: ONLY while charging. The macOS
        // menu-bar battery icon already covers the steady-
        // state percentage; pulling the user's eye to the
        // notch every time the battery dips low or finishes
        // charging is noise. The bolt + percentage pill on
        // plug-in is the actually-useful moment — that's the
        // signal a session just changed state.
        guard info.isCharging else {
            coordinator?.clear(id: id)
            return
        }
        let symbol = batterySymbol(
            percent: info.percent, charging: info.isCharging)
        let devices = readConnectedHIDBatteries()
        let battery = LiveActivityCoordinator.BatteryInfo(
            macPercent: info.percent,
            macCharging: info.isCharging,
            devices: devices)
        let payload = LiveActivityCoordinator.Resolved(
            id: id,
            compactLeadingImage:
                LiveActivityCoordinator.symbolImage(symbol),
            compactTrailingText: "\(info.percent)%",
            compactTrailingImage: nil,
            tint: .white,
            // Low battery is urgent — bump priority so it
            // interrupts ambient publishers. Charging/full
            // are informational.
            priority: info.percent <= 20 ? 75 : 35,
            battery: battery)
        coordinator?.inject(payload)
    }

    private struct Reading {
        let percent: Int
        let isCharging: Bool
    }

    private func readPrimarySource() -> Reading? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?
                .takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?
                .takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(
                snapshot, source)?.takeUnretainedValue()
                as? [String: Any]
            else { continue }
            // Skip UPS / external sources — only want the
            // internal Mac battery.
            let type = desc[kIOPSTypeKey] as? String
            guard type == kIOPSInternalBatteryType else { continue }
            guard let current = desc[kIOPSCurrentCapacityKey]
                    as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int,
                  max > 0
            else { continue }
            let percent = (current * 100) / max
            let isCharging = (desc[kIOPSIsChargingKey] as? Bool)
                ?? false
            return Reading(percent: percent, isCharging: isCharging)
        }
        return nil
    }

    private func batterySymbol(
        percent: Int, charging: Bool
    ) -> String {
        // When charging the leading icon IS the charging
        // indicator — a plain bolt, no battery outline. The
        // user knows it's the battery pill from the context
        // and the percentage on the trailing side. Avoids
        // the doubled-bolt look (battery-icon's embedded
        // bolt + a bolt indicator) the old design had.
        if charging { return "bolt.fill" }
        switch percent {
        case 0..<10:   return "battery.0"
        case 10..<25:  return "battery.25"
        case 25..<50:  return "battery.50"
        case 50..<75:  return "battery.75"
        default:       return "battery.100"
        }
    }

    // MARK: - HID accessories

    /// Enumerates every `IOHIDDevice` IORegistry entry that
    /// publishes a `BatteryPercent` property and returns it as
    /// a tidy list for the expanded card. Catches Magic Mouse
    /// / Magic Trackpad / Magic Keyboard (Apple's accessories
    /// register `BatteryPercent` on themselves) plus any
    /// third-party HID that follows the same convention.
    ///
    /// Cheap — single matching-dict registry walk; takes a few
    /// milliseconds even with many devices attached. We call it
    /// on every 30s publish tick, no caching required.
    private func readConnectedHIDBatteries()
        -> [LiveActivityCoordinator.ConnectedBatteryDevice]
    {
        var devices: [LiveActivityCoordinator
            .ConnectedBatteryDevice] = []
        var iter: io_iterator_t = 0
        let matching = IOServiceMatching("IOHIDDevice")
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, matching, &iter
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }

        var seen: Set<String> = []
        var svc = IOIteratorNext(iter)
        while svc != 0 {
            defer {
                IOObjectRelease(svc)
                svc = IOIteratorNext(iter)
            }
            guard let pct = IORegistryEntryCreateCFProperty(
                svc, "BatteryPercent" as CFString,
                kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? Int else { continue }
            let name = (IORegistryEntryCreateCFProperty(
                svc, "Product" as CFString,
                kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String) ?? "Device"
            // Multiple HID interfaces on the same device
            // (a Magic Keyboard exposes keyboard + Touch ID
            // sensor as separate IOHIDDevice nodes, both
            // carrying the same BatteryPercent). Dedupe by
            // product name so the user sees one row per
            // physical accessory.
            let key = "\(name)|\(pct)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            devices.append(.init(
                name: name,
                percent: pct,
                symbol: hidSymbol(for: name)))
        }
        return devices.sorted { $0.name < $1.name }
    }

    /// SF Symbol best-guess for a HID accessory's product
    /// string. Matches the system's own Bluetooth menu icons
    /// where possible so the expanded card reads as native.
    private func hidSymbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("trackpad") {
            return "rectangle.fill.on.rectangle.fill"
        }
        if n.contains("mouse") { return "magicmouse.fill" }
        if n.contains("keyboard") { return "keyboard.fill" }
        if n.contains("pencil") || n.contains("pen") {
            return "applepencil"
        }
        if n.contains("airpod") || n.contains("beats") {
            return "airpods"
        }
        return "dot.radiowaves.left.and.right"
    }
}
