import SwiftUI

/// The rich content that materialises beneath the compact pill
/// when the user hovers for ≥1s. This file is the router only —
/// each per-activity layout lives in its own file under
/// `Sources/Halo/Expanded/`:
///
/// * `Sources/Halo/Expanded/ExpandedCardShared.swift` —
///   shared visual tokens (`.haloSecondary`, etc.) +
///   `ExpandedCardHeightKey` self-measurement.
/// * `Sources/Halo/Expanded/WorktreeExpandedView.swift`
/// * `Sources/Halo/Expanded/PortExpandedView.swift`
/// * `Sources/Halo/Expanded/AirPodsExpandedView.swift`
/// * `Sources/Halo/Expanded/BluetoothAudioExpandedView.swift`
/// * `Sources/Halo/Expanded/BatteryExpandedView.swift`
/// * `Sources/Halo/Expanded/CryptoExpandedView.swift`
///   (CryptoExpandedView + CryptoPill + CryptoRow + Sparkline)
/// * `Sources/Halo/Expanded/NowPlayingExpandedView.swift`
/// * `Sources/Halo/Expanded/EspressoExpandedView.swift`
/// * `Sources/Halo/Expanded/StatsExpandedView.swift`
///
/// The card lays its own padding internally — the caller just
/// hands it a frame and SwiftUI's intrinsic-sizing path
/// (combined with `ExpandedCardHeightKey`) tells `NotchHost`
/// how big the rendered card actually is.
struct ExpandedCard: View {
    let activity: LiveActivityCoordinator.Resolved
    /// Every active activity — used by views that aggregate
    /// data from multiple publishers in one card (the battery
    /// card lists AirPods alongside Mac + HID accessories).
    var allActivities: [LiveActivityCoordinator.Resolved] = []

    var body: some View {
        Group {
            switch activity.id {
            case "halo.stats":
                StatsExpandedView(activity: activity)
            case "espresso":
                EspressoExpandedView(activity: activity)
            case "halo.nowplaying":
                NowPlayingExpandedView(activity: activity)
            case "worktree":
                WorktreeExpandedView(activity: activity)
            case "port":
                PortExpandedView(activity: activity)
            case "halo.airpods":
                AirPodsExpandedView(activity: activity)
            case "halo.battery":
                BatteryExpandedView(
                    activity: activity,
                    allActivities: allActivities)
            case "halo.bluetoothaudio":
                BluetoothAudioExpandedView(activity: activity)
            case "halo.ext.crypto":
                CryptoExpandedView(activity: activity)
            default:
                genericContent
            }
        }
        // Internal padding so content never bleeds to the
        // island's edges (artwork flush-left, controls clipped
        // on the right). Horizontal matches the compact row's
        // inset; 12 top / 10 bottom. Applied INSIDE the measured
        // region below so the panel sizes to the padded height.
        .padding(.horizontal, Geometry.contentInset)
        .padding(.top, 12)
        .padding(.bottom, 5)
        // `.fixedSize(vertical: true)` makes the view refuse
        // to be vertically stretched by the parent's forced
        // `.frame(height:)`. Without this, the background
        // GeometryReader below would measure the PARENT's
        // allocated height instead of the content's natural
        // height — exactly the bug that left dead space at
        // the bottom when the panel was bigger than the
        // pills needed.
        .fixedSize(horizontal: false, vertical: true)
        // Publish the rendered content height via a
        // PreferenceKey. NotchView observes this and uses
        // the measured value to size the island shape and
        // the NSPanel exactly.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: ExpandedCardHeightKey.self,
                        value: proxy.size.height)
            }
        )
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var genericContent: some View {
        // Read-only for now — suite-app integrations don't yet
        // act on the Open CTA so we don't show one. Each app
        // can opt in to a real action later (open popover,
        // bring window forward, focus a specific section…).
        HStack(spacing: 12) {
            if let img = activity.compactLeadingImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .foregroundStyle(.haloTertiary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(titleForActivity)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.haloSecondary)
                if let value = activity.compactTrailingText {
                    Text(value)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Capitalised display name from the activity id —
    /// `worktree` → `WORKTREE`, `halo.volume` → `VOLUME`.
    private var titleForActivity: String {
        let trimmed = activity.id.hasPrefix("halo.")
            ? String(activity.id.dropFirst(5))
            : activity.id
        switch trimmed {
        case "nowplaying":  return "NOW PLAYING"
        default:            return trimmed.uppercased()
        }
    }
}
