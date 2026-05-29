import SwiftUI

// MARK: - Stats widget

/// 3-row vertical layout — one row per metric, each
/// `[icon] [progress bar] [percentage]`. Samples on-appear
/// and ticks every 1s while visible (the compact-pill
/// publisher uses its own state so we re-sample here
/// independently).
struct StatsExpandedView: View {
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
