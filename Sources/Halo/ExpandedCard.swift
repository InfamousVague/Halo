import AppKit
import Darwin
import SwiftUI

/// The rich content that materialises beneath the compact pill
/// when the user hovers for ≥1s. Dispatches by activity id to a
/// publisher-specific layout (Stats rows, AirPods per-device,
/// Worktree dirty + branch detail, etc.); falls back to a
/// generic "title + value + Open button" row for anything we
/// don't have a custom view for.
///
/// The card lays its own padding internally — the caller just
/// hands it a frame matching `Geometry.expandedExtraHeight`.
///
/// Visual hierarchy used by all sub-views:
///   • Primary text → `.white` (100%) — the data.
///   • Secondary text → `.white.opacity(0.62)` — labels,
///     subtitles, captions.
///   • Tertiary text / icons → `.white.opacity(0.4)` —
///     metadata, affordances.
///   • Faint surface → `.white.opacity(0.08)` — base of cells
///     / progress-bar tracks.
///   • Soft surface → `.white.opacity(0.14)` — pill buttons,
///     dividers.
/// `.foregroundStyle(.haloTertiary)` resolves against
/// `ShapeStyle`, not `Color` — the dot-shorthand lookup checks
/// the parameter type. Adding the tokens on
/// `ShapeStyle where Self == Color` lets both `.foregroundStyle`
/// (ShapeStyle) and direct `Color.haloX` usage work.
extension ShapeStyle where Self == Color {
    fileprivate static var haloSecondary: Color {
        Color.white.opacity(0.62)
    }
    fileprivate static var haloTertiary: Color {
        Color.white.opacity(0.4)
    }
    fileprivate static var haloSurfaceFaint: Color {
        Color.white.opacity(0.08)
    }
    fileprivate static var haloSurfaceSoft: Color {
        Color.white.opacity(0.14)
    }
}

extension Color {
    fileprivate static var haloSecondary: Color {
        Color.white.opacity(0.62)
    }
    fileprivate static var haloTertiary: Color {
        Color.white.opacity(0.4)
    }
    fileprivate static var haloSurfaceFaint: Color {
        Color.white.opacity(0.08)
    }
    fileprivate static var haloSurfaceSoft: Color {
        Color.white.opacity(0.14)
    }
}

struct ExpandedCard: View {
    let activity: LiveActivityCoordinator.Resolved

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
            default:
                genericContent
            }
        }
        // 22pt horizontal inset to match the compact-row
        // icon's column. Vertical pad is asymmetric — 12pt top
        // (clear of the compact row band) + 10pt bottom — the
        // bottom inset just needs visual breathing room from
        // the pill's rounded corner, not the full side
        // breathing room.
        .padding(.horizontal, Geometry.contentInset)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

// MARK: - Worktree

/// Branch switcher. Top row shows the current repo + branch +
/// dirty marker; below it a list of OTHER local branches the
/// user can switch to with a tap. Posts a distributed
/// notification — Worktree's listener does the auto-stash +
/// switch + pop on the other side.
private struct WorktreeExpandedView: View {
    let activity: LiveActivityCoordinator.Resolved

    private var info: LiveActivityCoordinator.WorktreeInfo? {
        activity.worktree
    }

    /// Branches other than the current one, alphabetised,
    /// capped so the card doesn't grow huge. Anything past the
    /// cap is reachable via the Worktree popover.
    private var otherBranches: [String] {
        guard let info else { return [] }
        return info.branches
            .filter { $0 != info.currentBranch }
            .sorted()
            .prefix(5)
            .map { $0 }
    }

    private var brand: Color {
        NotchView.pillTextColor(for: activity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row — current state.
            HStack(spacing: 10) {
                if let img = activity.compactLeadingImage {
                    Image(nsImage: NotchView.tinted(
                        img, color: brand))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                }
                Text(currentLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                if (info?.isDirty ?? false) {
                    Text("dirty")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(brand.opacity(0.22)))
                        .overlay(
                            Capsule().stroke(
                                brand.opacity(0.35),
                                lineWidth: 0.5))
                        .foregroundStyle(brand)
                }
                Spacer(minLength: 0)
                if let branchCount = info?.branches.count,
                   branchCount > 0 {
                    Text("\(branchCount) "
                         + (branchCount == 1
                            ? "branch" : "branches"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.haloTertiary)
                }
            }
            if !otherBranches.isEmpty {
                Divider()
                    .background(Color.haloSurfaceFaint)
                VStack(spacing: 4) {
                    ForEach(otherBranches, id: \.self) { b in
                        BranchRow(name: b, tint: brand) {
                            switchTo(b)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var currentLabel: String {
        guard let info else { return "WORKTREE" }
        let repo = (info.repoPath as NSString).lastPathComponent
        return "\(repo) · \(info.currentBranch)"
    }

    private func switchTo(_ branch: String) {
        DistributedNotificationCenter.default()
            .postNotificationName(
                Notification.Name(
                    "com.mattssoftware.worktree.switchBranch"),
                object: branch,
                deliverImmediately: true)
    }
}

private struct BranchRow: View {
    let name: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundStyle(tint.opacity(0.85))
                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(.haloSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.haloTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5,
                                 style: .continuous)
                    .fill(Color.haloSurfaceFaint))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Now Playing

/// Rich playback view: album cover thumbnail on the left,
/// title + artist + scrubber in the middle, prev/play-pause/
/// next on the right. Position refreshes on its own 1s timer
/// while visible so the scrubber moves smoothly even without
/// a fresh publish.
private struct NowPlayingExpandedView: View {
    let activity: LiveActivityCoordinator.Resolved

    @State private var livePosition: Double = 0
    @State private var positionTimer: Timer?

    private var media: LiveActivityCoordinator.MediaInfo? {
        activity.media
    }

    var body: some View {
        HStack(spacing: 12) {
            artwork
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6,
                                            style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(media?.title ?? "—")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(media?.artist ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.haloSecondary)
                    .lineLimit(1)
                scrubber
            }
            // Controls stack: play/pause row, then the
            // "position / duration" read-out underneath so
            // the user knows where the scrubber sits without
            // having to glance at the compact pill.
            VStack(spacing: 4) {
                controls
                timeReadout
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { startTicking() }
        .onDisappear { positionTimer?.invalidate() }
        .onChange(of: media?.title) { _, _ in
            livePosition = media?.positionSeconds ?? 0
        }
    }

    /// `00:42 / 03:14` — current position / total duration
    /// under the play / pause row. Uses
    /// `NotchView.dimmedUnitsText` so leading zeros and the
    /// `:` / `/` separators tone down to 50%, matching the
    /// compact pill.
    private var timeReadout: some View {
        let duration = media?.durationSeconds ?? 0
        let pos = Self.formatTime(livePosition)
        let dur = Self.formatTime(duration)
        return NotchView
            .dimmedUnitsText(
                "\(pos) / \(dur)",
                baseColor: NotchView.pillTextColor(for: activity))
            .font(.system(size: 10,
                          weight: .medium,
                          design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
    }

    private static func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    @ViewBuilder
    private var artwork: some View {
        if let img = media?.artwork {
            Image(nsImage: img)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.haloSurfaceFaint)
                Image(systemName: "music.note")
                    .font(.system(size: 18))
                    .foregroundStyle(.haloTertiary)
            }
        }
    }

    private var scrubber: some View {
        let duration = media?.durationSeconds ?? 0
        let progress: Double = {
            guard duration > 0 else { return 0 }
            return min(1, max(0, livePosition / duration))
        }()
        let tint = NotchView.pillTextColor(for: activity)
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.haloSurfaceSoft)
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, proxy.size.width
                                      * CGFloat(progress)))
            }
        }
        .frame(height: 3)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            ControlButton(symbol: "backward.fill") {
                postControl(.previous)
            }
            ControlButton(
                symbol: (media?.isPlaying ?? false)
                    ? "pause.fill" : "play.fill",
                large: true
            ) {
                postControl(.playPause)
            }
            ControlButton(symbol: "forward.fill") {
                postControl(.next)
            }
        }
    }

    // MARK: - Behaviour

    private enum Control { case playPause, next, previous }

    private func postControl(_ c: Control) {
        guard let source = media?.source else { return }
        switch (source, c) {
        case ("Spotify", .playPause): SpotifyScripter.playPause()
        case ("Spotify", .next):      SpotifyScripter.next()
        case ("Spotify", .previous):  SpotifyScripter.previous()
        case ("Music",   .playPause): MusicScripter.playPause()
        case ("Music",   .next):      MusicScripter.next()
        case ("Music",   .previous):  MusicScripter.previous()
        default:
            // MediaRemote control commands need yet another
            // private symbol set — wire on demand.
            break
        }
    }

    /// 1s tick that advances the scrubber locally so it looks
    /// alive between publishes. Re-sync with the publisher's
    /// reading every time the parent activity refreshes.
    private func startTicking() {
        livePosition = media?.positionSeconds ?? 0
        positionTimer = Timer.scheduledTimer(
            withTimeInterval: 1, repeats: true
        ) { _ in
            Task { @MainActor in
                guard media?.isPlaying ?? false else { return }
                livePosition += 1
            }
        }
    }
}

private struct ControlButton: View {
    let symbol: String
    var large: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: large ? 16 : 12,
                              weight: .semibold))
                .frame(width: large ? 28 : 22,
                       height: large ? 28 : 22)
                .foregroundStyle(.white.opacity(large ? 1 : 0.85))
                .background(
                    Circle().fill(
                        large ? Color.haloSurfaceSoft
                              : Color.haloSurfaceFaint))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Espresso

/// Header row (icon + label + countdown) above an action row
/// of quick-extend buttons + an End-session CTA. All four
/// buttons post distributed notifications — Espresso's pane
/// listens and calls `store.extend(byMinutes:)` or
/// `store.deactivate()` on the other side.
private struct EspressoExpandedView: View {
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
            // Header — current state.
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
                Spacer(minLength: 0)
            }
            // Action row — extend by N minutes, then End.
            if isActive {
                HStack(spacing: 6) {
                    if !isIndefinite {
                        ExtendPill(label: "+15m", tint: brand) {
                            extend(15)
                        }
                        ExtendPill(label: "+30m", tint: brand) {
                            extend(30)
                        }
                        ExtendPill(label: "+1h", tint: brand) {
                            extend(60)
                        }
                    }
                    Spacer(minLength: 0)
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

// MARK: - Stats widget

/// 3-row vertical layout — one row per metric, each
/// `[icon] [progress bar] [percentage]`. Samples on-appear
/// and ticks every 1s while visible (the compact-pill
/// publisher uses its own state so we re-sample here
/// independently).
private struct StatsExpandedView: View {
    let activity: LiveActivityCoordinator.Resolved

    @State private var cpu: Int = 0
    @State private var ram: Int = 0
    @State private var disk: Int = 0
    /// Bytes used / total per metric. RAM and disk surface the
    /// absolute numbers ("12.4 GB / 36.0 GB"); CPU's right
    /// column just shows the active-core count.
    @State private var ramBytes: (used: UInt64, total: UInt64) =
        (0, 0)
    @State private var diskBytes: (used: UInt64, total: UInt64) =
        (0, 0)
    /// CPU tick deltas — first sample seeds, second onwards
    /// yields a usable percentage.
    @State private var prevCPUTicks: (total: UInt64, idle: UInt64)?
    @State private var timer: Timer?

    private var brand: Color {
        NotchView.pillTextColor(for: activity)
    }
    private var cpuCores: Int {
        ProcessInfo.processInfo.activeProcessorCount
    }

    var body: some View {
        VStack(spacing: 10) {
            StatRow(
                symbol: "cpu",
                value: cpu,
                detail: "\(cpuCores) cores",
                tint: brand)
            StatRow(
                symbol: "memorychip",
                value: ram,
                detail: Self.formatBytes(ramBytes),
                tint: brand)
            StatRow(
                symbol: "internaldrive",
                value: disk,
                detail: Self.formatBytes(diskBytes),
                tint: brand)
        }
        .frame(maxWidth: .infinity)
        .onAppear { startSampling() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private func startSampling() {
        sampleAll()
        timer = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: true
        ) { _ in
            Task { @MainActor in sampleAll() }
        }
    }

    private func sampleAll() {
        cpu = sampleCPU()
        (ram, ramBytes) = sampleRAMDetail()
        (disk, diskBytes) = sampleDiskDetail()
    }

    /// `12.4 / 36 GB` — used + total in matching units. Pure
    /// "used GB" loses context; "GB free" inverts the meaning
    /// from the bar (which fills with used). This keeps both
    /// numbers and the bar reading consistently.
    private static func formatBytes(
        _ pair: (used: UInt64, total: UInt64)
    ) -> String {
        guard pair.total > 0 else { return "—" }
        let gb = 1024.0 * 1024.0 * 1024.0
        let used = Double(pair.used) / gb
        let total = Double(pair.total) / gb
        // Keep the label short — the row's right column is
        // narrow and we don't want it stealing space from the
        // bar.
        return String(format: "%.1f / %.0f GB", used, total)
    }

    private func sampleCPU() -> Int {
        var size = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size /
            MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(
                to: integer_t.self, capacity: Int(size)
            ) {
                host_statistics(
                    mach_host_self(),
                    HOST_CPU_LOAD_INFO,
                    $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let total = user + system + idle + nice
        defer { prevCPUTicks = (total, idle) }
        guard let prev = prevCPUTicks,
              total > prev.total else { return cpu }
        let totalΔ = total - prev.total
        let idleΔ = idle &- prev.idle
        let busyΔ = totalΔ &- idleΔ
        return Int((Double(busyΔ) / Double(totalΔ)) * 100)
    }

    private func sampleRAMDetail()
        -> (Int, (used: UInt64, total: UInt64))
    {
        var size = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size /
            MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(
                to: integer_t.self, capacity: Int(size)
            ) {
                host_statistics64(
                    mach_host_self(),
                    HOST_VM_INFO64,
                    $0, &size)
            }
        }
        guard result == KERN_SUCCESS
        else { return (0, (0, 0)) }
        let pageSize = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count)
                    + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count))
                    * pageSize
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return (0, (0, 0)) }
        let pct = Int((Double(used) / Double(total)) * 100)
        return (pct, (used, total))
    }

    private func sampleDiskDetail()
        -> (Int, (used: UInt64, total: UInt64))
    {
        var fs = statfs()
        guard statfs("/", &fs) == 0
        else { return (0, (0, 0)) }
        let blockSize = UInt64(fs.f_bsize)
        let total = UInt64(fs.f_blocks) * blockSize
        let free = UInt64(fs.f_bavail) * blockSize
        guard total > 0 else { return (0, (0, 0)) }
        let used = total &- free
        let pct = Int((Double(used) / Double(total)) * 100)
        return (pct, (used, total))
    }
}

/// One metric row: 18pt icon · flex-width bar (tinted in the
/// publisher's brand colour) · 38pt percentage with a small
/// secondary label underneath (RAM and disk show
/// used / total in GB, CPU shows the core count).
private struct StatRow: View {
    let symbol: String
    let value: Int
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint.opacity(0.85))
                .frame(width: 18, alignment: .leading)
            ProgressBar(
                value: Double(value) / 100.0,
                tint: tint)
                .frame(height: 5)
                .frame(maxWidth: .infinity)
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(value)%")
                    .font(.system(size: 12,
                                  weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text(detail)
                    .font(.system(size: 8,
                                  weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.haloTertiary)
            }
            .frame(minWidth: 78, alignment: .trailing)
        }
        .frame(height: 24)
    }
}

private struct ProgressBar: View {
    let value: Double  // 0...1
    let tint: Color
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.haloSurfaceSoft)
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, proxy.size.width
                                      * CGFloat(min(1, max(0, value)))))
            }
        }
    }
}
