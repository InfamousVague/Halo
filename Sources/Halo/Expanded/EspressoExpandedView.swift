import SwiftUI

// MARK: - Espresso

/// Header row (icon + label + countdown) above an action row
/// of quick-extend buttons + an End-session CTA. All four
/// buttons post distributed notifications — Espresso's pane
/// listens and calls `store.extend(byMinutes:)` or
/// `store.deactivate()` on the other side.
struct EspressoExpandedView: View {
    let activity: LiveActivityCoordinator.Resolved

    private var isActive: Bool {
        // Active state is whatever the publisher chooses to
        // surface in `compactTrailingText`; idle string is
        // literally "OFF".
        (activity.compactTrailingText ?? "OFF") != "OFF"
    }
    private var brand: Color {
        NotchView.pillTextColor(for: activity)
    }
    private var isIndefinite: Bool {
        // Extend buttons only make sense when the session has
        // an end date to push out. The pane writes "ON" for
        // indefinite sessions.
        (activity.compactTrailingText ?? "OFF") == "ON"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // State row — icon + ESPRESSO/value on the left, the
            // End-session button right-aligned on the SAME row.
            HStack(spacing: 12) {
                if let img = activity.compactLeadingImage {
                    Image(nsImage: NotchView.tinted(
                        img, color: brand))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("ESPRESSO")
                        .font(.system(size: 11,
                                      weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(brand.opacity(0.85))
                    NotchView.dimmedUnitsText(
                        activity.compactTrailingText ?? "OFF",
                        baseColor: .white)
                        .font(.system(size: 14,
                                      weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 8)
                if isActive {
                    Button(action: end) {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 9))
                            Text("End")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(
                                Color.white.opacity(0.10)))
                        .foregroundStyle(.white)
                        .font(.system(size: 11,
                                      weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
            }
            // Quick-extend row — only for TIMED sessions (there's
            // an end date to push out). Indefinite "ON" sessions
            // have nothing to extend, so the state row is all
            // that shows.
            if isActive && !isIndefinite {
                HStack(spacing: 6) {
                    ExtendPill(label: "+15m", tint: brand) {
                        extend(15)
                    }
                    ExtendPill(label: "+30m", tint: brand) {
                        extend(30)
                    }
                    ExtendPill(label: "+1h", tint: brand) {
                        extend(60)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func extend(_ minutes: Int) {
        DistributedNotificationCenter.default()
            .postNotificationName(
                Notification.Name(
                    "com.mattssoftware.espresso.extend"),
                object: String(minutes),
                deliverImmediately: true)
    }
    private func end() {
        DistributedNotificationCenter.default()
            .postNotificationName(
                Notification.Name(
                    "com.mattssoftware.espresso.stop"),
                object: nil,
                deliverImmediately: true)
    }
}

/// Small brand-tinted pill button for Espresso's
/// quick-extend row.
private struct ExtendPill: View {
    let label: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(tint.opacity(0.18)))
                .overlay(
                    Capsule().stroke(tint.opacity(0.35),
                                     lineWidth: 0.5))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}
