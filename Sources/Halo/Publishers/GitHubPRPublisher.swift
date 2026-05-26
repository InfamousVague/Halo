import AppKit
import Foundation

/// Open-PR count via the `gh` CLI. No GitHub API token in
/// Halo's possession — `gh` is already authenticated for the
/// user, and its output is what we read.
///
/// Visibility: silent when zero open PRs (or `gh` isn't
/// installed). Surfaces a count when at least one PR is open
/// and authored by the current user.
@MainActor
final class GitHubPRPublisher: HaloPublisher {
    let id = "halo.github"

    private weak var coordinator: LiveActivityCoordinator?
    private var timer: Timer?

    init(coordinator: LiveActivityCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        refresh()
        // 5 min cadence — PR state doesn't change THAT fast,
        // and `gh pr list` is a network round-trip.
        timer = Timer.scheduledTimer(
            withTimeInterval: 300, repeats: true
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
        // Run off-main so the network call doesn't hitch the
        // island.
        Task.detached(priority: .background) {
            guard let count = Self.openPRCount() else {
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
                            "arrow.triangle.pull"),
                    compactTrailingText:
                        "\(count) PR\(count == 1 ? "" : "s")",
                    compactTrailingImage: nil,
                    tint: .white,
                    priority: 35)
                self.coordinator?.inject(payload)
            }
        }
    }

    /// Counts the user's own open PRs via
    /// `gh pr list --author=@me --state=open --json number`.
    /// Returns nil when `gh` isn't installed or isn't logged in.
    nonisolated private static func openPRCount() -> Int? {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh",
        ]
        guard let gh = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = [
            "pr", "list",
            "--author=@me",
            "--state=open",
            "--json", "number",
            "--limit", "100",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let array = (try? JSONSerialization.jsonObject(
            with: data)) as? [Any]
        else { return nil }
        return array.count
    }
}
