import AppKit
import SwiftUI

/// Owns the borderless NSPanel that hosts Halo's island shape at
/// the top of the screen. Resolves the notch's exact geometry on
/// every screen-parameter change so the island re-anchors when
/// the user docks / undocks an external display.
///
/// Click-through across the whole window — only the island itself
/// is visible, the surrounding area is transparent. Phase 0 keeps
/// `ignoresMouseEvents = true` so the menu bar stays clickable;
/// hover-to-expand interactivity returns once we wire custom
/// hitTest geometry (Phase 2).
@MainActor
final class NotchHost: NSObject {

    let coordinator = LiveActivityCoordinator()

    private var panel: NSPanel?
    private var hostingController: NSHostingController<NotchHostRoot>?
    private var screenObserver: NSObjectProtocol?
    /// Latest cached layout — held for rebuildPanel reuse and
    /// in case we need to re-query screen geometry without
    /// hitting NSScreen.main again.
    private var currentLayout: NotchLayout?

    /// In-process feature publishers (volume, brightness, music,
    /// AirPods). Each starts/stops with the host so toggling
    /// Halo via settings shuts every system listener down too.
    private var publishers: [HaloPublisher] = []

    private(set) var isEnabled: Bool = false

    func enable() {
        guard !isEnabled else { return }
        isEnabled = true
        rebuildPanel()
        coordinator.start()
        startPublishers()
        installHoverMonitor()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildPanel() }
        }
    }

    func disable() {
        guard isEnabled else { return }
        isEnabled = false
        if let o = screenObserver {
            NotificationCenter.default.removeObserver(o)
            screenObserver = nil
        }
        uninstallHoverMonitor()
        stopPublishers()
        coordinator.stop()
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
        currentLayout = nil
    }

    // MARK: - Hover monitor + per-event mouse capture

    /// Global mouse-moved monitor. We track the cursor and
    /// flip the panel's `ignoresMouseEvents` based on whether
    /// it's currently inside the island rect. When inside,
    /// the panel captures clicks (so the user can tap to
    /// advance the cycle). When outside, the panel is fully
    /// click-through so menu-bar items stay reachable.
    private var hoverMonitor: Any?
    private var lastInsideIsland = false

    private func installHoverMonitor() {
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .mouseMoved
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshHover() }
        }
    }

    private func uninstallHoverMonitor() {
        if let m = hoverMonitor {
            NSEvent.removeMonitor(m)
            hoverMonitor = nil
        }
        lastInsideIsland = false
        panel?.ignoresMouseEvents = true
    }

    private func refreshHover() {
        guard let layout = currentLayout,
              let screen = NSScreen.main,
              let panel = panel
        else { return }
        let cursor = NSEvent.mouseLocation  // screen-space
        let panelLocal = CGPoint(
            x: cursor.x - screen.frame.minX,
            y: screen.frame.maxY - cursor.y)
        let rect = Geometry.islandFrame(
            for: coordinator.topActivity, layout: layout)
            .insetBy(dx: -6, dy: -6)
        let inside = rect.contains(panelLocal)
        guard inside != lastInsideIsland else { return }
        lastInsideIsland = inside
        // Inside → become clickable so the SwiftUI tap gesture
        // can fire. Outside → revert to click-through so the
        // panel never swallows menu-bar items.
        panel.ignoresMouseEvents = !inside
    }

    private func startPublishers() {
        // Volume HUD — gated by HaloSettings so users can opt out
        // (some pair Halo with an existing volume HUD tool).
        if HaloSettings.volumeHUDEnabled {
            let v = VolumePublisher(coordinator: coordinator)
            v.start()
            publishers.append(v)
        }
        if HaloSettings.nowPlayingEnabled {
            let n = NowPlayingPublisher(coordinator: coordinator)
            n.start()
            publishers.append(n)
        }
        if HaloSettings.brightnessHUDEnabled {
            let b = BrightnessPublisher(coordinator: coordinator)
            b.start()
            publishers.append(b)
        }
        if HaloSettings.airpodsEnabled {
            let a = AirPodsPublisher(coordinator: coordinator)
            a.start()
            publishers.append(a)
        }
        if HaloSettings.statsEnabled {
            let s = StatsPublisher(coordinator: coordinator)
            s.start()
            publishers.append(s)
        }
    }

    private func stopPublishers() {
        for p in publishers { p.stop() }
        publishers.removeAll()
    }

    /// Tear down all publishers and re-create only the ones the
    /// user currently has enabled. Called when a setting toggle
    /// flips; cheaper than per-publisher start/stop wiring and
    /// guarantees no orphan listeners.
    func restartPublishers() {
        guard isEnabled else { return }
        stopPublishers()
        startPublishers()
    }

    private func rebuildPanel() {
        guard let screen = NSScreen.main else { return }
        let layout = NotchLayout.resolve(for: screen)

        // Panel covers a tall band at the very top of the screen
        // — the island lives in the top portion, the rest is
        // transparent room for a future expanded state to grow
        // downward without resizing the window (which would
        // jitter z-order). Full screen width so the island can
        // anchor to the notch wherever it is on multi-monitor
        // setups.
        let panelRect = NSRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - layout.panelHeight,
            width: screen.frame.width,
            height: layout.panelHeight
        )

        if panel == nil {
            let p = NSPanel(
                contentRect: panelRect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.isMovable = false
            p.isFloatingPanel = true
            // .popUpMenu (101) is above status-bar items (25) so
            // a packed menu bar can't draw over the island.
            p.level = .popUpMenu
            p.collectionBehavior = [
                .canJoinAllSpaces,
                .stationary,
                .fullScreenAuxiliary,
                .ignoresCycle,
            ]
            // FULL click-through so the menu bar items behind
            // us remain interactive. Hover detection rides on
            // a global NSEvent monitor (see `installHover
            // Monitor`) — that path doesn't need the panel to
            // accept mouse events at all.
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            // Don't let AppKit clamp our frame to the screen's
            // visibleFrame (which excludes the menu-bar band) —
            // we WANT to draw over the menu-bar area.
            p.setFrame(panelRect, display: false)
            panel = p
        } else {
            panel?.setFrame(panelRect, display: false, animate: false)
        }

        let root = NotchHostRoot(
            coordinator: coordinator,
            layout: layout)

        if let hc = hostingController {
            hc.rootView = root
        } else {
            let hc = NSHostingController(rootView: root)
            hc.view.wantsLayer = true
            hc.view.layer?.backgroundColor = NSColor.clear.cgColor
            hc.view.autoresizingMask = [.width, .height]
            hostingController = hc
            panel?.contentViewController = hc
        }
        // Re-assert frames AFTER attaching the controller — the
        // contentViewController setter can shrink the window to
        // the controller's intrinsic size.
        panel?.setFrame(panelRect, display: true, animate: false)
        hostingController?.view.frame = NSRect(
            origin: .zero, size: panelRect.size)

        currentLayout = layout
        panel?.orderFrontRegardless()
    }

}

/// SwiftUI root mounted inside the NSPanel's `NSHostingController`.
struct NotchHostRoot: View {
    @Bindable var coordinator: LiveActivityCoordinator
    let layout: NotchLayout

    var body: some View {
        NotchView(
            activity: coordinator.topActivity,
            cycleSlot: coordinator.cycleIndex,
            layout: layout,
            onTap: { coordinator.advanceCycleManually() })
    }
}

/// "Where does the island sit on THIS screen" math. Notched
/// MacBooks (14"/16" Pro, MBA M2+) expose the notch's bounds via
/// `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`. Non-notched
/// displays get a 200pt phantom notch centred at top so the
/// island shape still renders in a sensible spot.
struct NotchLayout: Equatable {
    let hasNotch: Bool
    let notchLeadingX: CGFloat
    let notchTrailingX: CGFloat
    let screenWidth: CGFloat
    let menuBarHeight: CGFloat
    let panelHeight: CGFloat

    var notchWidth: CGFloat { notchTrailingX - notchLeadingX }
    var notchCenterX: CGFloat { (notchLeadingX + notchTrailingX) / 2 }

    static func resolve(for screen: NSScreen) -> NotchLayout {
        let screenWidth = screen.frame.width
        if let leftAux = screen.auxiliaryTopLeftArea,
           let rightAux = screen.auxiliaryTopRightArea {
            return NotchLayout(
                hasNotch: true,
                notchLeadingX: leftAux.maxX - screen.frame.minX,
                notchTrailingX: rightAux.minX - screen.frame.minX,
                screenWidth: screenWidth,
                menuBarHeight: leftAux.height,
                panelHeight: 200
            )
        }
        let phantom: CGFloat = 200
        return NotchLayout(
            hasNotch: false,
            notchLeadingX: (screenWidth - phantom) / 2,
            notchTrailingX: (screenWidth + phantom) / 2,
            screenWidth: screenWidth,
            menuBarHeight: 24,
            panelHeight: 200
        )
    }
}
