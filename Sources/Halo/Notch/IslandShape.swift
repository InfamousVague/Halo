import SwiftUI

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
struct IslandShape: Shape {
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
struct ScreenAccentTrace: Shape {
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

