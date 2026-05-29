import SwiftUI

// MARK: - AirPods

/// Per-bud battery breakdown for AirPods / Beats. Header shows
/// the device name (so a household with two pairs can tell
/// which one is connected); below, three battery pills — left
/// bud, right bud, and the case — each showing percentage,
/// charging indicator, and a tinted level bar.
///
/// Buds with `nil` battery (in case, lid closed, firmware
/// reported "unknown") render as a faint placeholder rather
/// than being hidden, so the layout doesn't shift around as
/// the buds come in and out of the case.
struct AirPodsExpandedView: View {
    let activity: LiveActivityCoordinator.Resolved

    private var info: LiveActivityCoordinator.AirPodsInfo? {
        activity.airpods
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let img = activity.compactLeadingImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("AIRPODS")
                        .font(.system(size: 10,
                                      weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(.haloSecondary)
                    if let name = info?.deviceName,
                       !name.isEmpty {
                        Text(name)
                            .font(.system(size: 12,
                                          weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                if info?.charging == true {
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
            Divider().background(Color.haloSurfaceFaint)
            HStack(spacing: 8) {
                BatteryCell(label: "Left",
                            icon: "earbuds",
                            percent: info?.left)
                BatteryCell(label: "Right",
                            icon: "earbuds",
                            percent: info?.right)
                BatteryCell(label: "Case",
                            icon: "earbuds.case.fill",
                            percent: info?.caseBattery)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One battery pill in the AirPods card. `nil` percent renders
/// as a faint "—" so the row keeps its layout while a bud is
/// in the case reporting unknown.
private struct BatteryCell: View {
    let label: String
    let icon: String
    let percent: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(.haloSecondary)
                Text(label.uppercased())
                    .font(.system(size: 9,
                                  weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(.haloSecondary)
                Spacer(minLength: 0)
                if let p = percent {
                    Text("\(p)%")
                        .font(.system(size: 11,
                                      weight: .semibold,
                                      design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                } else {
                    Text("—")
                        .font(.system(size: 11,
                                      weight: .semibold))
                        .foregroundStyle(.haloTertiary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.haloSurfaceFaint)
                    Capsule()
                        .fill(barColor(for: percent))
                        .frame(
                            width: geo.size.width
                                * CGFloat(percent ?? 0) / 100)
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6,
                             style: .continuous)
                .fill(Color.haloSurfaceFaint))
        .frame(maxWidth: .infinity)
    }

    /// Bar colour mirrors the iOS battery indicator: green
    /// above 20%, amber 10–20%, red under 10%. Matches the
    /// same urgency cues the compact-pill glyph uses.
    private func barColor(for p: Int?) -> Color {
        guard let p else { return .haloSurfaceFaint }
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

