import SwiftUI

/// The Dynamic Island shape itself. Hangs from the top of the
/// screen — top edge flush with `y = 0` so the island reads as a
/// natural extension of the menu-bar / notch band rather than a
/// floating card.
///
/// Geometry:
///   • Top corners: small radius (4pt) so the shape looks like it
///     comes FROM the screen edge rather than starting at it with
///     a hard 90° corner. Squircle/continuous style matches macOS
///     window chrome.
///   • Bottom corners: larger radius (14pt) so the bottom reads
///     unmistakeably as a hanging panel.
///   • Width: ~60pt wider than the notch (≈30pt on each side).
///   • Height: just enough to clear the menu bar + a small tray
///     for icon + text. Phase 2 adds the expanded state that grows
///     downward when the user hovers.
///
///        ─ screen edge ─
///       ╭───────────────╮       ← small top radius
///       │   ☕    ON    │       ← compact slot: icon left, text right
///       ╰───────────────╯       ← bigger bottom radius
struct NotchView: View {
    var activities: [LiveActivityCoordinator.Resolved]
    var layout: NotchLayout

    /// How far the island extends past the notch's edges on each
    /// side. Keep this small enough to not crowd the leftmost
    /// status-bar items.
    private let sidePad: CGFloat = 30
    /// How far below the menu-bar bottom the island hangs in the
    /// compact state. The visible "tray" lives in this band.
    private let extensionBelow: CGFloat = 16
    private let topCornerRadius: CGFloat = 4
    private let bottomCornerRadius: CGFloat = 14

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Transparent backdrop — the host panel is screen-wide
            // but only the island shape itself draws pixels.
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

    // MARK: - Island

    @ViewBuilder
    private func island(
        for a: LiveActivityCoordinator.Resolved
    ) -> some View {
        let totalWidth =
            (layout.notchTrailingX - layout.notchLeadingX) + sidePad * 2
        let totalHeight = layout.menuBarHeight + extensionBelow
        let leftEdge = layout.notchLeadingX - sidePad
        let trayTopInset = layout.menuBarHeight

        ZStack(alignment: .top) {
            UnevenRoundedRectangle(
                topLeadingRadius: topCornerRadius,
                bottomLeadingRadius: bottomCornerRadius,
                bottomTrailingRadius: bottomCornerRadius,
                topTrailingRadius: topCornerRadius,
                style: .continuous
            )
            .fill(Color.black)
            .frame(width: totalWidth, height: totalHeight)

            // Content lives in the "tray" band — below the
            // menu-bar level so it doesn't clash with the hardware
            // notch above. Icon left, text right.
            HStack(spacing: 0) {
                leadingContent(for: a)
                Spacer(minLength: 8)
                trailingContent(for: a)
            }
            .padding(.horizontal, 12)
            .frame(width: totalWidth, height: extensionBelow)
            .offset(y: trayTopInset)
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
                .frame(width: 12, height: 12)
        }
    }

    @ViewBuilder
    private func trailingContent(
        for a: LiveActivityCoordinator.Resolved
    ) -> some View {
        if let text = a.compactTrailingText {
            Text(text)
                .font(.system(size: 10, weight: .semibold,
                              design: .rounded))
                .foregroundStyle(a.tint)
                .lineLimit(1)
                .fixedSize()
        } else if let img = a.compactTrailingImage {
            Image(nsImage: tintImage(img, color: a.tint))
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
        }
    }

    /// Paint a template NSImage with the activity's tint colour.
    /// SF Symbols + PNG templates arrive as alpha masks; without
    /// this they'd render in the default content colour and lose
    /// the publisher's brand hue.
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
