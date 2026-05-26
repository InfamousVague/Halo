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

    /// 0 → 1: how far the contour trace has expanded from the
    /// pill's bottom-centre. Animated when a new activity
    /// takes the slot. 0 = no line visible, 1 = full path
    /// drawn. Stays at 1 until the activity changes (or
    /// disappears), then resets for the next re-trace.
    @State private var borderProgress: Double = 0

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
                island(for: a)
                    // Spring on every visible attribute — frame
                    // width / height, icon, text — so the pill
                    // morphs smoothly when any of them change.
                    .animation(.spring(response: 0.32,
                                       dampingFraction: 0.86),
                               value: a.id)
                    .animation(.spring(response: 0.32,
                                       dampingFraction: 0.86),
                               value: a.compactTrailingText)
                    .animation(.spring(response: 0.42,
                                       dampingFraction: 0.84),
                               value: isExpanded)
                    .animation(.spring(response: 0.32,
                                       dampingFraction: 0.86),
                               value: cycleSlot)
            }
            // Screen-top accent line — 2px stroke at the very
            // top edge of the display, painted in the new
            // publisher's brand colour and expanding from the
            // notch centre out to both screen edges when an
            // activity claims the slot. Sits above the island
            // shape (in the ZStack) and ignores hit tests so
            // it never blocks menu-bar clicks.
            screenTopAccent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: activity?.id) { _, _ in
            if activity != nil { triggerBorderTrace() }
        }
        .onAppear {
            if activity != nil { triggerBorderTrace() }
        }
    }

    @ViewBuilder
    private var screenTopAccent: some View {
        if let a = activity {
            let color = Self.accentColor(for: a)
            // Single 1pt stroke. The path runs from the pill's
            // bottom-centre out to each screen edge, hugging
            // the island's contour through the bottom corner,
            // side, and concave bite before extending along
            // the screen's top edge. Two copies — one per
            // side — are stacked and trimmed by
            // `borderProgress` so the line draws itself
            // outward from the centre.
            let frame = Geometry.islandFrame(
                for: a, layout: layout, expanded: isExpanded)
            let stroke = StrokeStyle(
                lineWidth: 1,
                lineCap: .round,
                lineJoin: .round)
            ZStack {
                ScreenAccentTrace(
                    side: .right,
                    islandFrame: frame,
                    screenWidth: layout.screenWidth,
                    punchRadius: punchRadius,
                    bottomCornerRadius: bottomCornerRadius
                )
                .trim(from: 0, to: borderProgress)
                .stroke(color, style: stroke)
                ScreenAccentTrace(
                    side: .left,
                    islandFrame: frame,
                    screenWidth: layout.screenWidth,
                    punchRadius: punchRadius,
                    bottomCornerRadius: bottomCornerRadius
                )
                .trim(from: 0, to: borderProgress)
                .stroke(color, style: stroke)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Match the island's hover-expansion spring so the
            // contour morphs in lock-step with the pill rather
            // than snapping to the new frame. `ScreenAccentTrace`
            // is `Animatable` on its `islandFrame`, so this
            // animation propagates through to the path
            // coordinates and the trace stretches / contracts
            // alongside the pill body.
            .animation(.spring(response: 0.42,
                               dampingFraction: 0.84),
                       value: isExpanded)
            .animation(.spring(response: 0.32,
                               dampingFraction: 0.86),
                       value: a.compactTrailingText)
            .allowsHitTesting(false)
        }
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
    /// 1 over ~0.9s and then **stays drawn**. The line only
    /// disappears when the activity itself goes away (the
    /// `if let a = activity` guard above strips the view), or
    /// when the next activity takes the slot and resets the
    /// progress for its own re-trace.
    private func triggerBorderTrace() {
        borderProgress = 0
        withAnimation(.easeOut(duration: 0.9)) {
            borderProgress = 1
        }
    }

    /// Per-publisher accent. Prefers the activity's declared
    /// tint (file-store publishers set it via tintHex); falls
    /// back to a hand-picked brand color for built-in
    /// publishers that publish white.
    private static func accentColor(
        for a: LiveActivityCoordinator.Resolved
    ) -> Color {
        // The compact pill tint is white across publishers —
        // detect that and route to the per-id brand color.
        if let brand = brandColor(forID: a.id) { return brand }
        return a.tint
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
            // B&W scheme — every glyph tints white, ignoring
            // the publisher's tintHex. 90% so the icon reads
            // as supporting content next to 100% primary text
            // (the "data" side gets full punch).
            Image(nsImage: tintImage(img, color: .white))
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .opacity(0.9)
                .id("lead-\(a.id)")
                .transition(.opacity)
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
            Self.dimmedUnitsText(text)
                .font(.system(size: 13))
                .lineLimit(1)
                .fixedSize()
                .id("trail-text-\(a.id)")
                .transition(.opacity)
        } else if let img = a.compactTrailingImage {
            Image(nsImage: tintImage(img, color: .white))
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .opacity(0.9)
                .id("trail-img-\(a.id)")
                .transition(.opacity)
        }
    }

    /// Concatenates the string as `Text` runs, dimming any
    /// single letter that immediately follows a digit. Catches
    /// the unit suffixes in time displays — `1h30m`, `5m 23s`,
    /// `1d4h` — without touching pure-letter strings like
    /// repo names or branch names. Lone letters between digits
    /// (e.g. the `m` in `1m 23s` even when followed by a
    /// space) still dim because the rule is "previous char is
    /// a digit" — and the next-not-letter check just guards
    /// against words happening to start with a letter that
    /// followed a digit accidentally.
    fileprivate static func dimmedUnitsText(_ s: String) -> Text {
        var result = Text("")
        let chars = Array(s)
        for i in 0..<chars.count {
            let ch = chars[i]
            let isUnit: Bool = {
                guard ch.isLetter else { return false }
                guard i > 0, chars[i - 1].isNumber else {
                    return false
                }
                // Single-letter unit — the next char (if any)
                // should NOT also be a letter, otherwise we'd
                // be in the middle of a word ("Mango" with a
                // preceding "10").
                if i + 1 < chars.count, chars[i + 1].isLetter {
                    return false
                }
                return true
            }()
            let piece = Text(String(ch))
                .foregroundStyle(
                    isUnit
                        ? Color.white.opacity(0.5)
                        : Color.white)
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

    /// Minimum width an expanded card grows to (regardless of
    /// the compact pill's content width). Wide enough for the
    /// 3-row Stats layout or a multi-device AirPods layout.
    static let expandedMinWidth: CGFloat = 320

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
            // 44pt artwork ≥ title+artist+scrubber stack
            content = 50
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
    /// When `expanded`, the island grows DOWNWARD into a card
    /// (+`expandedExtraHeight`) and widens symmetrically to at
    /// least `expandedMinWidth` so the rich content has room.
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
        var totalWidth = leftHalf + notchW + rightHalf
        var totalHeight = layout.menuBarHeight + 1
        if expanded {
            // Symmetric extra width centred on the notch so
            // the card grows evenly on both sides.
            let needed = max(expandedMinWidth, totalWidth)
            totalWidth = needed
            totalHeight += expandedExtraHeight(for: a)
        }
        // Centre on the notch when expanded (the card needs
        // symmetric room for the widget grid), otherwise stay
        // asymmetric so compact text alignment looks right.
        let leftEdge: CGFloat
        if expanded {
            leftEdge = layout.notchCenterX - totalWidth / 2
        } else {
            leftEdge = layout.notchLeadingX - leftHalf
        }
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

        // 1pt offset that drops the horizontal top-edge
        // segment just below the device's curved screen bezel.
        // The line is otherwise centred on the screen's y=0,
        // so half of it sits behind the bezel and the other
        // half lands inside the rounded-corner falloff — only
        // about a quarter of a point ends up visible. Pushing
        // it down by a full point clears the bezel entirely
        // while keeping the contour meeting the pill silhouette
        // exactly at the wing's top corner (y=0).
        let edgeDrop: CGFloat = 1

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
            // 1pt drop right at the wing's top corner, then
            // along the screen's top edge to its right side.
            p.addLine(to: CGPoint(x: islandFrame.maxX,
                                  y: topY + edgeDrop))
            p.addLine(to: CGPoint(x: screenWidth,
                                  y: topY + edgeDrop))

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
            // 1pt drop right at the wing's top corner, then
            // along the screen's top edge to its left side.
            p.addLine(to: CGPoint(x: islandFrame.minX,
                                  y: topY + edgeDrop))
            p.addLine(to: CGPoint(x: 0, y: topY + edgeDrop))
        }
        return p
    }
}

