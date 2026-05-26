import AppKit
import Combine
import Observation
import SuiteKit
import SwiftUI

/// Reads suite-wide live-activity payloads from the shared on-disk
/// store and exposes the highest-priority one for the island UI to
/// render. Single source of truth for "what is the island showing
/// right now."
///
/// Halo runs in its own process, so it can't see in-memory pane
/// state (Espresso's `EspressoStore.active`, Worktree's snapshot,
/// etc.). Every publisher writes its payload to a JSON file under
/// `~/Library/Application Support/MattsSoftware/live-activity/`
/// and we poll the directory at 1 Hz. Cheap, durable, debuggable
/// (`cat espresso.json` shows the live state), and survives
/// either side restarting.
@MainActor
@Observable
final class LiveActivityCoordinator {

    /// Normalised activity ready for the UI. The store's JSON
    /// `Payload` reduces to this shape — SF Symbol names get
    /// resolved into template NSImages on this side so the
    /// renderer stays uniform.
    struct Resolved: Identifiable, Equatable {
        let id: String
        let compactLeadingImage: NSImage?
        let compactTrailingText: String?
        let compactTrailingImage: NSImage?
        let tint: Color
        let priority: Int

        static func == (l: Resolved, r: Resolved) -> Bool {
            l.id == r.id &&
            l.compactTrailingText == r.compactTrailingText &&
            l.priority == r.priority &&
            l.tint == r.tint
        }
    }

    /// All currently-active payloads, high → low priority.
    private(set) var activities: [Resolved] = []

    /// Index of the activity currently on display. Advances on
    /// a fixed cadence so the island cycles through every
    /// active publisher rather than parking on the single
    /// highest-priority one.
    private(set) var cycleIndex: Int = 0

    /// The activity the island should render right now —
    /// cycle-aware. Falls back to the first activity if the
    /// index has drifted past the end of the array (which can
    /// happen between a tick and the next `pollOnce`).
    var topActivity: Resolved? {
        guard !activities.isEmpty else { return nil }
        let safe = activities.indices.contains(cycleIndex)
            ? cycleIndex : 0
        return activities[safe]
    }

    /// Payloads older than this are treated as stale (writer
    /// crashed without clearing) and ignored. 30s is long enough
    /// for Espresso's 1 Hz updates to never trip it, short enough
    /// that a dead writer falls off within a sensible window.
    @ObservationIgnored private let payloadTTL: TimeInterval = 30
    @ObservationIgnored private var pollTimer: Timer?
    /// Cycle through active publishers at this cadence so the
    /// user sees every pill rather than parking on the single
    /// highest-priority one. 4s feels right — long enough to
    /// read each, short enough that you don't miss anything
    /// during a casual glance at the menu bar.
    @ObservationIgnored private let cycleInterval: TimeInterval = 4
    @ObservationIgnored private var cycleTimer: Timer?

    /// In-process payloads — Halo's own publishers (volume,
    /// brightness, now-playing) write here directly instead of
    /// round-tripping through the file store. Updates are
    /// instant; no 1 Hz disk poll, no TTL drift.
    @ObservationIgnored private var inProcess: [String: Resolved] = [:]
    /// Expiry dates for transient in-process payloads (volume
    /// HUDs etc.). `.distantFuture` for steady-state payloads.
    @ObservationIgnored private var inProcessExpiry: [String: Date] = [:]

    func start() {
        pollOnce()
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.pollOnce() }
        }
        cycleTimer = Timer.scheduledTimer(
            withTimeInterval: cycleInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.advanceCycle() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        cycleTimer?.invalidate()
        cycleTimer = nil
    }

    /// Advance to the next active publisher. No-op when the
    /// list is empty or has only one item. Triggers an
    /// `activities` mutation indirectly so `@Observable`
    /// downstream views re-render.
    private func advanceCycle() {
        guard activities.count > 1 else { return }
        cycleIndex = (cycleIndex + 1) % activities.count
        // Re-publishing the array nudges @Observable to fire.
        let snapshot = activities
        activities = snapshot
    }

    /// User-initiated cycle advance (click on the island).
    /// Same logic as the timer but ALSO resets the 4s
    /// auto-cycle clock so the next auto-advance comes a full
    /// interval after the manual click — feels right when you
    /// tap-tap-tap to step through.
    func advanceCycleManually() {
        advanceCycle()
        cycleTimer?.invalidate()
        cycleTimer = Timer.scheduledTimer(
            withTimeInterval: cycleInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.advanceCycle() }
        }
    }

    /// Force an immediate re-poll. Used by settings toggles
    /// that change which suite slots are visible — without it
    /// the change waits up to 1s for the next scheduled tick.
    func refreshNow() {
        pollOnce()
    }

    // MARK: - In-process injection

    /// Publish a payload owned by an in-process publisher (volume
    /// HUD, music now-playing, etc.). `ttl` is measured from now;
    /// pass `.infinity` for steady-state payloads. Re-publishing
    /// the same `id` replaces the previous payload and resets
    /// the expiry clock.
    func inject(
        _ payload: Resolved,
        ttl: TimeInterval = .infinity
    ) {
        inProcess[payload.id] = payload
        inProcessExpiry[payload.id] =
            ttl.isFinite ? Date().addingTimeInterval(ttl) : .distantFuture
        pollOnce()
    }

    /// Withdraw an in-process payload (publisher went idle).
    func clear(id: String) {
        inProcess.removeValue(forKey: id)
        inProcessExpiry.removeValue(forKey: id)
        pollOnce()
    }

    // MARK: - Polling

    private func pollOnce() {
        // Drop expired in-process payloads (e.g. the 2s volume
        // HUD that has run its course).
        let now = Date()
        for (id, expiry) in inProcessExpiry where expiry < now {
            inProcess.removeValue(forKey: id)
            inProcessExpiry.removeValue(forKey: id)
        }
        // Merge: file-store payloads + in-process payloads.
        // In-process wins on id collision (Halo's own publisher
        // is authoritative over a stale file on disk).
        var byId: [String: Resolved] = [:]
        for r in readSharedStore() { byId[r.id] = r }
        for (id, r) in inProcess { byId[id] = r }

        let collected = byId.values.sorted {
            // Stable sort: priority desc, then id asc — ties
            // don't flicker frame-to-frame.
            if $0.priority != $1.priority {
                return $0.priority > $1.priority
            }
            return $0.id < $1.id
        }
        if collected != activities {
            NSLog("[halo] activities changed: \(activities.count) → \(collected.count) (top=\(collected.first?.id ?? "—"))")
            // Transient HUDs (priority ≥ 90) interrupt the
            // cycle so volume / brightness HUDs appear the
            // instant they fire — not on the next 4s tick.
            // The new arrival is whatever wasn't in `activities`
            // before; if its priority is high enough, jump to it.
            let oldIDs = Set(activities.map(\.id))
            let arrivals = collected.filter { !oldIDs.contains($0.id) }
            if let urgent = arrivals.first(where: { $0.priority >= 90 }),
               let idx = collected.firstIndex(where: { $0.id == urgent.id }) {
                cycleIndex = idx
            } else if !collected.indices.contains(cycleIndex) {
                cycleIndex = 0
            }
            activities = collected
        }
    }

    private func readSharedStore() -> [Resolved] {
        let fm = FileManager.default
        let dir = SuiteLiveActivityStore.directory
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else { return [] }
        let now = Date().timeIntervalSince1970
        var out: [Resolved] = []
        for url in entries where url.pathExtension == "json" {
            let id = url.deletingPathExtension().lastPathComponent
            // Honour the user's per-slot visibility toggle —
            // a publisher whose file is on disk but whose
            // settings flag is off is treated as if it
            // weren't publishing at all.
            if !HaloSettings.suiteSlotEnabled(id) { continue }
            guard let data = try? Data(contentsOf: url),
                  let p = try? JSONDecoder().decode(
                    SuiteLiveActivityStore.Payload.self, from: data)
            else { continue }
            if now - p.updatedAt > payloadTTL { continue }
            out.append(Resolved(
                id: id,
                compactLeadingImage: Self.symbolImage(p.compactLeadingSymbol),
                compactTrailingText: p.compactTrailingText,
                compactTrailingImage: Self.symbolImage(p.compactTrailingSymbol),
                tint: Self.color(hex: p.tintHex),
                priority: p.priority
            ))
        }
        return out
    }

    // MARK: - Helpers

    /// "#RRGGBB" → Color. Falls back to white for unparseable hex.
    private static func color(hex: String) -> Color {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            return .white
        }
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    /// Resolve an SF Symbol name to a tintable template NSImage.
    /// Exposed so in-process publishers (`VolumePublisher` etc.)
    /// can build payloads without each importing AppKit symbols
    /// piecemeal.
    static func symbolImage(_ name: String?) -> NSImage? {
        guard let name, !name.isEmpty,
              let img = NSImage(systemSymbolName: name,
                                accessibilityDescription: nil)
        else { return nil }
        img.isTemplate = true
        return img
    }
}

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
