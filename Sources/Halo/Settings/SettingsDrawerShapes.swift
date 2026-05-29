import SwiftUI

// MARK: - DrawerShape

/// 90°-rotated notch outline — the drawer body is a clean
/// rounded rectangle, with two small WINGS (the rotated
/// equivalent of the notch's left + right wings) that
/// extend ABOVE and BELOW the body, NOT cuts INTO it.
///
///                              ┌──┐ ← top WING extends
///                              │  │   up past body's top,
///                              │  │   against screen right
///         ╭───────────────────┴──┤
///   body's top edge ─→            │ (rounded top-left)
///                                 │
///                  body           │
///                                 │ (right edge flush
///                                 │   against screen)
///                  body           │
///                                 │
///   body's bottom ─→              │ (rounded bottom-left)
///         ╰───────────────────┬──┤
///                              │  │
///                              │  │
///                              └──┘ ← bottom WING extends
///                                     down past body's bot
///
/// Concave wedges sit at the inside corners where the wings
/// meet the body's top + bottom (not on the body itself).
/// Going clockwise around the outline from the top-right
/// screen corner:
///
///   1. Top-right outer corner of TOP wing (the screen corner)
///   2. Right edge of TOP wing → flush right edge of body →
///      right edge of BOTTOM wing  (one continuous vertical
///      line against the screen)
///   3. Bottom-right outer corner of BOTTOM wing (the lower
///      screen corner of the panel)
///   4. Bottom edge of BOTTOM wing leftward
///   5. Left side of BOTTOM wing UP to body level
///   6. Concave wedge curving from bottom wing's inner
///      corner into body's bottom-right corner
///   7. Body's bottom edge leftward
///   8. Body's rounded bottom-left corner
///   9. Body's left edge upward
///   10. Body's rounded top-left corner
///   11. Body's top edge rightward
///   12. Concave wedge from body's top-right corner up to
///       top wing's inner-bottom-left corner
///   13. Top wing's left side UP to outer top corner (close)
/// The sticky right-edge layer — a vertical strip from
/// `x = bodyRight` to `x = w` covering the full screen-facing
/// edge of the panel, with concave wedge cuts at its top-left
/// and bottom-left corners where it joins the body. Stays
/// anchored to the screen edge throughout the slide animation,
/// like the macOS top notch's corners stay anchored during the
/// island's downward expand.
struct WingsShape: Shape {
    var wedgeRadius: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let wr = wedgeRadius
        let bodyRight = w - wr

        var p = Path()

        // Trace clockwise from screen-top-right corner.
        p.move(to: CGPoint(x: w, y: 0))
        // Right edge south to screen-bottom-right corner —
        // flush against the screen edge for the panel's full
        // height.
        p.addLine(to: CGPoint(x: w, y: h))
        // Bottom-RIGHT wedge: arc from (w, h) inward to the
        // body's bottom-right corner (bodyRight, h - wr).
        p.addArc(
            center: CGPoint(x: bodyRight, y: h),
            radius: wr,
            startAngle: .degrees(0),     // (w, h)
            endAngle: .degrees(270),     // (bodyRight, h - wr)
            clockwise: true)
        // Inner left edge of the strip — straight north at
        // x = bodyRight from the bottom wedge endpoint up to
        // the top wedge endpoint. Stays at bodyRight so the
        // body's right edge (also at bodyRight) lines up
        // flush with this side when the body slides into
        // place.
        p.addLine(to: CGPoint(x: bodyRight, y: wr))
        // Top-RIGHT wedge: arc back up to (w, 0) closing the
        // strip.
        p.addArc(
            center: CGPoint(x: bodyRight, y: 0),
            radius: wr,
            startAngle: .degrees(90),    // (bodyRight, wr)
            endAngle: .degrees(0),       // (w, 0)
            clockwise: true)

        p.closeSubpath()
        return p
    }
}

/// Just the body — a rounded rectangle from (0, wr) to
/// (bodyRight, h - wr) with rounded LEFT corners and a sharp
/// right edge. Sits in the body region of the panel; gets
/// `.offset(x:)`-translated for the slide-in animation. The
/// wings render at their natural position (no offset) and
/// stay anchored to the screen edge, so the body slides in
/// from off-screen-right and visually meets the wings at
/// `x = bodyRight` when settled.
struct BodyShape: Shape {
    var wedgeRadius: CGFloat = 14
    var leftCornerRadius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let wr = wedgeRadius
        let bodyRight = w - wr
        let lr = min(
            leftCornerRadius, (h - 2 * wr) / 2)

        var p = Path()
        // Trace clockwise from body's top-right corner.
        p.move(to: CGPoint(x: bodyRight, y: wr))
        p.addLine(to: CGPoint(x: bodyRight, y: h - wr))
        p.addLine(to: CGPoint(x: lr, y: h - wr))
        // Bottom-left rounded corner.
        p.addArc(
            center: CGPoint(x: lr, y: h - wr - lr),
            radius: lr,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false)
        // Left edge north.
        p.addLine(to: CGPoint(x: 0, y: wr + lr))
        // Top-left rounded corner.
        p.addArc(
            center: CGPoint(x: lr, y: wr + lr),
            radius: lr,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false)
        // Top edge east back to start.
        p.addLine(to: CGPoint(x: bodyRight, y: wr))
        p.closeSubpath()
        return p
    }
}

struct DrawerShape: Shape {
    /// Wing depth — how far the wing extends past the body
    /// and the radius of the concave wedge where it meets
    /// the body. Constant: the wedges sit at the screen
    /// edge throughout the open animation, anchored like the
    /// hardware notch's corners.
    var wedgeRadius: CGFloat = 14
    /// 0 = drawer fully collapsed against the right screen
    /// edge (just the two wing "ears" visible), 1 = drawer
    /// fully open with the body extending all the way to the
    /// left edge of the panel. Animatable.
    ///
    /// During the open animation the WEDGES stay at the
    /// right edge (fixed); only the body's LEFT edge moves —
    /// from `bodyRight` (collapsed, body has zero width) all
    /// the way to `0` (full body). Same relationship the
    /// notch's downward expansion has to the screen top edge.
    var openProgress: CGFloat = 1
    /// Rounded-corner radius for the body's interior-facing
    /// corners (top-left + bottom-left).
    var leftCornerRadius: CGFloat = 18

    /// Path interpolates on `openProgress` so SwiftUI's
    /// animation system can morph between collapsed + open
    /// states — body extends leftward from the fixed right-
    /// edge wedges.
    var animatableData: CGFloat {
        get { openProgress }
        set { openProgress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let wr = wedgeRadius
        // Body's right edge sits inset from the panel's
        // right edge by wr (so the wings can extend past it).
        let bodyRight = w - wr
        // Body's left edge — animatable. At openProgress=1
        // the body's left edge is at 0 (full body). At
        // openProgress=0 it's at bodyRight (zero body width).
        let bodyLeft = bodyRight * (1 - openProgress)
        // Rounded corners can't exceed half the body's
        // dimensions in either axis — clamp so the morph
        // stays valid when the body is narrow.
        let bodyWidth = bodyRight - bodyLeft
        let lr = min(
            leftCornerRadius,
            max(0, bodyWidth / 2),
            max(0, (h - 2 * wr) / 2))

        var p = Path()

        // 1. Start at the screen-top corner (top-right of
        //    the top wing, against the screen edges).
        p.move(to: CGPoint(x: w, y: 0))

        // 2. Right edge straight down — flush against the
        //    screen edge for the FULL panel height. Stays
        //    here regardless of openProgress — the wedges
        //    are anchored to the screen edge.
        p.addLine(to: CGPoint(x: w, y: h))

        // 3. Bottom-right wedge: screen-bottom corner of the
        //    panel (w, h) → body's bottom-right
        //    (bodyRight, h - wr). Fixed position; doesn't
        //    move with openProgress.
        p.addArc(
            center: CGPoint(x: bodyRight, y: h),
            radius: wr,
            startAngle: .degrees(0),     // (w, h)
            endAngle: .degrees(270),     // (bodyRight, h - wr)
            clockwise: true)             // through 315°

        // 4. Body's bottom edge westbound — extends from the
        //    fixed body-right corner all the way to the
        //    body's CURRENT left edge (bodyLeft, h - wr).
        //    As openProgress animates, bodyLeft moves left,
        //    extending this edge.
        p.addLine(to: CGPoint(x: bodyLeft + lr, y: h - wr))

        // 5. Body's rounded bottom-left corner — convex.
        //    Position moves with bodyLeft.
        p.addArc(
            center: CGPoint(x: bodyLeft + lr, y: h - wr - lr),
            radius: lr,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false)

        // 6. Body's left edge northbound — also moves with
        //    bodyLeft.
        p.addLine(to: CGPoint(x: bodyLeft, y: wr + lr))

        // 7. Body's rounded top-left corner — convex.
        p.addArc(
            center: CGPoint(x: bodyLeft + lr, y: wr + lr),
            radius: lr,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false)

        // 8. Body's top edge eastbound — back to the fixed
        //    body-right corner (bodyRight, wr).
        p.addLine(to: CGPoint(x: bodyRight, y: wr))

        // 9. Top-right wedge: mirror of step 3. Fixed
        //    position at the screen edge.
        p.addArc(
            center: CGPoint(x: bodyRight, y: 0),
            radius: wr,
            startAngle: .degrees(90),
            endAngle: .degrees(0),
            clockwise: true)

        p.closeSubpath()
        return p
    }
}
