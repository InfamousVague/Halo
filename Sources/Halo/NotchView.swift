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
            for: a, layout: layout, expanded: isExpanded)
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
            for: a, layout: layout, expanded: isExpanded)
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
                    ExpandedCard(activity: a)
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

    /// Colour used for the leading icon, the trailing text,
    /// and the time read-out in the expanded music card. Just
    /// the publisher's brand colour straight up — Spotify green
    /// is *the* Spotify green, Apple Music red is *the* Apple
    /// Music red, Espresso brown is the espresso brown.
    static func pillTextColor(
        for a: LiveActivityCoordinator.Resolved
    ) -> Color {
        accentColor(for: a)
    }

    private static func brandColor(forID id: String) -> Color? {
        switch id {
        case "halo.volume":     return Color(red: 0.36, green: 0.66, blue: 1.00)
        case "halo.brightness": return Color(red: 1.00, green: 0.78, blue: 0.20)
        case "halo.nowplaying": return Color(red: 0.96, green: 0.41, blue: 0.62)
        case "halo.airpods":    return Color(red: 0.78, green: 0.78, blue: 0.82)
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
            // Album cover takes precedence over the generic
            // music-note symbol when we have it. Full colour
            // (not template-tinted) and clipped to a small
            // rounded square so it reads like a Spotify /
            // Music thumbnail rather than a glyph.
            Image(nsImage: artwork)
                .resizable()
                .scaledToFill()
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 3,
                                            style: .continuous))
                .id("lead-art-\(a.media?.title ?? "")")
                .transition(.opacity)
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
                img, color: Self.pillTextColor(for: a)))
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
        if let text = a.compactTrailingText {
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
            Self.dimmedUnitsText(
                text,
                baseColor: Self.pillTextColor(for: a))
                .font(.system(size: 13))
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText())
                .id("trail-text-\(a.id)")
        } else if let img = a.compactTrailingImage {
            Image(nsImage: tintImage(
                img, color: Self.pillTextColor(for: a)))
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
    /// * **Unit letters** following a digit — `h`/`m`/`s`/`d`
    ///   in things like `1h30m`, `5m 23s`, `1d4h`.
    /// * **Numeric punctuation** in time / percent strings —
    ///   `:`, `/`, `%` in things like `1:23`, `1:23 / 4:56`,
    ///   `50%`. Only dimmed when the surrounding string is
    ///   clearly numeric (digit immediately followed by `:`
    ///   or `%` somewhere in the run), so a branch name like
    ///   `feature/foo` doesn't get its `/` dimmed too.
    /// * **Leading zeros** — the padding `0` at the start of
    ///   each numeric group (`0`*1*:23, *0*5m 23s) so the
    ///   eye reads the magnitude without losing the constant
    ///   width that prevents pill reflow.
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
        for i in 0..<chars.count {
            let ch = chars[i]
            let isUnit: Bool = {
                // Single-letter unit after a digit (h/m/s/d).
                if ch.isLetter {
                    guard i > 0, chars[i - 1].isNumber else {
                        return false
                    }
                    // The next char (if any) should NOT also
                    // be a letter — otherwise we'd be in the
                    // middle of a word ("Mango" with a
                    // preceding "10").
                    if i + 1 < chars.count,
                       chars[i + 1].isLetter {
                        return false
                    }
                    return true
                }
                // Numeric punctuation in a numeric run.
                if isNumericContext &&
                   (ch == ":" || ch == "/" || ch == "%") {
                    return true
                }
                // Leading zero: a `0` at the start of a
                // numeric run that has at least one more
                // digit after it. So the `0` in `01:23` and
                // both `0`s in `01h 05m` dim, but the `0` in
                // `10:23` (preceded by `1`) stays bright,
                // and a lone `0` like `0%` stays bright too
                // (no digit follows, so it's the value not
                // padding).
                if ch == "0" {
                    let prevIsDigit = i > 0
                        && chars[i - 1].isNumber
                    let nextIsDigit = i + 1 < chars.count
                        && chars[i + 1].isNumber
                    if !prevIsDigit && nextIsDigit {
                        return true
                    }
                }
                return false
            }()
            let piece = Text(String(ch))
                .foregroundStyle(
                    isUnit
                        ? baseColor.opacity(0.5)
                        : baseColor)
            result = result + piece
        }
        return result
    }

    /// Paint a template NSImage with the activity's tint.
    private func tintImage(_ img: NSImage, color: Color) -> NSImage {
        let nsColor = NSColor(color)
        let tinted = img.copy() as! NSImage
        tinted.isTemplate = false
        tinted.lockFocus()
        nsColor.set()
        let rect = NSRect(origin: .zero, size: tinted.size)
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        return tinted
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

    /// Predicted width of the leading content slot for an
    /// activity. Mirrors `NotchView.leadingContent`'s sizes.
    static func leadingWidth(
        for a: LiveActivityCoordinator.Resolved?
    ) -> CGFloat {
        a?.compactLeadingImage != nil ? 18 : 0
    }

    /// Predicted width of the trailing content slot. Text is
    /// measured with NSString's typesetting against the same
    /// font NotchView renders with.
    static func trailingWidth(
        for a: LiveActivityCoordinator.Resolved?
    ) -> CGFloat {
        guard let a else { return 0 }
        if let text = a.compactTrailingText {
            return measureText(text, size: 13)
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
        for a: LiveActivityCoordinator.Resolved?
    ) -> CGFloat {
        // 12 top + 10 bottom — matches `ExpandedCard`'s
        // internal vertical insets. Less than the horizontal
        // pad on purpose; the rounded bottom corners already
        // provide visual breathing room.
        let padding: CGFloat = 12 + 10
        let content: CGFloat
        switch a?.id {
        case "halo.stats":
            // 3 rows × 20pt + 2 gaps × 10pt = 80pt
            content = 80
        case "halo.nowplaying":
            // Controls column is now controls (~24pt) + 4pt
            // gap + time read-out (~14pt) = ~42pt, plus the
            // artwork at 44pt. Bump the slot from 50 → 60 so
            // the read-out doesn't get clipped.
            content = 60
        case "worktree":
            // Header row + divider + up to 5 branch rows ×
            // ~26pt each. Real branch count caps the height
            // dynamically by way of the empty VStack.
            let branchCount = min(5, max(0,
                (a?.worktree?.branches.count ?? 1) - 1))
            content = 24 /* header */ + 12 /* divider+pad */
                + CGFloat(branchCount) * 26
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
        expanded: Bool = false
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
        let totalWidth = leftHalf + notchW + rightHalf
        var totalHeight = layout.menuBarHeight + 1
        if expanded {
            totalHeight += expandedExtraHeight(for: a)
        }
        // Always asymmetric, anchored to the notch's leading
        // edge. The expanded card lives entirely inside the
        // same horizontal footprint as the compact row, so no
        // sideways jump on hover.
        let leftEdge = layout.notchLeadingX - leftHalf
        return CGRect(
            x: leftEdge, y: 0,
            width: totalWidth, height: totalHeight)
    }

    /// Measure a string's drawn width using NSString's
    /// typesetting. Matches `Text(.system(size: 13))` — same
    /// regular-weight system font the menu-bar clock uses.
    private static func measureText(
        _ s: String, size: CGFloat
    ) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        return ceil((s as NSString).size(
            withAttributes: attrs).width) + 2
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

