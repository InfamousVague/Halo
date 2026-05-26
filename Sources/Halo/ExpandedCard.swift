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
