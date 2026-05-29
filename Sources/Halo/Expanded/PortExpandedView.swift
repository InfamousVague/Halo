import AppKit
import SwiftUI

// MARK: - Port

/// Lists the top few listening ports Port surfaced in the
/// live-activity payload, with a per-row kill button. Tap a
/// row's kill icon → distributed notification → Port's
/// `killByPid` runs `kill(2)` on the owning pid. Rows
/// disappear from the next publish once the process is gone.
struct PortExpandedView: View {
    let activity: LiveActivityCoordinator.Resolved

    private var info: LiveActivityCoordinator.PortInfo? {
        activity.port
    }
    private var brand: Color {
        NotchView.pillTextColor(for: activity)
    }
    private var totalCount: Int {
        Int(activity.compactTrailingText ?? "") ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header — total listening-port count + a small
            // "showing N of M" hint when we capped the list.
            HStack(spacing: 10) {
                if let img = activity.compactLeadingImage {
                    Image(nsImage: NotchView.tinted(
                        img, color: brand))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("LISTENING PORTS")
                        .font(.system(size: 10,
                                      weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(brand.opacity(0.85))
                    // Verbatim so the count never picks up
                    // the locale's thousands separator (1,234)
                    // — the compact pill renders the same
                    // value as a plain integer, and they
                    // should match.
                    Text(verbatim: "\(totalCount) open")
                        .font(.system(size: 12,
                                      weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                if let info, info.entries.count < totalCount {
                    Text("top \(info.entries.count)")
                        .font(.system(size: 10,
                                      weight: .medium))
                        .foregroundStyle(.haloTertiary)
                }
            }
            if let entries = info?.entries, !entries.isEmpty {
                Divider().background(Color.haloSurfaceFaint)
                // 2-column grid — at the expanded width the
                // card is wide enough to fit two port cards
                // side by side, which reads better than a
                // single tall list. Caps at 6 entries (Port
                // sorts by port number and prefixes to 6
                // before publishing), filling a 2×3 grid
                // exactly.
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(),
                                 spacing: 6),
                        GridItem(.flexible(),
                                 spacing: 6)
                    ],
                    spacing: 4
                ) {
                    ForEach(entries, id: \.self) { e in
                        PortRow(entry: e, tint: brand) {
                            kill(pid: e.pid)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func kill(pid: Int32) {
        DistributedNotificationCenter.default()
            .postNotificationName(
                Notification.Name(
                    "com.mattssoftware.port.kill"),
                object: String(pid),
                deliverImmediately: true)
    }
}

/// One row in the Port expanded card.
///
/// Layout, left to right:
///   • Port number (data; large white)
///   • Service / process name (label; secondary)
///   • Kill button (brand-tinted destructive action)
private struct PortRow: View {
    let entry: LiveActivityCoordinator.PortEntry
    let tint: Color
    let kill: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // `Text(verbatim:)` so port numbers don't pick up
            // the user's locale separator — Text's default
            // `String(describing:)` interpolation would render
            // 1900 as "1,900" in en_US.
            Text(verbatim: String(entry.port))
                .font(.system(size: 12,
                              weight: .semibold,
                              design: .monospaced))
                .foregroundStyle(.white)
                .fixedSize()
            Text(entry.proto.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(tint.opacity(0.18)))
                .foregroundStyle(tint)
                .fixedSize()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.haloSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button(action: kill) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(
                        Circle().fill(
                            Color.white.opacity(0.10)))
                    .foregroundStyle(.haloSecondary)
            }
            .buttonStyle(.plain)
            .help("Terminate pid \(entry.pid) (\(entry.process))")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5,
                             style: .continuous)
                .fill(Color.haloSurfaceFaint))
    }

    private var label: String {
        if let svc = entry.service, !svc.isEmpty {
            return svc
        }
        return entry.process
    }
}

