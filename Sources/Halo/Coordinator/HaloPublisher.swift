import Foundation

// MARK: - Publisher protocol

/// In-process source of live-activity payloads — Halo's built-in
/// system integrations (volume, brightness, now-playing) all
/// adopt this. External apps still go through
/// `SuiteLiveActivityStore` (the on-disk JSON path).
@MainActor
protocol HaloPublisher: AnyObject {
    /// Slot id under which this publisher's payload appears.
    /// Convention: `halo.<feature>` (e.g. `halo.volume`).
    var id: String { get }
    /// Begin listening for the underlying system event.
    func start()
    /// Stop listening; clear any active payload.
    func stop()
}
