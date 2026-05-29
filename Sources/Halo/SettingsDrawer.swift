import AppKit
import SwiftUI

/// Slide-in settings drawer pinned to the screen's right edge.
/// Shaped like a vertical sibling of the notch — concave wedge
/// at the top-left where it meets the screen interior + rounded
/// bottom corners + a flush top + right against the screen
/// edges. OLED-pure-black surface, no borders, no edge glow:
/// the shape and the layered content sell it without
/// outlines.
///
/// Sized as a card (440×720, capped to screen height − inset)
/// rather than a full-screen pane — feels transient and
/// scoped, which matches how settings are typically a
/// glance-and-go interaction rather than a long session.
///
/// Lifecycle: `show()` creates the panel just off-screen at
/// `screen.maxX` and animates it leftward to its docked
/// position; `hide()` reverses. Borderless,
/// non-activating so the app focus stays on whatever the user
/// was just doing.
@MainActor
final class SettingsDrawer {
    /// Pixel width of the drawer when fully open. Sized to
    /// hold the 140pt sidebar + ~340pt content column with
    /// comfortable padding — a card, not a pane. Bumped
    /// from 440 → 520 so the content column doesn't crush
    /// the toggle rows' titles, and the sidebar has the
    /// width it needs to render "Extensions" without
    /// wrapping.
    private let width: CGFloat = 520
    /// Maximum height; clamped to screen so it never extends
    /// past the visible area on a 13" laptop screen.
    private let maxHeight: CGFloat = 720
    /// Minimum padding above the drawer's top edge + below
    /// its bottom edge when vertically centred. Keeps the
    /// drawer floating in the screen's middle band instead of
    /// crashing into the menu bar at the top or the dock at
    /// the bottom.
    private let verticalEdgeInset: CGFloat = 40

    private var panel: NSPanel?
    private weak var notchHost: NotchHost?
    /// Monitors that auto-dismiss the drawer: clicking outside
    /// the panel, or pressing Escape while the panel is up.
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    /// Shared state between AppKit (this class) + SwiftUI
    /// (the drawer view). Flipping `shouldClose` from
    /// `hide()` triggers the SwiftUI close animation; the
    /// view's `onChange` observer drives `openProgress`
    /// back to 0 inside a `withAnimation` block.
    private let controller = DrawerController()

    init(notchHost: NotchHost) {
        self.notchHost = notchHost
    }

    var isOpen: Bool { panel != nil }

    /// Toggle: if the drawer is already up, slide it out;
    /// otherwise create + slide in.
    func toggle() {
        if isOpen { hide() } else { show() }
    }

    func show() {
        if isOpen { return }
        guard let screen = NSScreen.main else { return }

        let h = min(
            maxHeight,
            screen.frame.height - verticalEdgeInset * 2)
        let onX = screen.frame.maxX - width
        // Vertically centre the drawer in the screen — sits
        // in the middle band, flush against the right edge
        // (top + bottom corners both meet the screen edge
        // there). The notch is horizontally centred on the
        // top edge; the drawer is the 90°-rotated sibling
        // vertically centred on the right edge.
        let y = screen.frame.minY
            + (screen.frame.height - h) / 2

        // Create the panel AT its final frame, not off-screen
        // — animating NSWindow.setFrame interpolates width +
        // height + origin together and ends up stretching the
        // SwiftUI shape (the DrawerShape's Path depends on
        // rect dimensions, so a transitional frame would
        // re-draw the wedges at the wrong proportions, making
        // the panel appear to "grow tall" as it slides in).
        // The slide is implemented via a Core Animation
        // translation on the contentView layer below — the
        // panel itself stays at its docked frame the whole
        // time, only its rendered content moves.
        let p = SettingsDrawerPanel(
            contentRect: NSRect(
                x: onX, y: y,
                width: width, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        // Transparent panel chrome — the SwiftUI DrawerShape
        // does ALL of the visible shape, including the
        // notch-style concave wedges. AppKit drawing a
        // rounded rectangle for us would clip the wedges and
        // the illusion would collapse.
        p.hasShadow = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
        ]
        p.isReleasedWhenClosed = false

        // Reset the controller's close flag so the view's
        // onChange doesn't immediately trigger a close from
        // a stale value (would happen on a re-show after a
        // previous hide).
        controller.shouldClose = false
        let root = SettingsDrawerView(
            bindings: SettingsBindings(
                notchHost: notchHost!),
            controller: controller,
            onClose: { [weak self] in self?.hide() })
        p.contentViewController =
            NSHostingController(rootView: root)

        // Explicitly set the frame AFTER creation. NSPanel's
        // contentRect-based initializer sometimes adjusts the
        // frame (safe-area / menu-bar interplay on notched
        // displays); a direct setFrame call guarantees the
        // top-right corner is exactly at the screen's
        // top-right corner with no inset.
        p.setFrame(
            NSRect(x: onX, y: y,
                   width: width, height: h),
            display: false)

        panel = p
        p.orderFrontRegardless()

        // No layer-translation animation here — the open
        // animation is driven entirely by the SwiftUI shape
        // morph on `DrawerShape.openProgress`. The panel
        // stays at its final frame, the wedges stay anchored
        // to the screen right edge, and the body extends
        // LEFTWARD as openProgress animates from 0 → 1.

        installDismissMonitors()
    }

    // (animateContentSlide removed — the open/close animation
    // is now driven entirely by the SwiftUI shape morph on
    // `DrawerShape.openProgress`. See `show()` / `hide()`.)

    func hide() {
        guard panel != nil else { return }
        uninstallDismissMonitors()

        // Flip the controller flag — the SwiftUI view's
        // `onChange` observer notices and runs
        // `withAnimation { openProgress = 0 }`, morphing the
        // drawer back into the right-edge wing strips. Wait
        // for that animation to finish (matches the easeIn
        // 0.22s duration in the view) before tearing the
        // panel down so the user sees the close animation.
        controller.shouldClose = true
        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: 240_000_000)
            self.panel?.orderOut(nil)
            self.panel = nil
        }
    }

    // MARK: - Dismiss-on-outside-tap + escape

    private func installDismissMonitors() {
        // Global monitor — catches clicks on OTHER apps and
        // dismisses. Doesn't fire for clicks on our own panel
        // (good — those stay interactive).
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
        // Local monitor — Escape dismisses while the drawer is
        // focused.
        keyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            if event.keyCode == 53 {  // kVK_Escape
                Task { @MainActor in self?.hide() }
                return nil
            }
            return event
        }
    }

    private func uninstallDismissMonitors() {
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }
}

/// NSPanel subclass that opts INTO becoming key — borderless
/// panels normally refuse, which would block keyboard input
/// for the toggles and text fields inside the drawer.
/// `.nonactivatingPanel` still suppresses focus-steal on the
/// host app.
private final class SettingsDrawerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Bridge between the AppKit `SettingsDrawer` controller and
/// the SwiftUI `SettingsDrawerView`. Lets `hide()` (called
/// from outside the SwiftUI tree) trigger the reverse-open
/// animation inside SwiftUI by flipping `shouldClose` —
/// the view's `onChange` observer notices and runs
/// `withAnimation { openProgress = 0 }`.
@MainActor
@Observable
final class DrawerController {
    /// Flipped to `true` by `SettingsDrawer.hide()` so the
    /// SwiftUI view knows to morph the drawer closed.
    var shouldClose: Bool = false
}
