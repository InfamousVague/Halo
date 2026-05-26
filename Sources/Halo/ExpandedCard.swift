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
struct ExpandedCard: View {
    let activity: LiveActivityCoordinator.Resolved

    var body: some View {
        Group {
            switch activity.id {
            case "halo.stats":
                StatsExpandedView()
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
        // Match the compact row's horizontal inset
        // (`Geometry.contentInset`, 22pt) so icons in the
        // expanded layout line up vertically with the compact
        // row's leading icon.
        .padding(.horizontal, Geometry.contentInset)
        .padding(.top, 12)
        .padding(.bottom, 14)
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
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(titleForActivity)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.white)
                if let value = activity.compactTrailingText {
                    Text(value)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.72))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row — current state.
            HStack(spacing: 10) {
                if let img = activity.compactLeadingImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .foregroundStyle(.white)
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
                            Capsule().fill(
                                Color.orange.opacity(0.25)))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            if !otherBranches.isEmpty {
                Divider()
                    .background(Color.white.opacity(0.12))
                VStack(spacing: 4) {
                    ForEach(otherBranches, id: \.self) { b in
                        BranchRow(name: b) {
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5,
                                 style: .continuous)
                    .fill(Color.white.opacity(0.06)))
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
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                scrubber
            }
            controls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { startTicking() }
        .onDisappear { positionTimer?.invalidate() }
        .onChange(of: media?.title) { _, _ in
            livePosition = media?.positionSeconds ?? 0
        }
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
                    .fill(Color.white.opacity(0.08))
                Image(systemName: "music.note")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var scrubber: some View {
        let duration = media?.durationSeconds ?? 0
        let progress: Double = {
            guard duration > 0 else { return 0 }
            return min(1, max(0, livePosition / duration))
        }()
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                Capsule()
                    .fill(Color.white)
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
                .foregroundStyle(.white)
                .background(
                    Circle().fill(Color.white.opacity(
                        large ? 0.16 : 0.08)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Espresso

/// Single row showing the current keep-awake state (`ON` /
/// countdown / `OFF`) with an "End session" CTA visible only
/// while a session is active. Stops via a distributed
/// notification — Espresso's pane listens and calls
/// `store.deactivate()`.
private struct EspressoExpandedView: View {
    let activity: LiveActivityCoordinator.Resolved

    private var isActive: Bool {
        // Active state is whatever the publisher chooses to
        // surface in `compactTrailingText`; idle string is
        // literally "OFF".
        (activity.compactTrailingText ?? "OFF") != "OFF"
    }

    var body: some View {
        HStack(spacing: 12) {
            if let img = activity.compactLeadingImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("ESPRESSO")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.white)
                Text(activity.compactTrailingText ?? "OFF")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.72))
            }
            Spacer(minLength: 0)
            if isActive {
                Button {
                    DistributedNotificationCenter.default()
                        .postNotificationName(
                            Notification.Name(
                                "com.mattssoftware.espresso.stop"),
                            object: nil,
                            deliverImmediately: true)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9))
                        Text("End session")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(Color.white.opacity(0.14)))
                    .foregroundStyle(.white)
                    .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Stats widget

/// 3-row vertical layout — one row per metric, each
/// `[icon] [progress bar] [percentage]`. Samples on-appear
/// and ticks every 1s while visible (the compact-pill
/// publisher uses its own state so we re-sample here
/// independently).
private struct StatsExpandedView: View {
    @State private var cpu: Int = 0
    @State private var ram: Int = 0
    @State private var disk: Int = 0
    /// CPU tick deltas — first sample seeds, second onwards
    /// yields a usable percentage.
    @State private var prevCPUTicks: (total: UInt64, idle: UInt64)?
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 10) {
            StatRow(symbol: "cpu", value: cpu)
            StatRow(symbol: "memorychip", value: ram)
            StatRow(symbol: "internaldrive", value: disk)
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
        ram = sampleRAM()
        disk = sampleDisk()
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

    private func sampleRAM() -> Int {
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
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count)
                    + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count))
                    * pageSize
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return 0 }
        return Int((Double(used) / Double(total)) * 100)
    }

    private func sampleDisk() -> Int {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else { return 0 }
        let blockSize = UInt64(fs.f_bsize)
        let total = UInt64(fs.f_blocks) * blockSize
        let free = UInt64(fs.f_bavail) * blockSize
        guard total > 0 else { return 0 }
        let used = total &- free
        return Int((Double(used) / Double(total)) * 100)
    }
}

/// One metric row: 18pt icon · flex-width bar · 38pt percentage.
/// Trimmed to the essentials so three rows fit cleanly inside
/// the expanded card without crowding.
private struct StatRow: View {
    let symbol: String
    let value: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 18, alignment: .leading)
            ProgressBar(value: Double(value) / 100.0)
                .frame(height: 5)
                .frame(maxWidth: .infinity)
            Text("\(value)%")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 38, alignment: .trailing)
        }
        .frame(height: 20)
    }
}

private struct ProgressBar: View {
    let value: Double  // 0...1
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(2, proxy.size.width
                                      * CGFloat(min(1, max(0, value)))))
            }
        }
    }
}
