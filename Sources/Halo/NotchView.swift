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
    var activities: [LiveActivityCoordinator.Resolved]
    var layout: NotchLayout

    /// Width past the notch's edges on each side, measured to
    /// the OUTER edge of the side elements (the punched-out
    /// corners). The pill body itself is narrower by one
    /// `punchRadius` on each end.
    private let sidePad: CGFloat = 40
    /// Radius of the circle punched out of each side element.
    /// Equal to the visible concave radius at the top corners.
    private let punchRadius: CGFloat = 12
    /// Regular convex radius at the pill body's bottom corners.
    private let bottomCornerRadius: CGFloat = 4

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let top = activities.first {
                island(for: top)
                    .animation(.spring(response: 0.34,
                                       dampingFraction: 0.78),
                               value: top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func island(
        for a: LiveActivityCoordinator.Resolved
    ) -> some View {
        let totalWidth =
            (layout.notchTrailingX - layout.notchLeadingX) + sidePad * 2
        let totalHeight = layout.menuBarHeight
        let leftEdge = layout.notchLeadingX - sidePad

        ZStack {
            IslandShape(
                punchRadius: punchRadius,
                bottomCornerRadius: bottomCornerRadius
            )
            .fill(Color.black)
            .frame(width: totalWidth, height: totalHeight)

            // Content centred vertically inside the menu-bar
            // band. Icon pushed to the FAR LEFT of the pill,
            // text to the FAR RIGHT — the notch's hardware
            // cutout sits between them in the middle.
            HStack(spacing: 0) {
                leadingContent(for: a)
                Spacer(minLength: 0)
                trailingContent(for: a)
            }
            .padding(.horizontal, 14)
            .frame(width: totalWidth, height: totalHeight)
        }
        .frame(width: totalWidth, height: totalHeight)
        .position(
            x: leftEdge + totalWidth / 2,
            y: totalHeight / 2)
    }

    @ViewBuilder
    private func leadingContent(
        for a: LiveActivityCoordinator.Resolved
    ) -> some View {
        if let img = a.compactLeadingImage {
            Image(nsImage: tintImage(img, color: a.tint))
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
        }
    }

    @ViewBuilder
    private func trailingContent(
        for a: LiveActivityCoordinator.Resolved
    ) -> some View {
        if let text = a.compactTrailingText {
            Text(text)
                .font(.system(size: 13, weight: .semibold,
                              design: .rounded))
                .foregroundStyle(a.tint)
                .lineLimit(1)
                .fixedSize()
        } else if let img = a.compactTrailingImage {
            Image(nsImage: tintImage(img, color: a.tint))
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
        }
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
