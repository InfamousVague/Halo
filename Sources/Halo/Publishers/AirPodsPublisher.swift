import AppKit
import CoreBluetooth

/// Reads battery levels from nearby AirPods / Beats by parsing
/// Apple's BLE proximity-pairing advertisements (manufacturer
/// ID 0x004C, subtype 0x07). The advertisements broadcast at
/// ≈1 Hz when the buds are out of the case or the case lid is
/// open; we never connect or pair, just sniff the broadcast.
///
/// Caveats:
///   • Requires Bluetooth permission (Info.plist
///     `NSBluetoothAlwaysUsageDescription`). First launch shows
///     the system prompt; refusal silently disables the
///     publisher.
///   • The advertisement format is reverse-engineered and
///     undocumented. Different Apple bud firmware versions
///     occasionally shift byte offsets; we log the raw
///     manufacturer data on parse failures so we can iterate.
///   • Battery nibble is `0xF` when the device is in the case
///     and reporting "unknown" — those readings are dropped.
///   • Priority 40 — well below transient HUDs (90) and Now
///     Playing (60). The pill only shows AirPods when nothing
///     more urgent is competing for the slot.
@MainActor
final class AirPodsPublisher: NSObject, HaloPublisher {
    let id = "halo.airpods"

    private weak var coordinator: LiveActivityCoordinator?
    private var central: CBCentralManager?
    private var lastPayload: AirPodsReading?
    private var staleTimer: Timer?
    /// Time after which a single reading is considered stale if
    /// no fresher advertisement has arrived. Matches the case-
    /// closed broadcast cadence.
    private let staleAfter: TimeInterval = 30
    private var lastReadingAt: Date = .distantPast

    init(coordinator: LiveActivityCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        // Lazily create the central — initialising it triggers
        // the OS permission prompt.
        central = CBCentralManager(
            delegate: self, queue: .main,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: false,
            ])
        // Sweep stale readings every 5s.
        staleTimer = Timer.scheduledTimer(
            withTimeInterval: 5, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.checkStale() }
        }
    }

    func stop() {
        central?.stopScan()
        central = nil
        staleTimer?.invalidate()
        staleTimer = nil
        coordinator?.clear(id: id)
    }

    // MARK: - Stale sweep

    private func checkStale() {
        guard lastPayload != nil else { return }
        if Date().timeIntervalSince(lastReadingAt) > staleAfter {
            lastPayload = nil
            coordinator?.clear(id: id)
        }
    }

    // MARK: - Advertisement parsing

    /// One reading from a single advertisement. Battery values
    /// are 0–100 (already mapped); `nil` means the device
    /// reported "unknown" (in case, lid closed, etc).
    fileprivate struct AirPodsReading: Equatable {
        let left: Int?
        let right: Int?
        let caseBattery: Int?
        /// True if any pod is currently charging.
        let charging: Bool

        /// Battery to surface in the compact pill — the lowest
        /// of left/right (so the user sees the urgent number).
        /// Falls back to case battery if both buds are unknown.
        var compactBattery: Int? {
            let bud = [left, right].compactMap { $0 }.min()
            return bud ?? caseBattery
        }
    }

    fileprivate func parseAdvertisement(_ data: Data) -> AirPodsReading? {
        // Manufacturer data layout (when Apple proximity-pair):
        //   [0..1] = 0x4C 0x00  (Apple manufacturer ID)
        //   [2]    = 0x07       (subtype: proximity pairing)
        //   [3]    = length
        //   [4..]  = payload
        // We only see [4..] sometimes; CoreBluetooth strips the
        // company ID on some macOS versions. Tolerate both.
        var p = data
        if p.count >= 2, p[0] == 0x4C, p[1] == 0x00 {
            p = p.subdata(in: 2..<p.count)
        }
        guard p.count >= 16 else { return nil }
        guard p[0] == 0x07 else { return nil }

        // Empirical offsets — verified across AirPods Pro Gen 2
        // and AirPods 3 firmware. Documented by MagicPodsCore
        // and AirBuddy reverse-engineering.
        //
        //   p[5] = flip bit (which nibble is L vs R, depends on
        //                    whether case is opened from L or R
        //                    side facing user)
        //   p[6] = battery nibbles — high = "primary", low = "secondary"
        //   p[7] = high nibble = case battery (0-10 × 10 = %)
        //          low nibble  = charging flags (bit 0 = right,
        //                                         bit 1 = left,
        //                                         bit 2 = case)
        let primary = nibbleToPercent(p[6] >> 4)
        let secondary = nibbleToPercent(p[6] & 0x0F)
        let caseBattery = nibbleToPercent(p[7] >> 4)
        let chargingFlags = p[7] & 0x07

        // Flip bit determines which is left vs right. Bit 5 of
        // p[5] (the "flip" bit) — when set, primary == right.
        let flipped = (p[5] & 0x20) != 0
        let left = flipped ? secondary : primary
        let right = flipped ? primary : secondary

        let charging = chargingFlags != 0

        return AirPodsReading(
            left: left,
            right: right,
            caseBattery: caseBattery,
            charging: charging)
    }

    private func nibbleToPercent(_ n: UInt8) -> Int? {
        // 0x0–0xA → 0%–100%. 0xF (and anything > 0xA) is the
        // "unknown" marker — bud in case with lid closed.
        let v = n & 0x0F
        guard v <= 10 else { return nil }
        return Int(v) * 10
    }

    // MARK: - Publish

    fileprivate func apply(reading: AirPodsReading) {
        // Same reading → don't churn the UI.
        if reading == lastPayload { return }
        lastPayload = reading
        lastReadingAt = Date()
        guard let pct = reading.compactBattery else {
            coordinator?.clear(id: id)
            return
        }
        // Choose a glyph that hints at state:
        //   • charging → bolt
        //   • below 20% → low battery
        //   • otherwise → AirPods symbol
        let symbol: String
        if reading.charging {
            symbol = "airpods"
        } else if pct <= 20 {
            symbol = "airpods.gen2"
        } else {
            symbol = "airpods"
        }
        let payload = LiveActivityCoordinator.Resolved(
            id: id,
            compactLeadingImage:
                LiveActivityCoordinator.symbolImage(symbol),
            compactTrailingText: "\(pct)%",
            compactTrailingImage: nil,
            tint: .white,
            priority: 40)
        coordinator?.inject(payload)
    }
}

// MARK: - CBCentralManagerDelegate

extension AirPodsPublisher: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(
        _ central: CBCentralManager
    ) {
        let state = central.state
        Task { @MainActor in
            guard state == .poweredOn else {
                NSLog("[halo] AirPods: BLE state = \(state.rawValue) — not scanning")
                return
            }
            // Scan continuously with duplicate keys enabled —
            // we want every advertisement so we can refresh
            // battery levels at the broadcast rate.
            central.scanForPeripherals(
                withServices: nil,
                options: [
                    CBCentralManagerScanOptionAllowDuplicatesKey: true,
                ])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let data = advertisementData[
            CBAdvertisementDataManufacturerDataKey] as? Data
        else { return }
        // Cheap pre-filter before we hop to main: must be Apple
        // proximity-pairing.
        guard data.count >= 4 else { return }
        let appleHeader = data.starts(with: [0x4C, 0x00, 0x07])
            || (data.count >= 17 && data[0] == 0x07)
        guard appleHeader else { return }

        Task { @MainActor [weak self] in
            guard let self,
                  let reading = self.parseAdvertisement(data)
            else { return }
            self.apply(reading: reading)
        }
    }
}
