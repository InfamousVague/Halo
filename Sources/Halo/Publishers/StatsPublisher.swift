import AppKit
import Darwin

/// Surface system load as an ambient pill — CPU, RAM, and Disk
/// take turns in the slot every few seconds. Useful "is the
/// machine OK?" glance, cheap to compute (a couple of mach
/// host queries + one statfs per tick).
///
/// Publishing model:
///   • Every `metricInterval` we rotate to the next metric
///     (CPU → RAM → Disk → CPU…) and republish with the
///     fresh reading.
///   • Re-publishing the same metric also re-samples it so the
///     pill stays live if it happens to hold the slot longer
///     than `metricInterval` (focus held by another publisher).
///   • Priority 20 — below transient HUDs, below Now Playing
///     / Espresso / Worktree. Stats is background presence,
///     never demands the slot.
@MainActor
final class StatsPublisher: HaloPublisher {
    let id = "halo.stats"

    private weak var coordinator: LiveActivityCoordinator?
    private var tickTimer: Timer?
    private var current: Metric = .cpu

    /// Previous total + idle ticks from `HOST_CPU_LOAD_INFO`,
    /// needed because the kernel returns counters since boot —
    /// usage % is computed as the delta between two samples.
    private var prevCPUTicks: (total: UInt64, idle: UInt64)?

    /// How long each metric holds the slot before we rotate.
    /// 3s feels readable; longer than the rapid-update window
    /// (2s) so each rotation registers as a focus-worthy event
    /// in Halo's coordinator — gives Stats a brief flash each
    /// rotation rather than sitting silent.
    private let metricInterval: TimeInterval = 3

    init(coordinator: LiveActivityCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        publishCurrent()
        tickTimer = Timer.scheduledTimer(
            withTimeInterval: metricInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.advanceAndPublish() }
        }
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        coordinator?.clear(id: id)
    }

    private func advanceAndPublish() {
        current = current.next
        publishCurrent()
    }

    private func publishCurrent() {
        let value: Int
        let symbol: String
        let label: String
        switch current {
        case .cpu:
            value = sampleCPUPercent()
            symbol = "cpu"
            label = "CPU"
        case .ram:
            value = sampleRAMPercent()
            symbol = "memorychip"
            label = "RAM"
        case .disk:
            value = sampleDiskPercent()
            symbol = "internaldrive"
            label = "Disk"
        }
        let payload = LiveActivityCoordinator.Resolved(
            id: id,
            compactLeadingImage:
                LiveActivityCoordinator.symbolImage(symbol),
            // Combine the metric name + value so the user sees
            // "CPU 42%" rather than just "42%" — without it
            // they couldn't tell which metric is on display.
            compactTrailingText: "\(label) \(value)%",
            compactTrailingImage: nil,
            tint: .white,
            priority: 20)
        coordinator?.inject(payload)
    }

    // MARK: - Metric enum

    private enum Metric {
        case cpu, ram, disk
        var next: Metric {
            switch self {
            case .cpu:  return .ram
            case .ram:  return .disk
            case .disk: return .cpu
            }
        }
    }

    // MARK: - Sampling

    /// CPU usage % since the previous sample. Mach's
    /// `HOST_CPU_LOAD_INFO` returns counters since boot in 4
    /// buckets (user / system / idle / nice); usage = 1 −
    /// (idleΔ / totalΔ). First sample seeds the previous-ticks
    /// cache and returns 0 — not enough data to compute a
    /// rate yet.
    private func sampleCPUPercent() -> Int {
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
              total > prev.total else { return 0 }
        let totalΔ = total - prev.total
        let idleΔ = idle &- prev.idle
        let busyΔ = totalΔ &- idleΔ
        return Int((Double(busyΔ) / Double(totalΔ)) * 100)
    }

    /// RAM usage % from `host_statistics64(HOST_VM_INFO64)`.
    /// Uses (active + wired + compressed) / total — same set
    /// Activity Monitor sums under "Memory Used."
    private func sampleRAMPercent() -> Int {
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

    /// Root volume usage % via `statfs(2)`. `f_blocks` total
    /// blocks, `f_bavail` blocks available to non-root.
    private func sampleDiskPercent() -> Int {
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
