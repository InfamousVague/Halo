import SwiftUI

// MARK: - Battery

/// Per-device battery breakdown. The top row is always the
/// Mac itself — large percentage + level bar + a bolt pill
/// when charging. Below that, a list of every connected
/// device with battery info we can read:
///
/// * HID accessories from IORegistry (Magic Mouse / Trackpad /
///   Keyboard, third-party HID with `BatteryPercent`)
/// * AirPods (read across from the AirPods publisher's
///   payload in `allActivities` — left + right + case folded
///   into a single "lowest of all" pill plus a per-bud
///   breakdown badge)
///
/// Falls back gracefully when no accessories are connected —
/// the card just shows the Mac battery on its own.
struct BatteryExpandedView: View {
    let activity: LiveActivityCoordinator.Resolved
    let allActivities: [LiveActivityCoordinator.Resolved]

    private var info: LiveActivityCoordinator.BatteryInfo? {
        activity.battery
    }

    /// AirPods state from the sibling `halo.airpods` activity,
    /// when both publishers are active simultaneously. Lets us
    /// list AirPods alongside the Mac + HID devices instead of
    /// fragmenting battery info across two separate dropdowns.
    private var airpods: LiveActivityCoordinator.AirPodsInfo? {
        allActivities.first {
            $0.id == "halo.airpods"
        }?.airpods
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            macRow
            Divider().background(Color.haloSurfaceFaint)
            VStack(spacing: 4) {
                ForEach(info?.devices ?? [], id: \.self) { d in
                    DeviceBatteryRow(
                        name: d.name,
                        symbol: d.symbol,
                        percent: d.percent,
                        charging: false)
                }
                if let ap = airpods {
                    airpodsRow(ap)
                }
                if (info?.devices.isEmpty ?? true)
                   && airpods == nil {
                    Text("No other devices connected")
                        .font(.system(size: 10))
                        .foregroundStyle(.haloTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity,
                               alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var macRow: some View {
        HStack(spacing: 10) {
            if let img = activity.compactLeadingImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("THIS MAC")
                    .font(.system(size: 10,
                                  weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.haloSecondary)
                Text("\(info?.macPercent ?? 0)%")
                    .font(.system(size: 14,
                                  weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
            if info?.macCharging == true {
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9,
                                      weight: .bold))
                    Text("Charging")
                        .font(.system(size: 10,
                                      weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(
                        Color.white.opacity(0.14)))
            }
        }
    }

    private func airpodsRow(
        _ ap: LiveActivityCoordinator.AirPodsInfo
    ) -> some View {
        // Lowest of left / right / case for the headline
        // number — same "show the urgent value" rule the
        // AirPods compact pill uses.
        let lowest = [ap.left, ap.right, ap.caseBattery]
            .compactMap { $0 }.min() ?? 0
        let name = ap.deviceName.isEmpty
            ? "AirPods" : ap.deviceName
        return DeviceBatteryRow(
            name: name,
            symbol: "airpods",
            percent: lowest,
            charging: ap.charging)
    }
}

/// One row in the battery expanded card. Icon + name on the
/// left, percentage + level bar on the right. The whole row
/// dims when battery is unknown (-1) or below the urgency
/// threshold — matches the iOS Now-Playing battery row look.
private struct DeviceBatteryRow: View {
    let name: String
    let symbol: String
    let percent: Int
    let charging: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.haloSecondary)
                .frame(width: 18, alignment: .center)
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9,
                                  weight: .bold))
                    .foregroundStyle(.white)
            }
            // Level bar — same iOS battery palette as the
            // AirPods cells (green > 20%, amber 10-20%, red
            // < 10%).
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.haloSurfaceFaint)
                Capsule()
                    .fill(barColor(for: percent))
                    .frame(width: 60
                           * CGFloat(percent) / 100)
            }
            .frame(width: 60, height: 4)
            Text("\(percent)%")
                .font(.system(size: 11,
                              weight: .semibold,
                              design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 36, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5,
                             style: .continuous)
                .fill(Color.haloSurfaceFaint))
    }

    private func barColor(for p: Int) -> Color {
        switch p {
        case ..<10:  return Color(red: 1.00,
                                  green: 0.38,
                                  blue: 0.35)
        case ..<20:  return Color(red: 1.00,
                                  green: 0.78,
                                  blue: 0.20)
        default:     return Color(red: 0.30,
                                  green: 0.83,
                                  blue: 0.50)
        }
    }
}

