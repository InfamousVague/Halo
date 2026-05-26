import AppKit
import Foundation

/// Running-container count via `docker ps -q`. No API key,
/// no socket auth — `docker` is already configured for the
/// user (either via Docker Desktop, OrbStack, or Colima).
///
/// Visibility: silent when zero or the binary's missing.
@MainActor
final class DockerPublisher: HaloPublisher {
    let id = "halo.docker"

    private weak var coordinator: LiveActivityCoordinator?
    private var timer: Timer?

    init(coordinator: LiveActivityCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        refresh()
        // 30s cadence — container counts ebb during normal
        // dev work but rarely flap second-by-second.
        timer = Timer.scheduledTimer(
            withTimeInterval: 30, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        coordinator?.clear(id: id)
    }

    private func refresh() {
        Task.detached(priority: .background) {
            guard let count = Self.runningCount() else {
                await MainActor.run { [weak self] in
                    self?.coordinator?.clear(id: self?.id ?? "")
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if count == 0 {
                    self.coordinator?.clear(id: self.id)
                    return
                }
                let payload = LiveActivityCoordinator.Resolved(
                    id: self.id,
                    compactLeadingImage:
                        LiveActivityCoordinator.symbolImage(
                            "shippingbox.fill"),
                    compactTrailingText: "\(count) running",
                    compactTrailingImage: nil,
                    tint: .white,
                    priority: 25)
                self.coordinator?.inject(payload)
            }
        }
    }

    /// Counts running containers via
    /// `docker ps -q | wc -l`. Returns nil when docker isn't
    /// installed OR the daemon isn't running (the CLI prints
    /// to stderr in that case and exits non-zero).
    nonisolated private static func runningCount() -> Int? {
        let candidates = [
            "/opt/homebrew/bin/docker",
            "/usr/local/bin/docker",
            "/usr/bin/docker",
        ]
        guard let docker = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: docker)
        process.arguments = ["ps", "-q"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8) ?? ""
        return s.split(whereSeparator: \.isNewline)
            .filter { !$0.isEmpty }
            .count
    }
}
