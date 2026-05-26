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
    /// Click-the-pill handler. `NotchHost` flips the panel's
    /// `ignoresMouseEvents` only when the cursor is inside the
    /// island so this tap only ever fires from a click ON the
    /// pill itself.
    var onTap: () -> Void = {}

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
                    .animation(.spring(response: 0.34,
                                       dampingFraction: 0.78),
                               value: a.id)
                    .animation(.spring(response: 0.34,
                                       dampingFraction: 0.82),
                               value: cycleSlot)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func island(
        for a: LiveActivityCoordinator.Resolved
    ) -> some View {
        let frame = Geometry.islandFrame(for: a, layout: layout)
        let totalWidth = frame.width
        let totalHeight = frame.height
        let centerX = frame.midX

        let notchW = layout.notchTrailingX - layout.notchLeadingX

        ZStack {
            IslandShape(
                punchRadius: punchRadius,
                bottomCornerRadius: bottomCornerRadius
            )
            .fill(Color.black)
            .frame(width: totalWidth, height: totalHeight)

            // Icon left, text right, notch in the middle.
            HStack(spacing: 0) {
                leadingContent(for: a)
                Spacer(minLength: notchW + notchClearance * 2)
                trailingContent(for: a)
            }
            .padding(.horizontal, contentInset)
            .frame(width: totalWidth, height: totalHeight)
        }
        .frame(width: totalWidth, height: totalHeight)
        .position(x: centerX, y: totalHeight / 2)
        // Capture taps on the entire pill — only fires when the
        // panel is in capture mode (cursor over the island), so
        // clicks elsewhere in the menu bar are unaffected.
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }


    @ViewBuilder
    private func leadingContent(
        for a: LiveActivityCoordinator.Resolved
    ) -> some View {
        if let img = a.compactLeadingImage {
            // B&W scheme — every glyph tints white, ignoring
            // the publisher's tintHex. Brand colours come back
            // later as an opt-in setting.
            Image(nsImage: tintImage(img, color: .white))
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
            // Match the system menu-bar clock — same size,
            // regular weight, default (non-rounded) design.
            // Was 13pt semibold rounded which read as
            // emphasised next to the rest of the bar.
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
        } else if let img = a.compactTrailingImage {
            Image(nsImage: tintImage(img, color: .white))
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

    /// The visible pill's frame in panel-local coordinates with
    /// the SwiftUI convention (origin top-left). The pill's
    /// left and right wings size INDEPENDENTLY to their own
    /// content — long trailing text doesn't force an empty
    /// left wing to match, and vice versa. The pill is no
    /// longer strictly centred on the notch; it grows
    /// asymmetrically into whichever side has more text.
    ///
    /// Both wings still respect `sidePad` as a minimum so a
    /// tiny icon doesn't leave the wing flush with the notch.
    static func islandFrame(
        for a: LiveActivityCoordinator.Resolved?,
        layout: NotchLayout,
        expanded: Bool = false
    ) -> CGRect {
        let notchW = layout.notchTrailingX - layout.notchLeadingX
        let leadW = leadingWidth(for: a)
        let trailW = trailingWidth(for: a)
        // Per-side minimum wing width — covers content +
        // padding to the inner side of the notch.
        let leftHalf = max(
            leadW + contentInset + notchClearance,
            sidePad)
        let rightHalf = max(
            trailW + contentInset + notchClearance,
            sidePad)
        let totalWidth = leftHalf + notchW + rightHalf
        // +1pt overlap onto the menu-bar bottom border so the
        // pill reads as flush with the menu bar — otherwise
        // anti-aliasing leaves a 1px seam.
        let totalHeight = layout.menuBarHeight + 1
        // leftEdge in panel coords = notch left minus our
        // left-wing width.
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
