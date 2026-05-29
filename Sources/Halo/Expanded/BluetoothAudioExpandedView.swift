import SwiftUI

// MARK: - Bluetooth audio

/// Generic Bluetooth speaker / headphones / soundbar card.
/// Shown when the active audio output is a Bluetooth-transport
/// device that ISN'T AirPods/Beats (those have their own
/// per-bud breakdown card). The expanded card surfaces:
///
/// * The device name + form-factor SF Symbol (speaker /
///   headphones / soundbar / earbuds, inferred from name).
/// * Battery percent + level bar when `system_profiler`
///   surfaced one. Some generic AVRCP speakers don't report
///   battery — those just show "Connected".
/// * Eyebrow "BLUETOOTH AUDIO" so the user knows which pill
///   they're looking at when several audio outputs are nearby.
struct BluetoothAudioExpandedView: View {
    let activity: LiveActivityCoordinator.Resolved

    private var info:
        LiveActivityCoordinator.BluetoothAudioInfo? {
        activity.bluetoothAudio
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: info?.symbol
                      ?? "hifispeaker.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("BLUETOOTH AUDIO")
                        .font(.system(size: 10,
                                      weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(.haloSecondary)
                    Text(info?.name ?? "Connected")
                        .font(.system(size: 13,
                                      weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Text("Connected")
                    .font(.system(size: 9,
                                  weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(
                            Color.white.opacity(0.14)))
            }
            Divider().background(Color.haloSurfaceFaint)
            if let pct = info?.batteryPercent {
                batteryRow(percent: pct)
            } else {
                Text("Battery not reported")
                    .font(.system(size: 10))
                    .foregroundStyle(.haloTertiary)
                    .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func batteryRow(percent: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: batterySymbol(for: percent))
                .font(.system(size: 11))
                .foregroundStyle(.haloSecondary)
                .frame(width: 18, alignment: .center)
            Text("Battery")
                .font(.system(size: 11))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.haloSurfaceFaint)
                Capsule()
                    .fill(barColor(for: percent))
                    .frame(width: 100
                           * CGFloat(percent) / 100)
            }
            .frame(width: 100, height: 4)
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

    private func batterySymbol(for p: Int) -> String {
        switch p {
        case ..<10:  return "battery.0"
        case ..<25:  return "battery.25"
        case ..<50:  return "battery.50"
        case ..<75:  return "battery.75"
        default:     return "battery.100"
        }
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

