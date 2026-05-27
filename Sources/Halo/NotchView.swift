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
    /// Click-the-pill handler. `NotchHost` flips the panel's
    /// `ignoresMouseEvents` only when the cursor is inside the
    /// island so this tap only ever fires from a click ON the
    /// pill itself.
    var onTap: () -> Void = {}

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
            hasAirpods: hasAirpodsActivity)
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
            hasAirpods: hasAirpodsActivity)
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
        }
        .frame(width: totalWidth, height: totalHeight)
        .position(x: centerX, y: totalHeight / 2)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
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

    /// Per-publisher accent. Prefers the activity's declared
    /// tint (file-store publishers set it via tintHex); falls
    /// back to a hand-picked brand color for built-in
    /// publishers that publish white. The now-playing accent
    /// is further routed through the source app so Spotify
    /// pulls green, Apple Music pulls red, etc — the line
    /// then mirrors whichever app the user is actually
    /// listening to.
    private static func accentColor(
        for a: LiveActivityCoordinator.Resolved
    ) -> Color {
        if a.id == "halo.nowplaying", let media = a.media {
            return mediaSourceColor(media.source)
        }
        // The compact pill tint is white across publishers —
        // detect that and route to the per-id brand color.
        if let brand = brandColor(forID: a.id) { return brand }
        return a.tint
    }

    /// Brand colour for the app currently driving the
    /// now-playing pill. `source` matches the string the
    /// scripters / MediaRemote bridge sets on `MediaInfo`.
    /// Unknown sources fall back to the generic music pink.
    private static func mediaSourceColor(_ source: String) -> Color {
        switch source {
        case "Spotify":
            // Spotify green (#1DB954).
            return Color(red: 0.11, green: 0.73, blue: 0.33)
        case "Music":
            // Apple Music red (#FA243C).
            return Color(red: 0.98, green: 0.14, blue: 0.24)
        case "MediaRemote":
            // Generic media bridge — we don't know who's
            // playing. Use the original neutral music pink so
            // the pill stays branded as "audio" rather than
            // jumping colours per track.
            return Color(red: 0.96, green: 0.41, blue: 0.62)
        default:
            return Color(red: 0.96, green: 0.41, blue: 0.62)
        }
    }

    /// Default brand-tint used for the leading icon, the
    /// trailing text, and the time read-out in the expanded
    /// music card. Most activities return the publisher's
    /// brand colour straight up — see `pillIconColor` /
    /// `pillTrailingTextColor` for the per-id overrides.
    static func pillTextColor(
        for a: LiveActivityCoordinator.Resolved
    ) -> Color {
        accentColor(for: a)
    }

    /// Tint for the leading-pill icon and the expanded-card
    /// header glyph. Same as the publisher's brand colour
    /// for most apps; Worktree overrides to the Git brand
    /// orange `#F1502F` so the official Jason Long logo
    /// reads in its native colour instead of being painted
    /// over with the worktree-green hex.
    static func pillIconColor(
        for a: LiveActivityCoordinator.Resolved
    ) -> Color {
        if a.id == "worktree" { return gitBrandColor }
        return pillTextColor(for: a)
    }

    /// Colour for the compact pill's trailing data text.
    /// Same brand colour as the icon for most apps; Worktree's
    /// branch name stays white because it's primary data
    /// (the thing the user actually reads) and matching the
    /// rest of the suite's "white primary text" convention
    /// keeps the glance hierarchy consistent.
    static func pillTrailingTextColor(
        for a: LiveActivityCoordinator.Resolved
    ) -> Color {
        if a.id == "worktree" { return .white }
        return pillTextColor(for: a)
    }

    /// The official Git logo colour
    /// ([git-scm.com](https://git-scm.com)), used so the
    /// Jason Long Git icon reads in its native palette
    /// rather than tinted to match the worktree-green
    /// hex.
    private static let gitBrandColor = Color(
        red: 0.945, green: 0.314, blue: 0.184)

    private static func brandColor(forID id: String) -> Color? {
        switch id {
        // System HUDs match the system bezel's monochrome
        // palette — the digit + icon + accent trace all read
        // as one neutral overlay on top of the menu bar.
        // Coloured pills are reserved for app activities
        // (Espresso tan, Worktree green, etc).
        case "halo.volume":     return .white
        case "halo.brightness": return .white
        case "halo.nowplaying": return Color(red: 0.96, green: 0.41, blue: 0.62)
        case "halo.airpods":    return Color(red: 0.78, green: 0.78, blue: 0.82)
        case "halo.bluetoothaudio":
                                return Color(red: 0.36, green: 0.66, blue: 1.00)
        case "halo.stats":      return Color(red: 0.35, green: 0.83, blue: 0.85)
        case "halo.battery":    return Color(red: 0.30, green: 0.83, blue: 0.50)
        case "halo.vpn":        return Color(red: 0.30, green: 0.83, blue: 0.50)
        case "halo.calendar":   return Color(red: 1.00, green: 0.36, blue: 0.34)
        case "halo.github":     return Color(red: 0.55, green: 0.45, blue: 0.95)
        case "halo.docker":     return Color(red: 0.07, green: 0.56, blue: 0.91)
        // Suite-app publishers already carry a brand tint via
        // tintHex; fall through to use `activity.tint`.
        default:                return nil
        }
    }


    @ViewBuilder
    private func leadingContent(
        for a: LiveActivityCoordinator.Resolved
    ) -> some View {
        if let artwork = a.media?.artwork {
            // Album cover + song title side by side. The
            // cover stays the same small rounded thumbnail
            // (reads like a Spotify / Music card); the title
            // sits in the publisher's brand colour so the
            // pill reads as "this song from this app" at a
            // glance.
            HStack(spacing: 6) {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(
                        cornerRadius: 3,
                        style: .continuous))
                if let title = a.media?.title,
                   !title.isEmpty {
                    // Cap at 120pt and ping-pong if the title
                    // doesn't fit — long track names ("I Had
                    // Some Help (Feat. Morgan Wallen)") used
                    // to push the pill across the screen.
                    // Title stays white so it reads as the
                    // primary data; the source-app tint
                    // belongs on the icons / time read-out.
                    MarqueeText(
                        text: title,
                        font: .system(size: 13,
                                      weight: .medium),
                        fontSize: 13,
                        color: .white,
                        maxWidth: 120)
                }
            }
            .id("lead-art-\(a.media?.title ?? "")")
            .transition(.opacity)
        } else if a.id == "worktree",
                  let info = a.worktree,
                  let img = a.compactLeadingImage {
            // Worktree splits its label across both wings:
            // Git icon + project name on the LEFT (data the
            // user reads first — which repo am I in?), branch
            // name on the RIGHT (data they act on — what
            // branch?). Same layout pattern as Now Playing's
            // artwork + title.
            let projectName = info.displayName
                ?? ((info.repoPath as NSString)
                        .lastPathComponent)
            HStack(spacing: 6) {
                Image(nsImage: tintImage(
                    img, color: Self.pillIconColor(for: a)))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .opacity(0.9)
                Text(projectName)
                    .font(.system(size: 13,
                                  weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 140,
                           alignment: .leading)
            }
            .id("lead-worktree-\(projectName)")
            .animation(nil, value: a.compactTrailingText)
        } else if let img = a.compactLeadingImage {
            // Tinted-near-white scheme — each pill picks up a
            // hint of its publisher's brand colour (Espresso
            // tan, Spotify green, etc.) without losing the
            // readable B&W feel. 90% opacity so the icon reads
            // as supporting content next to the 100% trailing
            // text.
            //
            // `tintImage` builds a fresh NSImage every render,
            // so when the trailing text ticks (Espresso's 1Hz
            // countdown) the parent's spring would otherwise
            // crossfade the icon — that read as the icon
            // "flashing" on every second. Opt out of that
            // animation explicitly; the icon itself doesn't
            // need to animate on text changes.
            Image(nsImage: tintImage(
                img, color: Self.pillIconColor(for: a)))
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .opacity(0.9)
                .id("lead-\(a.id)")
                .animation(nil, value: a.compactTrailingText)
        }
    }

    @ViewBuilder
    private func trailingContent(
        for a: LiveActivityCoordinator.Resolved
    ) -> some View {
        if a.id == "worktree", let info = a.worktree {
            // Worktree puts the project name in the leading
            // wing, so the trailing wing carries ONLY the
            // current branch (plus a dirty marker if the
            // working tree has uncommitted changes). White
            // text — branch is the primary data the user
            // reads on the right.
            let marker = info.isDirty ? "*" : ""
            Text("\(info.currentBranch)\(marker)")
                .font(.system(size: 13))
                .foregroundStyle(
                    Self.pillTrailingTextColor(for: a))
                .lineLimit(1)
                .fixedSize()
                .id("trail-worktree-\(info.currentBranch)")
        } else if let text = a.compactTrailingText {
            // Letter unit suffixes (the 'h'/'m'/'s' after
            // digits in things like "1h30m" or "5m 23s") drop
            // to 50% — the number is the data, the unit is the
            // label. Pure-letter strings (branch names, etc.)
            // stay at 100%.
            //
            // `.contentTransition(.numericText())` gives
            // numeric digit changes the iOS-style slot-machine
            // roll. Espresso's 1Hz countdown / music position
            // / volume HUD percentages now ticker rather than
            // crossfade.
            //
            // Optional `compactTrailingPrefixSymbol` (SF Symbol
            // name) renders inline as a glyph BEFORE the
            // dimmed text — used by the battery pill to
            // prepend a bolt when the Mac is charging.
            let baseColor = Self.pillTrailingTextColor(for: a)
            HStack(spacing: 3) {
                if let sym = a.compactTrailingPrefixSymbol {
                    Image(systemName: sym)
                        .font(.system(size: 11,
                                      weight: .semibold))
                        .foregroundStyle(baseColor)
                }
                Self.dimmedUnitsText(text, baseColor: baseColor)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.numericText())
            }
            .id("trail-text-\(a.id)")
        } else if let img = a.compactTrailingImage {
            Image(nsImage: tintImage(
                img, color: Self.pillIconColor(for: a)))
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .opacity(0.9)
                .id("trail-img-\(a.id)")
                .animation(nil, value: a.compactTrailingText)
        }
    }

    /// Concatenates the string as `Text` runs, dimming the
    /// "labels" around digits while leaving the meaningful
    /// digits at full punch. Three categories of dim:
    ///
    /// * **Unit letters** at 50% — `h`/`m`/`s`/`d` after a
    ///   digit in `1h30m`, `5m 23s`, `1d4h`.
    /// * **Leading zeros** at 50% — a `0` that starts a
    ///   digit-run AND is padding a real (non-zero) value.
    ///   So both `0`s in `03:00 / 03:29` dim (each is padding
    ///   the leading `3`), the `0` in `01:23` dims, and the
    ///   `0` after `:` in `01:05` also dims (it's padding the
    ///   `5`). But the `00` in `10:00` or `00:48` stays
    ///   bright — the whole digit-run is zero, no real value
    ///   to pad, the `0`s *are* the value.
    /// * **Numeric punctuation** at 70% — `:`, `/`, `%` when
    ///   the string is clearly a numeric label (a digit
    ///   immediately followed by `:` or `%` somewhere). At
    ///   70% rather than 50% so the structural separators
    ///   stay readable; the units / leading-zero placeholders
    ///   are quieter (50%) since they're labels, not glyphs
    ///   that need to be quickly parsed.
    static func dimmedUnitsText(
        _ s: String,
        baseColor: Color = .white
    ) -> Text {
        var result = Text("")
        let chars = Array(s)
        // Detect "this is a numeric label" — a digit
        // immediately followed by `:` or `%` somewhere in the
        // string. Used to gate the punctuation dimming.
        let isNumericContext: Bool = {
            for i in 0..<chars.count where chars[i].isNumber {
                guard i + 1 < chars.count else { continue }
                let next = chars[i + 1]
                if next == ":" || next == "%" { return true }
            }
            return false
        }()
        // Precompute the indices of every leading-zero
        // character. A `0` dims iff it sits in the
        // "leading-zero run" of its token — i.e. start of
        // string / whitespace / `/`, followed by zero or
        // more consecutive `0`s, before the first non-`0`
        // character. So `00:53` dims both prefix zeros (the
        // whole minutes field is zero-padded), `01:23` dims
        // only the first, `10:00` dims none (the trailing
        // zeros come after a non-zero digit), and `0%` dims
        // the lone `0` because it's still the leading zero
        // of its token.
        let leadingZeroIndices: Set<Int> = {
            var indices: Set<Int> = []
            var inLeadingRun = true
            for i in 0..<chars.count {
                let ch = chars[i]
                if inLeadingRun && ch == "0" {
                    indices.insert(i)
                } else if ch == "0" {
                    // 0 outside a run: ignored, no state change
                } else if ch.isWhitespace || ch == "/" {
                    // Token boundary — re-enter the run for
                    // the next token's prefix.
                    inLeadingRun = true
                } else {
                    // Anything else (digits 1-9, `:`, `%`,
                    // letters…) ends the current run.
                    inLeadingRun = false
                }
            }
            return indices
        }()
        for i in 0..<chars.count {
            let ch = chars[i]
            let opacity: Double = {
                // Single-letter unit after a digit (h/m/s/d).
                if ch.isLetter {
                    guard i > 0, chars[i - 1].isNumber else {
                        return 1.0
                    }
                    // The next char (if any) should NOT also
                    // be a letter — otherwise we'd be in the
                    // middle of a word ("Mango" with a
                    // preceding "10").
                    if i + 1 < chars.count,
                       chars[i + 1].isLetter {
                        return 1.0
                    }
                    return 0.5
                }
                // Numeric punctuation in a numeric run.
                if isNumericContext &&
                   (ch == ":" || ch == "/" || ch == "%") {
                    return 0.7
                }
                // Leading zero — precomputed above. Dims
                // the whole zero-prefix of each token,
                // including all-zero runs like the `00` in
                // `00:53` (the minutes value is zero,
                // padded for width). Mid-token zeros stay
                // bright (`03:09`'s second `0`).
                if leadingZeroIndices.contains(i) {
                    return 0.5
                }
                return 1.0
            }()
            let piece = Text(String(ch))
                .foregroundStyle(baseColor.opacity(opacity))
            result = result + piece
        }
        return result
    }

    /// Paint a template NSImage with the activity's tint.
    private func tintImage(_ img: NSImage, color: Color) -> NSImage {
        Self.tinted(img, color: color)
    }

    /// Static variant the expanded views in `ExpandedCard` use
    /// to colour their header glyphs without each one having
    /// to re-implement the source-atop fill.
    static func tinted(_ img: NSImage, color: Color) -> NSImage {
        let nsColor = NSColor(color)
        let copy = img.copy() as! NSImage
        copy.isTemplate = false
        copy.lockFocus()
        nsColor.set()
        let rect = NSRect(origin: .zero, size: copy.size)
        rect.fill(using: .sourceAtop)
        copy.unlockFocus()
        return copy
    }
}

// MARK: - Geometry

/// Shared layout math for the island. The body of `NotchView`
/// uses it to lay the SwiftUI content out; `NotchHost`'s
/// hit-test view uses the same numbers to decide whether a
/// mouse event lands inside the visible pill.
///
/// Single source of truth — both sides have to agree on the
/// pill's bounds or hit-testing drifts from the visible shape.
enum Geometry {
    /// Minimum width past the notch's edges on each side. The
    /// pill grows past this when content demands.
    static let sidePad: CGFloat = 40
    /// Radius of the concave outer corner (matches the masking
    /// circle that lives just outside the pill on each side).
    static let punchRadius: CGFloat = 12
    /// Convex radius at the pill body's bottom corners.
    static let bottomCornerRadius: CGFloat = 10
    /// Inset between the pill's outer edge and the leading/
    /// trailing content.
    static let contentInset: CGFloat = 22
    /// Minimum gap between content and the physical notch
    /// cutout so the icon/text never sit under the camera.
    static let notchClearance: CGFloat = 12
    /// Standard fixed width the island always grows to when
    /// expanded. Every dropdown sits in the exact same
    /// footprint regardless of which activity is driving it
    /// (Port grid, Worktree branches, Now Playing controls,
    /// AirPods cells, …) — the card centres on the notch
    /// and the compact pill morphs into / out of this single
    /// canonical shape on hover. Sized to comfortably hold
    /// the Now-Playing compact row (18pt artwork + 6pt gap
    /// + 120pt title slot + insets + notch + trailing time)
    /// which is the widest of any pill we render.
    static let expandedWidth: CGFloat = 480

    /// Predicted width of the leading content slot for an
    /// activity. Mirrors `NotchView.leadingContent`'s sizes:
    /// just the 18pt artwork / icon thumbnail by default, but
    /// for now-playing pills the song title sits next to the
    /// album cover so the slot widens to include it (capped
    /// at `maxTitleWidth` to keep an enormous track name from
    /// pushing the pill off the screen).
    static func leadingWidth(
        for a: LiveActivityCoordinator.Resolved?
    ) -> CGFloat {
        guard let a else { return 0 }
        if a.id == "worktree", let info = a.worktree {
            // Git icon + project name (capped at 140pt so a
            // huge folder name doesn't push the trailing
            // branch off the screen). Mirror the renderer.
            let projectName = info.displayName
                ?? ((info.repoPath as NSString)
                        .lastPathComponent)
            let w = min(140,
                        measureText(projectName, size: 13))
            return 18 + 6 + w
        }
        if a.media?.title != nil {
            // Pinned width regardless of the song's natural
            // text width. Used to be \`min(measured, cap)\`,
            // which made the pill (and the expanded dropdown
            // that grows from it) shrink and grow with each
            // track. That reflow was jarring when skipping
            // — fix at the cap so "Bad Habit" and "I Had
            // Some Help (Feat. Morgan Wallen)" produce the
            // same compact + expanded geometry; MarqueeText
            // pads short titles inside the slot and tickers
            // long ones.
            let titleSlot: CGFloat = 120
            // artwork (18) + HStack spacing (6) + title slot
            return 18 + 6 + titleSlot
        }
        return a.compactLeadingImage != nil ? 18 : 0
    }

    /// Predicted width of the trailing content slot. Text is
    /// measured with NSString's typesetting against the same
    /// font NotchView renders with.
    static func trailingWidth(
        for a: LiveActivityCoordinator.Resolved?
    ) -> CGFloat {
        guard let a else { return 0 }
        if a.id == "worktree", let info = a.worktree {
            // Just the current branch + optional dirty
            // marker — no longer the full project·branch
            // label the previous layout packed in here.
            let marker = info.isDirty ? "*" : ""
            return measureText(
                "\(info.currentBranch)\(marker)", size: 13)
        }
        if let text = a.compactTrailingText {
            var w = measureText(text, size: 13)
            // The inline glyph (bolt for the charging battery
            // pill, …) renders at ~11pt + a 3pt gap before
            // the text. Add it to the measured width so the
            // pill grows enough to fit both.
            if a.compactTrailingPrefixSymbol != nil {
                w += 13
            }
            return w
        }
        if a.compactTrailingImage != nil { return 16 }
        return 0
    }

    /// Per-activity extra height for the expanded card. Sums
    /// the activity's intrinsic content height + the card's
    /// internal padding (12 top + 14 bottom = 26pt). Lets the
    /// island fit content tightly rather than sitting on a
    /// fixed bottom-padding floor.
    static func expandedExtraHeight(
        for a: LiveActivityCoordinator.Resolved?,
        hasAirpods: Bool = false
    ) -> CGFloat {
        // 12 top + 10 bottom — matches `ExpandedCard`'s
        // internal vertical insets. Less than the horizontal
        // pad on purpose; the rounded bottom corners already
        // provide visual breathing room.
        let padding: CGFloat = 12 + 10
        let content: CGFloat
        switch a?.id {
        case "halo.stats":
            // 3 rows × 24pt (bar + two-line right column with
            // % over an absolute-value sublabel) + 2 gaps × 10pt
            // = 92pt
            content = 92
        case "halo.battery":
            // Mac header row (~38pt — eyebrow + percentage +
            // optional Charging pill) + divider + a row per
            // connected device (~32pt: 11pt label + 5pt vert
            // pad × 2 + breathing). Plus +1 row when AirPods
            // is active (surfaced by BatteryExpandedView from
            // the sibling `halo.airpods` activity). Empty-
            // state shows a small "no devices" placeholder.
            let hidCount = a?.battery?.devices.count ?? 0
            let rowCount = max(1,
                hidCount + (hasAirpods ? 1 : 0))
            content = 38 + 12 + CGFloat(rowCount) * 32
        case "halo.airpods":
            // Header row (~26pt with the device name on its
            // second line) + divider + the row of three
            // battery cells (~44pt: 9pt label + 4pt gap +
            // 4pt bar + 5pt × 2 vertical pad + breathing).
            content = 26 + 12 + 44
        case "halo.bluetoothaudio":
            // Header row + divider + a small battery-bar /
            // codec block. When battery is known: ~64pt for
            // the bar row. When not known: just the
            // connection eyebrow.
            let hasBat = a?.bluetoothAudio?
                .batteryPercent != nil
            content = 36 /* header */
                + 12 /* divider */
                + (hasBat ? 36 : 20)
        case "halo.nowplaying":
            // Artwork is 44pt tall and dominates the row. The
            // title + artist + scrubber stack and the
            // controls + time-readout stack both fit inside
            // that height, so 44 is exactly the row height —
            // anything extra is dead space below the card.
            content = 44
        case "worktree":
            // Repo header + recent-branches grid + footer
            // actions. The branches grid is 3 columns × up to
            // 2 rows (≤ 6 branches) — ceil((branches - current)
            // / 3) gives the row count. Each grid cell is
            // ~32pt tall (5pt vpad × 2 + 11pt text + a touch).
            // Anything else the WorktreeExpandedView renders
            // (REMOTES, WORKTREES, SAVED) lives inside its own
            // ScrollView, which scrolls inside this frame
            // rather than growing the card.
            let switchable = min(6, max(0,
                (a?.worktree?.branches.count ?? 1) - 1))
            let gridRows = max(1, (switchable + 2) / 3)
            let gridBlock = CGFloat(gridRows) * 32 + 20
                /* + 20pt for the section's RECENT BRANCHES
                   eyebrow + the inter-row breathing space */
            content = 36 /* header */
                + 8 /* gap */ + gridBlock
                + 8 /* gap */ + 28 /* footer */
        case "port":
            // Header row (eyebrow + count, ~30pt) + divider +
            // 2-column grid of port rows. With the standard
            // `expandedMinWidth` (440pt) we fit two cards per
            // row comfortably; up to 6 entries means at most
            // ceil(6 / 2) = 3 grid rows, exactly filling the
            // 2×3 grid. 30pt per row covers the 12pt label
            // + the row's vertical padding plus a touch for
            // the inter-row gap.
            let entryCount = min(6,
                a?.port?.entries.count ?? 0)
            let gridRows = (entryCount + 1) / 2
            let headerHeight: CGFloat = 30
            let dividerPad: CGFloat = 12
            let rowsHeight = gridRows > 0
                ? CGFloat(gridRows) * 30 + dividerPad
                : 0
            content = headerHeight + rowsHeight
        default:
            // Generic row: 26pt icon + spacing ≈ 30pt
            content = 30
        }
        return content + padding
    }

    /// The visible pill's frame in panel-local coordinates with
    /// the SwiftUI convention (origin top-left). The pill's
    /// left and right wings size INDEPENDENTLY to their own
    /// content — long trailing text doesn't force an empty
    /// left wing to match, and vice versa.
    ///
    /// When `expanded`, the island grows **straight down** —
    /// same width and same horizontal position as the compact
    /// pill, just taller by `expandedExtraHeight`. The compact
    /// row fades to opacity 0 but keeps its layout space so
    /// the pill doesn't shift sideways on hover.
    static func islandFrame(
        for a: LiveActivityCoordinator.Resolved?,
        layout: NotchLayout,
        expanded: Bool = false,
        hasAirpods: Bool = false
    ) -> CGRect {
        let notchW = layout.notchTrailingX - layout.notchLeadingX
        let leadW = leadingWidth(for: a)
        let trailW = trailingWidth(for: a)
        let leftHalf = max(
            leadW + contentInset + notchClearance,
            sidePad)
        let rightHalf = max(
            trailW + contentInset + notchClearance,
            sidePad)
        var totalWidth = leftHalf + notchW + rightHalf
        var totalHeight = layout.menuBarHeight + 1
        // When compact the pill hangs asymmetrically off the
        // notch's leading edge so it tracks the menu bar's
        // built-in clock. When expanded we snap to a single
        // canonical `expandedWidth` and centre on the notch
        // — every dropdown reads as the same UI element
        // regardless of which publisher is driving it (Port
        // grid, Worktree branches, Now Playing controls, …).
        // The width is a strict force, not a minimum: even
        // pills that are naturally wider than the expanded
        // width (the Now Playing title slot is borderline)
        // get squeezed down to match so the card outline is
        // visually consistent.
        var leftEdge = layout.notchLeadingX - leftHalf
        if expanded {
            totalHeight += expandedExtraHeight(
                for: a, hasAirpods: hasAirpods)
            let notchCenter =
                layout.notchLeadingX + notchW / 2
            totalWidth = expandedWidth
            leftEdge = notchCenter - totalWidth / 2
        }
        return CGRect(
            x: leftEdge, y: 0,
            width: totalWidth, height: totalHeight)
    }

    /// Measure a string's drawn width using NSString's
    /// typesetting. Matches `Text(.system(size: 13))` — same
    /// regular-weight system font the menu-bar clock uses.
    static func measureText(
        _ s: String, size: CGFloat
    ) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        return ceil((s as NSString).size(
            withAttributes: attrs).width) + 2
    }
}

// MARK: - Marquee text

/// Single-line text that ping-pongs horizontally if its drawn
/// width exceeds `maxWidth` — radio-style ticker. Pauses
/// briefly at each end before reversing so the user can
/// actually read the full label. Falls back to a static frame
/// at the text's natural width if it already fits.
private struct MarqueeText: View {
    let text: String
    let font: Font
    let fontSize: CGFloat
    let color: Color
    let maxWidth: CGFloat
    /// Marquee scroll speed in points per second.
    let speed: Double = 30
    /// Pause at each end of the scroll, in seconds.
    let endPause: Double = 1.5

    var body: some View {
        let measured = Geometry.measureText(text, size: fontSize)
        let overflow = max(0, measured - maxWidth)
        // Always render at full `maxWidth` so the parent's
        // geometry doesn't shift when the text content changes.
        // Short labels pad inside the slot (alignment: .leading);
        // long labels scroll inside the same slot.
        Group {
            if overflow > 0 {
                TimelineView(.animation) { context in
                    label
                        .offset(x: -offset(
                            at: context.date,
                            overflow: overflow))
                        .frame(width: maxWidth,
                               alignment: .leading)
                        .clipped()
                }
            } else {
                label
                    .frame(width: maxWidth,
                           alignment: .leading)
            }
        }
        // Restart the marquee when the text content changes
        // (skip to next track) so we don't carry over a
        // half-scrolled offset.
        .id(text)
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }

    /// Where in the ping-pong cycle we are right now, expressed
    /// as a horizontal offset to apply to the text. Cycle:
    /// pause at start → scroll left → pause at end → scroll
    /// back to start → repeat.
    private func offset(
        at date: Date, overflow: CGFloat
    ) -> CGFloat {
        let scrollDur = Double(overflow) / speed
        let cycle = (endPause + scrollDur) * 2
        let t = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycle)
        if t < endPause {
            return 0
        } else if t < endPause + scrollDur {
            let p = (t - endPause) / scrollDur
            return CGFloat(p) * overflow
        } else if t < endPause * 2 + scrollDur {
            return overflow
        } else {
            let p = (t - endPause * 2 - scrollDur) / scrollDur
            return overflow * CGFloat(1 - p)
        }
    }
}

// MARK: - Shape

/// One combined Path tracing a pill that hangs from the screen
/// edge with smooth concave transitions at the top corners:
///
///   1. A flat-topped pill body whose vertical sides start at
///      `y = pr` (not the screen edge) — the top `pr` is taken
///      up by the concave outer corners.
///   2. At each top corner, a concave 90° arc that smoothly
///      blends from the horizontal screen edge (above, at
///      `y = 0`) into the pill's vertical side (below, at
///      `x = pillLeft` or `x = pillRight`). The arc's centre
///      sits at the pill's notional top corner (`pillRight, 0`
///      / `pillLeft, 0`) so the curve "wraps" outward, the
///      same trick the macOS notch uses where it meets the
///      screen below it.
///
/// Tracing the OUTSIDE boundary clockwise from outer top-left:
///
///   (0, 0) → top edge → (w, 0)
///     → concave outer corner → (pillRight, pr)
///     → pill's right edge → (pillRight, h - br)
///     → convex bottom-right → (pillRight - br, h)
///     → bottom edge → (pillLeft + br, h)
///     → convex bottom-left → (pillLeft, h - br)
///     → pill's left edge → (pillLeft, pr)
///     → concave outer corner → (0, 0)
///
/// NB: SwiftUI's `addArc(..., clockwise:)` uses y-up math
/// convention internally — `clockwise: false` produces the
/// visually CLOCKWISE short arc in screen space (verified by
/// the bottom corners, which use `clockwise: false` and curve
/// the right way). Both concave outer corners and both
/// rounded bottom corners use `clockwise: false`.
private struct IslandShape: Shape {
    var punchRadius: CGFloat = 12
    var bottomCornerRadius: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let pr = punchRadius
        let br = min(bottomCornerRadius, h / 2)

        // The pill body sits inset by `pr` on each side; the
        // outer `pr × pr` square at each top corner is a
        // "wing" — most of it gets masked away by a circle
        // sitting OUTSIDE the pill on that side, and what's
        // left is the small concave-edged ear on top of the
        // pill at that corner.
        let pillLeft = pr
        let pillRight = w - pr

        var p = Path()

        // Outer top-left (where left wing meets screen edge).
        p.move(to: CGPoint(x: 0, y: 0))

        // Top edge across both wings and the pill top.
        p.addLine(to: CGPoint(x: w, y: 0))

        // RIGHT wing concave arc. The masking circle sits to
        // the RIGHT of the pill, centred at (w, pr) — the
        // outer-bottom corner of the right wing square. It
        // chews out everything in the wing except the small
        // ear at top-left of the wing (which sits on top of
        // the pill's right shoulder). Arc traces the visible
        // ear's curved boundary from (w, 0) on the screen
        // edge down-and-left to (pillRight, pr) where the
        // wing meets the pill's right edge.
        p.addArc(
            center: CGPoint(x: w, y: pr),
            radius: pr,
            startAngle: .degrees(-90),   // = (w, 0)
            endAngle: .degrees(180),     // = (pillRight, pr)
            clockwise: true)             // short arc via -135°

        // Pill's right edge straight down.
        p.addLine(to: CGPoint(x: pillRight, y: h - br))

        // Bottom-right convex rounded corner.
        p.addArc(
            center: CGPoint(x: pillRight - br, y: h - br),
            radius: br,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false)

        // Bottom edge.
        p.addLine(to: CGPoint(x: pillLeft + br, y: h))

        // Bottom-left convex rounded corner.
        p.addArc(
            center: CGPoint(x: pillLeft + br, y: h - br),
            radius: br,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false)

        // Pill's left edge straight up to the left wing.
        p.addLine(to: CGPoint(x: pillLeft, y: pr))

        // LEFT wing concave arc — mirror. Masking circle
        // centred at (0, pr), the outer-bottom corner of the
        // left wing square. Arc traces the ear's curve from
        // (pillLeft, pr) up-and-left to (0, 0).
        p.addArc(
            center: CGPoint(x: 0, y: pr),
            radius: pr,
            startAngle: .degrees(0),     // = (pillLeft, pr)
            endAngle: .degrees(-90),     // = (0, 0)
            clockwise: true)             // short arc via -45°

        p.closeSubpath()
        return p
    }
}

/// One half of the contour-trace accent. Builds the path from
/// the pill's bottom-centre outward — along the bottom edge,
/// through the convex bottom corner, up the side, through the
/// concave bite, and finally along the screen's top edge out to
/// the screen's left/right edge. Two copies (one per `Side`)
/// are stacked in `screenTopAccent`, each trimmed by
/// `borderProgress` so the line appears to draw itself outward
/// from the centre.
///
/// All coordinates are in the panel's local space (origin
/// top-left). The path uses `islandFrame` and `screenWidth`
/// directly rather than the parent rect, so the parent only
/// needs to size the shape large enough to contain the panel.
///
/// Arc-direction convention: SwiftUI's `Path.addArc` treats
/// `clockwise` in the legacy y-up sense, so `clockwise: false`
/// here produces visually-clockwise short arcs on screen and
/// vice-versa. Mirrors `IslandShape`.
private struct ScreenAccentTrace: Shape {
    enum Side { case left, right }
    var side: Side
    var islandFrame: CGRect
    var screenWidth: CGFloat
    var punchRadius: CGFloat
    var bottomCornerRadius: CGFloat

    /// Interpolates the four `islandFrame` components so SwiftUI
    /// can smoothly tween the contour when the pill expands /
    /// contracts on hover. Without this conformance the Shape's
    /// path would snap to the new geometry at the start of the
    /// animation instead of growing in lockstep with the pill.
    var animatableData:
        AnimatablePair<
            AnimatablePair<CGFloat, CGFloat>,
            AnimatablePair<CGFloat, CGFloat>
        >
    {
        get {
            AnimatablePair(
                AnimatablePair(islandFrame.origin.x,
                               islandFrame.origin.y),
                AnimatablePair(islandFrame.size.width,
                               islandFrame.size.height))
        }
        set {
            islandFrame = CGRect(
                x: newValue.first.first,
                y: newValue.first.second,
                width: newValue.second.first,
                height: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        let pr = punchRadius
        let br = min(bottomCornerRadius, islandFrame.height / 2)
        let pillLeft = islandFrame.minX + pr
        let pillRight = islandFrame.maxX - pr
        let topY = islandFrame.minY
        let bottomY = islandFrame.maxY

        var p = Path()
        // Both branches start at the bottom-centre of the pill.
        p.move(to: CGPoint(x: islandFrame.midX, y: bottomY))

        switch side {
        case .right:
            // Bottom edge → entry point of the rounded corner.
            p.addLine(to: CGPoint(x: pillRight - br, y: bottomY))
            // Bottom-right convex corner: south → east (the
            // reverse of `IslandShape`'s clockwise traversal,
            // hence `clockwise: true` rather than false).
            p.addArc(
                center: CGPoint(x: pillRight - br,
                                y: bottomY - br),
                radius: br,
                startAngle: .degrees(90),
                endAngle: .degrees(0),
                clockwise: true)
            // Up the pill's right edge to the concave bite.
            p.addLine(to: CGPoint(x: pillRight, y: topY + pr))
            // Right concave arc: west → north through the NW
            // quadrant of the masking circle that lives just
            // outside the pill at (frame.maxX, topY + pr).
            p.addArc(
                center: CGPoint(x: islandFrame.maxX,
                                y: topY + pr),
                radius: pr,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false)
            // Along the screen's top edge to its right side.
            // Sits right at y=0 — the device bezel clips half
            // the stroke, but anything fancier (an edge-drop +
            // chamfer) just trades one visual seam for another.
            p.addLine(to: CGPoint(x: screenWidth, y: topY))

        case .left:
            // Bottom edge → entry point of the rounded corner.
            p.addLine(to: CGPoint(x: pillLeft + br, y: bottomY))
            // Bottom-left convex corner: south → west. Same
            // direction as `IslandShape` so the convention
            // matches (`clockwise: false`).
            p.addArc(
                center: CGPoint(x: pillLeft + br,
                                y: bottomY - br),
                radius: br,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false)
            // Up the pill's left edge to the concave bite.
            p.addLine(to: CGPoint(x: pillLeft, y: topY + pr))
            // Left concave arc: east → north through the NE
            // quadrant of the masking circle at
            // (frame.minX, topY + pr). Same orientation as
            // `IslandShape`'s left wing concave.
            p.addArc(
                center: CGPoint(x: islandFrame.minX,
                                y: topY + pr),
                radius: pr,
                startAngle: .degrees(0),
                endAngle: .degrees(-90),
                clockwise: true)
            // Along the screen's top edge to its left side.
            p.addLine(to: CGPoint(x: 0, y: topY))
        }
        return p
    }
}

