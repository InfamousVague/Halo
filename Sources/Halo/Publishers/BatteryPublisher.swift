import AppKit
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
        // Show only at the salient moments — let the system
        // battery icon cover the middle of the range.
        let interesting =
            info.isCharging || info.percent <= 20 || info.percent >= 99
        guard interesting else {
            coordinator?.clear(id: id)
            return
        }
        let symbol = batterySymbol(
            percent: info.percent, charging: info.isCharging)
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
            priority: info.percent <= 20 ? 75 : 35)
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
        if charging { return "battery.100.bolt" }
        switch percent {
        case 0..<10:   return "battery.0"
        case 10..<25:  return "battery.25"
        case 25..<50:  return "battery.50"
        case 50..<75:  return "battery.75"
        default:       return "battery.100"
        }
    }
}
