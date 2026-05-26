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
        /// Optional rich-media payload — present only for
        /// Now Playing. Drives the expanded card's artwork +
        /// scrubber + controls.
        let media: MediaInfo?
        /// Optional Worktree-specific payload — populated only
        /// for the `worktree` slot. Drives the branch-switcher
        /// dropdown in the expanded card.
        let worktree: WorktreeInfo?

        init(
            id: String,
            compactLeadingImage: NSImage?,
            compactTrailingText: String?,
            compactTrailingImage: NSImage?,
            tint: Color,
            priority: Int,
            media: MediaInfo? = nil,
            worktree: WorktreeInfo? = nil
        ) {
            self.id = id
            self.compactLeadingImage = compactLeadingImage
            self.compactTrailingText = compactTrailingText
            self.compactTrailingImage = compactTrailingImage
            self.tint = tint
            self.priority = priority
            self.media = media
            self.worktree = worktree
        }

        static func == (l: Resolved, r: Resolved) -> Bool {
            l.id == r.id &&
            l.compactTrailingText == r.compactTrailingText &&
            l.priority == r.priority &&
            l.tint == r.tint &&
            l.media?.title == r.media?.title &&
            l.media?.isPlaying == r.media?.isPlaying &&
            l.worktree?.currentBranch == r.worktree?.currentBranch &&
            l.worktree?.branches == r.worktree?.branches &&
            l.worktree?.isDirty == r.worktree?.isDirty
        }
    }

    /// Branch-switch payload Halo decodes from `worktree.json`.
    struct WorktreeInfo: Equatable {
        let repoPath: String
        let currentBranch: String
        let branches: [String]
        let isDirty: Bool
    }

    /// Rich Now Playing payload. Position / duration are in
    /// seconds; artwork is the raw track image (album cover).
    /// `source` describes who's playing (Spotify / Music /
    /// MediaRemote) so the expanded view can route control
    /// commands back through the right AppleScript app.
    struct MediaInfo: Equatable {
        let title: String
        let artist: String?
        let album: String?
        let artwork: NSImage?
        let positionSeconds: Double?
        let durationSeconds: Double?
        let isPlaying: Bool
        let source: String

        static func == (l: MediaInfo, r: MediaInfo) -> Bool {
            // Skip artwork pixel comparison (slow + NSImage
            // doesn't conform to Equatable). Title + source +
            // isPlaying covers track changes; positions are
            // refreshed via the expanded view's own timer.
            l.title == r.title &&
            l.artist == r.artist &&
            l.source == r.source &&
            l.isPlaying == r.isPlaying
        }
    }

    /// All currently-active payloads, high → low priority.
    private(set) var activities: [Resolved] = []

    /// Generation counter used purely as an animation key — the
    /// SwiftUI view re-evaluates when this changes so the
    /// island transitions smoothly between focus changes.
    private(set) var cycleIndex: Int = 0

    /// Position within `activities` for the ambient round-robin.
    /// Advanced by `ambientTimer` on a regular cadence whenever
    /// nothing's currently locked / focused, so the user sees
    /// every active publisher in turn instead of being parked
    /// on whoever has the top priority (typically Espresso).
    @ObservationIgnored private var ambientCursor: Int = 0
    @ObservationIgnored private var ambientTimer: Timer?
    /// Seconds the slot holds on a given publisher in ambient
    /// rotation before advancing to the next one.
    @ObservationIgnored
        private let ambientRotateInterval: TimeInterval = 7

    /// The activity the island should render right now. Three-
    /// tier selection:
    ///   1. **User-locked** — the publisher the user manually
    ///      navigated to via tap, pinned for `userLockDuration`
    ///      seconds. Overrides everything else.
    ///   2. **Focused** — any publisher inside its post-event
    ///      focus window (text just changed, just appeared,
    ///      transient HUD fired). Most-recent focus wins ties.
    ///   3. **Ambient** — when nothing's focused, the highest-
    ///      priority steady-state payload (Now Playing,
    ///      Espresso ON, Worktree presence, etc.).
    /// Returns nil only when no publisher is active at all.
    var topActivity: Resolved? {
        guard !activities.isEmpty else { return nil }
        let now = Date()
        if let lockedID = userLockedID,
           let until = userLockUntil, until > now,
           let pinned = activities.first(where: { $0.id == lockedID }) {
            return pinned
        }
        // Hover lock: while the cursor is over the island,
        // freeze the slot on whatever was showing when hover
        // began. Outranks focus events and ambient rotation
        // so a publisher firing a focus window mid-hover
        // can't yank the displayed activity out from under
        // the user.
        if let hoverID = hoverLockedID,
           let pinned = activities.first(where: { $0.id == hoverID }) {
            return pinned
        }
        let focused = activities
            .compactMap { a -> (Resolved, Date)? in
                guard let until = focusUntil[a.id], until > now
                else { return nil }
                return (a, until)
            }
            .sorted { $0.1 > $1.1 }
        if let first = focused.first { return first.0 }
        // Ambient: rotate through every active publisher
        // (Espresso, Worktree, Port, …) on a steady cadence
        // instead of parking on `activities.first` (whoever
        // has the top priority). The user can still tap to
        // jump straight to a specific one — that path goes
        // through the user-lock branch above.
        return activities[ambientCursor % activities.count]
    }

    /// Payloads older than this are treated as stale (writer
    /// crashed without clearing) and ignored. 30s is long enough
    /// for Espresso's 1 Hz updates to never trip it, short enough
    /// that a dead writer falls off within a sensible window.
    @ObservationIgnored private let payloadTTL: TimeInterval = 30
    @ObservationIgnored private var pollTimer: Timer?

    // MARK: Context-aware focus

    /// How long an activity stays "fresh" / focused after a
    /// meaningful state change. Long enough to read; short
    /// enough that incidental changes don't hog the slot.
    @ObservationIgnored private let focusDuration: TimeInterval = 4
    /// Per-id focus-window override. Camera / mic going active
    /// is a privacy moment — give Peephole a longer guaranteed
    /// slot (5s) before the rotation can advance past it.
    @ObservationIgnored
        private let focusDurationOverrides: [String: TimeInterval] = [
            "peephole": 5,
        ]
    /// Don't treat a text change as a focus-worthy event if it
    /// happened within this window of the previous update —
    /// that's how a 1Hz countdown (Espresso) avoids
    /// permanently grabbing focus.
    @ObservationIgnored private let rapidUpdateWindow: TimeInterval = 2

    /// Last-seen compactTrailingText per id, so we can detect
    /// when a publisher's value has changed.
    @ObservationIgnored private var lastText: [String: String?] = [:]
    /// Time of the previous update per id, used by the rapid-
    /// update heuristic.
    @ObservationIgnored private var lastUpdateAt: [String: Date] = [:]
    /// "I want the slot until …" timestamp per id. Set on
    /// arrival or on a non-rapid text change; consulted by
    /// `topActivity` to decide who shows.
    @ObservationIgnored private var focusUntil: [String: Date] = [:]

    // MARK: User attention lock

    /// When the user taps the pill we pin display to that
    /// publisher for `userLockDuration` and suppress focus
    /// events from *other* publishers during the lock. Stops
    /// (e.g.) Espresso's state-change pulls from yanking the
    /// user back the moment they've navigated away.
    @ObservationIgnored private var userLockedID: String?
    @ObservationIgnored private var userLockUntil: Date?
    @ObservationIgnored private let userLockDuration: TimeInterval = 15

    /// While the cursor is over the island we freeze the slot
    /// on whatever activity was showing the moment hover
    /// began. The ambient rotation timer is torn down for the
    /// duration and re-created fresh on un-hover, so the
    /// next rotation tick is a full `ambientRotateInterval`
    /// away rather than firing the instant the cursor leaves.
    @ObservationIgnored private var hoverLockedID: String?

    /// In-process payloads — Halo's own publishers (volume,
    /// brightness, now-playing) write here directly instead of
    /// round-tripping through the file store. Updates are
    /// instant; no 1 Hz disk poll, no TTL drift.
    @ObservationIgnored private var inProcess: [String: Resolved] = [:]
    /// Expiry dates for transient in-process payloads (volume
    /// HUDs etc.). `.distantFuture` for steady-state payloads.
    @ObservationIgnored private var inProcessExpiry: [String: Date] = [:]

    @ObservationIgnored private var refreshObserver: NSObjectProtocol?

    func start() {
        pollOnce()
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.pollOnce() }
        }
        startAmbientTimer()
        // Publishers post this distributed notification right
        // after writing — gives us instant refresh instead of
        // waiting up to a second for the next polling tick.
        refreshObserver = DistributedNotificationCenter.default()
            .addObserver(
                forName: Notification.Name(
                    "com.mattssoftware.halo.refresh"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.pollOnce() }
            }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        ambientTimer?.invalidate()
        ambientTimer = nil
        if let o = refreshObserver {
            DistributedNotificationCenter.default()
                .removeObserver(o)
            refreshObserver = nil
        }
    }

    /// Hover state from `HoverTracker`. When the cursor
    /// enters the island, freeze the slot on whatever was
    /// showing and stop the rotation timer entirely. On exit,
    /// release the lock and re-arm the timer with a fresh
    /// full interval — so the user doesn't get a rotation the
    /// instant they move their cursor away.
    func setHoverActive(_ active: Bool) {
        if active {
            hoverLockedID = topActivity?.id
            ambientTimer?.invalidate()
            ambientTimer = nil
        } else {
            hoverLockedID = nil
            startAmbientTimer()
            // Force SwiftUI to re-evaluate `topActivity` now
            // that the hover lock is released — the displayed
            // activity might want to advance to whatever the
            // ambient cursor / focus state now resolves to.
            let snapshot = activities
            activities = snapshot
        }
    }

    private func startAmbientTimer() {
        ambientTimer?.invalidate()
        ambientTimer = Timer.scheduledTimer(
            withTimeInterval: ambientRotateInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.rotateAmbient() }
        }
    }

    /// Step `ambientCursor` to the next active publisher,
    /// skipping if we'd be stealing the slot from a user
    /// lock or a publisher that's mid-focus-window. Bumps
    /// `cycleIndex` so SwiftUI re-evaluates `topActivity`
    /// AND so `NotchView` recognises the change as a cycle
    /// (silent) rather than a new-arrival (traces the
    /// accent line).
    private func rotateAmbient() {
        guard activities.count > 1 else { return }
        let now = Date()
        if let until = userLockUntil, until > now { return }
        if focusUntil.contains(where: { $0.value > now }) {
            return
        }
        ambientCursor &+= 1
        cycleIndex &+= 1
        // Nudge @Observable so SwiftUI re-reads topActivity
        // even though `activities` is unchanged in identity.
        let snapshot = activities
        activities = snapshot
    }

    /// User-initiated step through the active set. Picks the
    /// activity AFTER whatever's currently displayed and pins
    /// it via the user-lock for `userLockDuration` seconds.
    /// During that window other publishers can still update
    /// their data, but they CAN'T grab focus — the user just
    /// said "I want this one," we respect it.
    func advanceCycleManually() {
        guard activities.count > 1 else { return }
        let currentID = topActivity?.id
        let currentIdx = activities.firstIndex {
            $0.id == currentID
        } ?? -1
        let nextIdx = (currentIdx + 1) % activities.count
        let next = activities[nextIdx]
        // Sync the ambient cursor too, so when the user lock
        // expires we don't snap back to wherever ambient was
        // before the tap — the next ambient tick advances
        // from the user's chosen position instead.
        ambientCursor = nextIdx
        userLockedID = next.id
        userLockUntil = Date().addingTimeInterval(userLockDuration)
        cycleIndex &+= 1
        // Nudge @Observable to fire.
        let snapshot = activities
        activities = snapshot
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

        // Per-activity change detection. A new arrival OR a
        // text change OUTSIDE the rapid-update window is a
        // focus-worthy event; the publisher takes the slot
        // for `focusDuration` seconds.
        //
        // Rapid changes (1Hz countdown text) don't grab focus
        // — that's what `rapidUpdateWindow` shields against.
        //
        // During a user lock (after a manual tap) only the
        // locked publisher can grab focus. Everyone else's
        // updates are silent — they still write to lastText
        // so we don't fire a stale "change" when the lock
        // releases, but we don't extend focusUntil for them.
        let isLocked = (userLockUntil ?? .distantPast) > now
        for a in collected {
            let isNew = !lastText.keys.contains(a.id)
            let prevText = lastText[a.id] ?? nil
            let prevUpdate = lastUpdateAt[a.id] ?? .distantPast
            let textChanged = prevText != a.compactTrailingText
            let isRapid =
                now.timeIntervalSince(prevUpdate) < rapidUpdateWindow
            let canFocus = !isLocked || a.id == userLockedID

            if canFocus && (isNew || (textChanged && !isRapid)) {
                let duration = focusDurationOverrides[a.id]
                    ?? focusDuration
                focusUntil[a.id] = now
                    .addingTimeInterval(duration)
            }
            lastText[a.id] = a.compactTrailingText
            lastUpdateAt[a.id] = now
        }
        // Clean up bookkeeping for activities no longer
        // active so memory doesn't grow unbounded.
        let activeIDs = Set(collected.map(\.id))
        for id in Array(lastText.keys) where !activeIDs.contains(id) {
            lastText.removeValue(forKey: id)
            lastUpdateAt.removeValue(forKey: id)
            focusUntil.removeValue(forKey: id)
        }

        if collected != activities {
            NSLog("[halo] activities changed: \(activities.count) → \(collected.count)")
            activities = collected
        } else if !focusUntil.isEmpty {
            // Activities array identical but a focus window
            // may have just opened/closed — force re-publish
            // so SwiftUI re-evaluates `topActivity`.
            let snapshot = activities
            activities = snapshot
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
            let worktreeInfo = p.worktree.map { w in
                WorktreeInfo(
                    repoPath: w.repoPath,
                    currentBranch: w.currentBranch,
                    branches: w.branches,
                    isDirty: w.isDirty)
            }
            out.append(Resolved(
                id: id,
                compactLeadingImage: Self.symbolImage(p.compactLeadingSymbol),
                compactTrailingText: p.compactTrailingText,
                compactTrailingImage: Self.symbolImage(p.compactTrailingSymbol),
                tint: Self.color(hex: p.tintHex),
                priority: p.priority,
                worktree: worktreeInfo
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

    /// Resolve an SF Symbol name (or one of Halo's bundled
    /// brand glyphs) to a tintable template NSImage. Exposed
    /// so in-process publishers (`VolumePublisher` etc.) can
    /// build payloads without each importing AppKit symbols
    /// piecemeal.
    ///
    /// Special names mapped to bundled assets:
    ///   • `"worktree.git"` → official Git logo at
    ///     `Resources/WorktreeGit.png` (CC BY 3.0, Jason Long).
    /// Anything else is treated as an SF Symbol name.
    static func symbolImage(_ name: String?) -> NSImage? {
        guard let name, !name.isEmpty else { return nil }
        if let bundled = bundledBrandImage(name) { return bundled }
        guard let img = NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil)
        else { return nil }
        img.isTemplate = true
        return img
    }

    private static func bundledBrandImage(_ name: String) -> NSImage? {
        switch name {
        case "worktree.git":
            return loadBundled("WorktreeGit")
        default:
            return nil
        }
    }

    /// Load a PNG from `Resources/`, normalise its draw size,
    /// and mark it template so it tints to match the other SF
    /// Symbols on the pill.
    private static func loadBundled(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url)
        else { return nil }
        img.size = NSSize(width: 20, height: 20)
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
