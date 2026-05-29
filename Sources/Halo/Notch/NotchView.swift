import SwiftUI

/// The Dynamic Island shape, constructed the way iOS does it:
///
///   • A central **pill body** — a plain rectangle (no top
///     rounding) with small rounded bottom corners.
///   • Two **side elements**, one each side of the pill, at the
///     very top. Each side element is a small black square with
///     a **circle punched out** of it; the remaining curved
///     wedge is what creates the visible concave transition
///     where the pill meets the screen edge above. The radius
///     belongs to the punch, not to the pill itself.
///
///        ─ screen edge ─
///       ╲┌─────────────┐╱   ← side elements with punched-out
///        │ ☕      1:23 │     circles → visible concave curves
///        ╰─────────────╯   ← regular small rounded bottom
struct NotchView: View {
    /// Currently-displayed activity from the coordinator's
    /// cycle — single slot at a time, swaps every 4s.
    var activity: LiveActivityCoordinator.Resolved?
    /// Every currently-active payload. Most of the renderer
    /// only cares about `activity` (the one being shown), but
    /// the expanded BatteryExpandedView needs to peek at the
    /// AirPods activity too so it can list every connected
    /// device in one place. Passed through to ExpandedCard.
    var allActivities: [LiveActivityCoordinator.Resolved] = []
    /// Coordinator's cycle index. Not used in rendering — it's
    /// here so SwiftUI re-evaluates the view when the index
    /// advances even if the underlying `activity` reference
    /// shape stays the same.
    var cycleSlot: Int = 0
    var layout: NotchLayout
    /// True once hover has held the island for ~1s. Drives
    /// the downward-expanded card layout.
    var isExpanded: Bool = false
    /// True the moment the cursor enters the island bounds
    /// (no debounce). Drives the gear button's fade-in so the
    /// settings affordance is reachable before the heavier
    /// expanded card has finished materialising.
    var isHovered: Bool = false
    /// Click-the-pill handler. `NotchHost` flips the panel's
    /// `ignoresMouseEvents` only when the cursor is inside the
    /// island so this tap only ever fires from a click ON the
    /// pill itself.
    var onTap: () -> Void = {}
    /// Open the slide-in settings drawer. Wired to the gear
    /// button rendered on hover and the right-click context
    /// menu's "Settings…" item.
    var onOpenSettings: () -> Void = {}

    /// Start of the visible trim window along the accent
    /// path. 0 = at the bottom-centre of the pill; 1 = at the
    /// screen's far edge. Animated **second**, after `traceTo`
    /// completes — the back end of the line then chases the
    /// front, "leaving" via the screen edges.
    @State private var traceFrom: Double = 0
    /// End of the visible trim window. 0 = at the
    /// bottom-centre; 1 = at the screen's far edge. Animated
    /// **first** — the front end of the line emanates outward
    /// to full extent before the back end starts moving.
    @State private var traceTo: Double = 0
    /// Colour of the line currently being drawn. Set inside
    /// `triggerBorderTrace`. Nil means we've never seen an
    /// activity yet.
    @State private var currentAccentColor: Color?
    /// Identifier for the in-flight trace. The trailing task
    /// that runs phase 2 checks this so a rapid second
    /// activity change doesn't have phase 2 from the old
    /// trace clobber the new one.
    @State private var traceToken: UUID = UUID()
    /// Last `cycleSlot` we saw, so we can tell whether an
    /// activity-id change came from a user tap-to-cycle
    /// (cycleSlot also advanced — no trace) or from a new
    /// publisher / priority shift (cycleSlot unchanged —
    /// play the trace-in → hold → trace-out animation).
    @State private var lastCycleSlot: Int = 0
    /// `id → last time it was the displayed activity`. Used
    /// to suppress the trace when an activity that just lost
    /// the slot quickly reclaims it (e.g. Espresso coming
    /// back after a 2.5s Worktree priority boost expires) —
    /// those aren't *new* arrivals from the user's point of
    /// view, just priority shuffles, so they shouldn't flash
    /// the accent line every time.
    @State private var recentlyShownAt: [String: Date] = [:]
    /// SwiftUI-measured natural height of the expanded
    /// card's content, published via `ExpandedCardHeightKey`
    /// from inside `ExpandedCard.body`. When > 0 it
    /// overrides the static `expandedExtraHeight` heuristic
    /// — the island shape and the NSPanel both size to
    /// exactly what the content needs. Resets to 0 on
    /// `activity.id` change so a stale value from the
    /// previous activity doesn't briefly mis-size the new
    /// card before its own measurement lands.
    @State private var measuredExpandedHeight: CGFloat = 0
    /// Optional callback bubbled up to NotchHost so the
    /// AppKit-side panel frame can match the measurement.
    var onMeasuredHeight: ((CGFloat) -> Void)? = nil

    /// Cheap "is the AirPods publisher also running?" check
    /// — passed into `Geometry.islandFrame` so the battery
    /// expanded card knows to reserve a row for the AirPods
    /// rollup even when its own activity payload doesn't
    /// carry the bud state.
    private var hasAirpodsActivity: Bool {
        allActivities.contains { $0.id == "halo.airpods" }
    }

    /// Default minimum sidePad — see `Geometry.sidePad`.
    private var sidePad: CGFloat { Geometry.sidePad }
    private var punchRadius: CGFloat { Geometry.punchRadius }
    private var bottomCornerRadius: CGFloat { Geometry.bottomCornerRadius }
    private var contentInset: CGFloat { Geometry.contentInset }
    private var notchClearance: CGFloat { Geometry.notchClearance }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let a = activity {
                // Both the pill and the screen-top accent live
                // inside this ZStack so they share a single
                // animation transaction. Applying the springs
                // here (rather than on each child) guarantees
                // that when `a.compactTrailingText`, `isExpanded`,
                // etc. change, SwiftUI kicks off ONE animation
                // covering both views — they then interpolate
                // their respective animatable values (the pill's
                // frame, the accent's `islandFrame`) on the
                // exact same clock, so the line tracks the pill
                // edge perfectly through every horizontal /
                // vertical resize.
                ZStack(alignment: .topLeading) {
                    island(for: a)
                    screenTopAccent(for: a)
                }
                .animation(.spring(response: 0.32,
                                   dampingFraction: 0.86),
                           value: a.id)
                .animation(.spring(response: 0.32,
                                   dampingFraction: 0.86),
                           value: a.compactTrailingText)
                .animation(.spring(response: 0.34,
                                   dampingFraction: 0.9),
                           value: isExpanded)
                .animation(.spring(response: 0.32,
                                   dampingFraction: 0.86),
                           value: cycleSlot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: activity?.id) { oldID, newID in
            let now = Date()
            // Whatever was just displayed is "recent" as of
            // now — mark it so a quick return to that id
            // (within `traceSilenceWindow`) is treated as a
            // priority shuffle, not a new arrival.
            if let oldID { recentlyShownAt[oldID] = now }
            guard let newID, activity != nil else { return }

            // 1) Skip on user tap-cycle (cycleSlot bumped).
            let isCycle = cycleSlot != lastCycleSlot
            lastCycleSlot = cycleSlot
            if isCycle { return }

            // 2) Skip when the new id was the displayed
            //    activity in the last few seconds (Espresso
            //    reclaiming after a Worktree boost, an item
            //    blipping in and out, etc).
            if let lastSeen = recentlyShownAt[newID],
               now.timeIntervalSince(lastSeen)
                    < Self.traceSilenceWindow {
                return
            }

            triggerBorderTrace()
        }
        .onChange(of: cycleSlot) { _, new in
            lastCycleSlot = new
        }
        .onChange(of: activity?.id) { _, _ in
            // Reset the measured height when the activity
            // changes so a stale value from the previous
            // card doesn't briefly mis-size the new one
            // before its own measurement lands.
            measuredExpandedHeight = 0
            onMeasuredHeight?(0)
        }
        .onChange(of: isExpanded) { _, expanded in
            // When the user un-hovers, the ExpandedCard
            // unmounts and the GeometryReader stops firing.
            // Reset the measured height so the island
            // collapses to the compact-pill size cleanly
            // and the panel shrinks back.
            if !expanded {
                measuredExpandedHeight = 0
                onMeasuredHeight?(0)
            }
        }
        .onPreferenceChange(ExpandedCardHeightKey.self) {
            height in
            // Skip zero-valued events — that's the
            // GeometryReader's defaultValue, not real data.
            guard height > 0 else { return }
            measuredExpandedHeight = height
            onMeasuredHeight?(height)
        }
        .onAppear {
            lastCycleSlot = cycleSlot
            if let id = activity?.id {
                recentlyShownAt[id] = Date()
                triggerBorderTrace()
            }
        }
    }

    /// Window after an activity leaves the slot during which
    /// a return to that activity is considered a priority
    /// shuffle (no trace), not a new arrival. Long enough to
    /// cover Worktree's 2.5s focus-boost and similar brief
    /// interruptions; short enough that an item legitimately
    /// disappearing and coming back many seconds later still
    /// gets a flash.
    private static let traceSilenceWindow: TimeInterval = 15

    @ViewBuilder
    private func screenTopAccent(
        for a: LiveActivityCoordinator.Resolved
    ) -> some View {
        // Single 1pt stroke per side. The path runs from the
        // pill's bottom-centre out to each screen edge,
        // hugging the island's contour through the bottom
        // corner, side, and concave bite before extending
        // along the screen's top edge.
        //
        // The visible window is `trim(from: traceFrom, to:
        // traceTo)`. Phase 1 advances `traceTo` from 0 to 1
        // (line emanates outward from the centre); phase 2
        // advances `traceFrom` from 0 to 1 (the back end of
        // the line then chases the front, the whole stroke
        // continuing outward and "leaving" via the screen
        // edges) — no rest in between, one fluid motion.
        //
        // Animation transactions live on the parent ZStack
        // alongside the pill, so the accent path's animatable
        // `islandFrame` morphs in the same clock as the pill's
        // `.frame()` — both interpolate together through any
        // width changes during the trace.
        let frame = Geometry.islandFrame(
            for: a, layout: layout, expanded: isExpanded,
            hasAirpods: hasAirpodsActivity,
            measuredExpandedHeight: measuredExpandedHeight)
        let stroke = StrokeStyle(
            lineWidth: 1,
            lineCap: .round,
            lineJoin: .round)
        ZStack {
            if let color = currentAccentColor {
                ScreenAccentTrace(
                    side: .right,
                    islandFrame: frame,
                    screenWidth: layout.screenWidth,
                    punchRadius: punchRadius,
                    bottomCornerRadius: bottomCornerRadius
                )
                .trim(from: traceFrom, to: traceTo)
                .stroke(color, style: stroke)
                ScreenAccentTrace(
                    side: .left,
                    islandFrame: frame,
                    screenWidth: layout.screenWidth,
                    punchRadius: punchRadius,
                    bottomCornerRadius: bottomCornerRadius
                )
                .trim(from: traceFrom, to: traceTo)
                .stroke(color, style: stroke)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func island(
        for a: LiveActivityCoordinator.Resolved
    ) -> some View {
        let frame = Geometry.islandFrame(
            for: a, layout: layout, expanded: isExpanded,
            hasAirpods: hasAirpodsActivity,
            measuredExpandedHeight: measuredExpandedHeight)
        let totalWidth = frame.width
        let totalHeight = frame.height
        let centerX = frame.midX

        let notchW = layout.notchTrailingX - layout.notchLeadingX
        let compactRowHeight = layout.menuBarHeight + 1

        ZStack(alignment: .top) {
            IslandShape(
                punchRadius: punchRadius,
                bottomCornerRadius: bottomCornerRadius
            )
            .fill(Color.black)
            .frame(width: totalWidth, height: totalHeight)

            VStack(spacing: 0) {
                // Compact row — always reserves its space so
                // the notch geometry stays put, but its content
                // fades out when expanded so the user doesn't
                // see the same info twice (icon + album cover,
                // time-readout + scrubber, etc).
                HStack(spacing: 0) {
                    leadingContent(for: a)
                    Spacer(minLength: notchW + notchClearance * 2)
                    trailingContent(for: a)
                }
                .padding(.horizontal, contentInset)
                .frame(width: totalWidth, height: compactRowHeight)
                .opacity(isExpanded ? 0 : 1)

                if isExpanded {
                    ExpandedCard(
                        activity: a,
                        allActivities: allActivities)
                        .frame(width: totalWidth,
                               height: totalHeight - compactRowHeight,
                               alignment: .top)
                        .transition(.opacity.combined(
                            with: .move(edge: .top)))
                }
            }
            .frame(width: totalWidth, height: totalHeight,
                   alignment: .top)
            // Belt-and-braces: clip the VStack to the island
            // path so a brief mismatch between measured height
            // and laid-out content (e.g. during the expand
            // spring) can never paint UI past the visible
            // dark surface. Worktree's section list used to
            // bleed a folder row below the IslandShape's
            // bottom edge during transitions before this clip.
            .clipShape(IslandShape(
                punchRadius: punchRadius,
                bottomCornerRadius: bottomCornerRadius))

            // Settings cog — fades in as soon as the cursor
            // (No in-island gear button — settings are reached
            // ONLY via the right-click context menu on the
            // pill so the island stays uncluttered.)
        }
        .frame(width: totalWidth, height: totalHeight)
        .position(x: centerX, y: totalHeight / 2)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .contextMenu {
            Button {
                onOpenSettings()
            } label: {
                Label("Settings…",
                      systemImage: "gearshape")
            }
            Divider()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Halo",
                      systemImage: "power")
            }
        }
    }

    /// Kick off the screen-top accent: trace grows from 0 to
    /// 1 over ~0.9s and then **stays drawn**. The previous
    /// accent's colour is held under the new trace at full
    /// opacity / full progress so the new line paints over it
    /// from the bottom-centre out, rather than flashing
    /// through a blank top edge. The underlay is dropped a
    /// little after the new trace completes — `traceToken`
    /// guards against a rapid second change wiping out an
    /// underlay the next trace still needs.
    ///
    /// While the user is hovering the island we keep the
    /// trace target at 0 (line sucked in toward the centre)
    /// so the visible UI is the expanded card alone, not the
    /// card with a competing accent line. The line bounces
    /// back out the next time the cursor leaves, via
    /// `animateHoverAccent`.
    /// Play the new-item accent animation as a single fluid
    /// motion: the line emanates from the bottom-centre out
    /// to the screen edges (phase 1), then the back end of
    /// the line continues outward along the same path,
    /// "leaving" via the edges (phase 2). The two phases run
    /// back-to-back with no hold between them, so the trim
    /// window slides outward at a constant speed.
    ///
    /// Only fired by `.onChange(of: activity?.id)` when the
    /// id change was *not* a user tap-cycle (those are
    /// silent).
    private func triggerBorderTrace() {
        guard let a = activity else { return }
        currentAccentColor = Self.accentColor(for: a)
        let token = UUID()
        traceToken = token
        traceFrom = 0
        traceTo = 0
        let phase1Seconds: Double = 0.9
        let phase2Seconds: Double = 0.9
        // Phase 1 — the leading edge sweeps from centre out to
        // each screen edge. Linear so the speed matches phase 2.
        withAnimation(.linear(duration: phase1Seconds)) {
            traceTo = 1
        }
        // Phase 2 — the trailing edge does the same sweep at
        // the same speed, eating the line from the centre
        // outward until it's gone. Kicks off the instant
        // phase 1 finishes.
        Task { @MainActor in
            let waitNanos = UInt64(
                phase1Seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: waitNanos)
            guard traceToken == token else { return }
            withAnimation(.linear(duration: phase2Seconds)) {
                traceFrom = 1
            }
        }
    }
}
