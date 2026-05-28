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
    /// hold the 150pt sidebar + ~260pt content column with
    /// comfortable padding — a card, not a pane.
    private let width: CGFloat = 440
    /// Maximum height; clamped to screen so it never extends
    /// past the visible area on a 13" laptop screen.
    private let maxHeight: CGFloat = 720
    /// Gap between the drawer and the screen edges (top, right,
    /// bottom). The right inset is 0 — the drawer sits flush
    /// against the right screen edge, mirroring the way the
    /// notch sits flush against the top edge.
    private let topInset: CGFloat = 0
    private let bottomInset: CGFloat = 24

    private var panel: NSPanel?
    private weak var notchHost: NotchHost?
    /// Monitors that auto-dismiss the drawer: clicking outside
    /// the panel, or pressing Escape while the panel is up.
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?

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
            screen.frame.height - topInset - bottomInset)
        let onX = screen.frame.maxX - width
        let offX = screen.frame.maxX
        // Anchor at the very top of the screen, so the drawer
        // visually hangs from the top edge like the notch does.
        let y = screen.frame.maxY - h - topInset

        let p = SettingsDrawerPanel(
            contentRect: NSRect(
                x: offX, y: y,
                width: width, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        // Transparent panel chrome — the SwiftUI DrawerShape
        // does ALL of the visible shape, including the
        // notch-style concave wedge. AppKit drawing a rounded
        // rectangle for us would clip the wedge and the
        // illusion would collapse.
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

        let root = SettingsDrawerView(
            bindings: SettingsBindings(
                notchHost: notchHost!),
            onClose: { [weak self] in self?.hide() })
        p.contentViewController =
            NSHostingController(rootView: root)

        panel = p
        p.orderFrontRegardless()

        // Slide in from off-screen-right.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(
                name: .easeOut)
            ctx.allowsImplicitAnimation = true
            p.animator().setFrame(
                NSRect(x: onX, y: y,
                       width: width, height: h),
                display: true)
        }

        installDismissMonitors()
    }

    func hide() {
        guard let p = panel, let screen = NSScreen.main
        else { return }
        uninstallDismissMonitors()

        let offX = screen.frame.maxX
        let frame = p.frame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(
                name: .easeIn)
            ctx.allowsImplicitAnimation = true
            p.animator().setFrame(
                NSRect(x: offX, y: frame.minY,
                       width: frame.width,
                       height: frame.height),
                display: true)
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel = nil
        })
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

// MARK: - DrawerShape

/// Notch-sibling outline for the settings panel. The drawer
/// hangs from the screen's top-right corner the way the
/// island hangs from the top-centre: flush top + right edges
/// (against the screen), a concave wedge at the top-left
/// where the panel meets the screen interior (matching the
/// island's wing concaves), rounded bottom-left + bottom-right
/// corners (matching the island's `bottomCornerRadius`).
///
/// Trace order is counter-clockwise from the top-left wedge
/// start so the winding matches `IslandShape`. SwiftUI's
/// `clockwise:` flag uses math-y-up convention internally, so
/// counter-clockwise-on-screen reads as `clockwise: false`
/// here (see `IslandShape` for the same parity).
private struct DrawerShape: Shape {
    /// Concave-wedge radius at the top-left corner. Matches
    /// `Geometry.punchRadius` so the wedge reads as a sibling
    /// of the notch's own wings.
    var topLeftConcaveRadius: CGFloat = 14
    /// Convex-corner radius at the bottom-left and
    /// bottom-right. Larger than the wedge so the drawer feels
    /// solid where it isn't against a screen edge.
    var bottomCornerRadius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cr = topLeftConcaveRadius
        let br = min(bottomCornerRadius, h / 2)

        var p = Path()

        // Start at the top edge where the concave wedge begins,
        // tracing counter-clockwise.
        p.move(to: CGPoint(x: cr, y: 0))

        // Concave wedge at top-left. Masking circle centred at
        // the corner (0, 0); arc bulges INTO the drawer
        // between (cr, 0) on the top edge and (0, cr) on the
        // left edge. The arc passes through (~0.71cr, ~0.71cr)
        // — inside the drawer — so the outline recesses at
        // the corner.
        p.addArc(
            center: CGPoint(x: 0, y: 0),
            radius: cr,
            startAngle: .degrees(0),     // (cr, 0)
            endAngle: .degrees(90),      // (0, cr)
            clockwise: false)            // through 45°

        // Left edge straight down to the bottom-left rounded
        // corner.
        p.addLine(to: CGPoint(x: 0, y: h - br))

        // Bottom-left convex rounded corner — same direction
        // as `IslandShape`'s bottom-left wedge, so the visual
        // weight is consistent.
        p.addArc(
            center: CGPoint(x: br, y: h - br),
            radius: br,
            startAngle: .degrees(180),   // (0, h - br)
            endAngle: .degrees(90),      // (br, h)
            clockwise: true)             // through 135°

        // Bottom edge.
        p.addLine(to: CGPoint(x: w - br, y: h))

        // Bottom-right convex rounded corner. Same radius as
        // the bottom-left so the drawer feels balanced even
        // though only one of these meets the screen edge.
        p.addArc(
            center: CGPoint(x: w - br, y: h - br),
            radius: br,
            startAngle: .degrees(90),    // (w - br, h)
            endAngle: .degrees(0),       // (w, h - br)
            clockwise: true)             // through 45°

        // Right edge straight up to the top-right corner.
        // Sharp corner here — the drawer sits flush against
        // the screen's right edge, so any rounding would be
        // clipped (and would look odd against the menu bar
        // band above).
        p.addLine(to: CGPoint(x: w, y: 0))

        // Top edge back to the wedge start.
        p.addLine(to: CGPoint(x: cr, y: 0))

        p.closeSubpath()
        return p
    }
}

// MARK: - Bindings

/// Bundles every UserDefaults toggle the drawer mutates into
/// one observable object so the SwiftUI view can read / write
/// without each row needing its own custom Binding factory.
@MainActor
@Observable
final class SettingsBindings {
    private weak var notchHost: NotchHost?

    init(notchHost: NotchHost) {
        self.notchHost = notchHost
    }

    var enabled: Bool {
        get { HaloSettings.enabled }
        set {
            HaloSettings.setEnabled(newValue)
            if newValue { notchHost?.enable() }
            else { notchHost?.disable() }
        }
    }
    var symmetry: Bool {
        get { HaloSettings.symmetryEnabled }
        set {
            HaloSettings.setSymmetryEnabled(newValue)
            // Symmetry affects the island's frame math — poke
            // the coordinator so SwiftUI re-runs `islandFrame`
            // and the pill resizes on the next tick.
            notchHost?.coordinator.refreshNow()
        }
    }
    var volume: Bool {
        get { HaloSettings.volumeHUDEnabled }
        set {
            HaloSettings.setVolumeHUDEnabled(newValue)
            notchHost?.restartPublishers()
        }
    }
    var brightness: Bool {
        get { HaloSettings.brightnessHUDEnabled }
        set {
            HaloSettings.setBrightnessHUDEnabled(newValue)
            notchHost?.restartPublishers()
        }
    }
    var nowPlaying: Bool {
        get { HaloSettings.nowPlayingEnabled }
        set {
            HaloSettings.setNowPlayingEnabled(newValue)
            notchHost?.restartPublishers()
        }
    }
    var airpods: Bool {
        get { HaloSettings.airpodsEnabled }
        set {
            HaloSettings.setAirpodsEnabled(newValue)
            notchHost?.restartPublishers()
        }
    }
    var bluetoothAudio: Bool {
        get { HaloSettings.bluetoothAudioEnabled }
        set {
            HaloSettings.setBluetoothAudioEnabled(newValue)
            notchHost?.restartPublishers()
        }
    }
    var stats: Bool {
        get { HaloSettings.statsEnabled }
        set {
            HaloSettings.setStatsEnabled(newValue)
            notchHost?.restartPublishers()
        }
    }
    var battery: Bool {
        get { HaloSettings.batteryEnabled }
        set {
            HaloSettings.setBatteryEnabled(newValue)
            notchHost?.restartPublishers()
        }
    }
    var vpn: Bool {
        get { HaloSettings.vpnEnabled }
        set {
            HaloSettings.setVPNEnabled(newValue)
            notchHost?.restartPublishers()
        }
    }
    var calendar: Bool {
        get { HaloSettings.calendarEnabled }
        set {
            HaloSettings.setCalendarEnabled(newValue)
            notchHost?.restartPublishers()
        }
    }
    var github: Bool {
        get { HaloSettings.githubEnabled }
        set {
            HaloSettings.setGithubEnabled(newValue)
            notchHost?.restartPublishers()
        }
    }
    var docker: Bool {
        get { HaloSettings.dockerEnabled }
        set {
            HaloSettings.setDockerEnabled(newValue)
            notchHost?.restartPublishers()
        }
    }

    func suiteSlotEnabled(_ id: String) -> Bool {
        HaloSettings.suiteSlotEnabled(id)
    }
    func setSuiteSlotEnabled(_ id: String, _ on: Bool) {
        HaloSettings.setSuiteSlotEnabled(id, on)
        notchHost?.coordinator.refreshNow()
    }
}

// MARK: - View

/// Settings drawer content, modelled after Libre.academy's
/// sidebar + content layout (which mirrors the Base UI
/// `NavSidebar` primitive at narrower dimensions).
///
/// Two columns: a 150pt nav rail on the left listing the
/// sections, an article-style content column on the right
/// with eyebrow + title + scrollable body. Pure-monochrome
/// styling — selected nav items get a soft 6%-white fill and
/// a weight bump, nothing accent-coloured. Hairline dividers
/// only where a `Divider` is structurally necessary (under
/// the article header). No panel outline.
private struct SettingsDrawerView: View {
    @State var bindings: SettingsBindings
    let onClose: () -> Void

    @State private var selection: SettingsSection = .general

    var body: some View {
        ZStack {
            // OLED black, masked to the notch-sibling shape so
            // the panel reads as a single shaped surface, not a
            // rectangle with rounded corners. The drawer's
            // NSPanel itself is transparent — this is the only
            // visible chrome.
            DrawerShape()
                .fill(Color.black)

            HStack(spacing: 0) {
                sidebar
                contentColumn
            }
            // Pad in from the shape's edges. The concave
            // top-left wedge means content needs more leading
            // padding at the top — 18pt clears the curve at
            // any reasonable cr value (14).
            .padding(.top, 18)
            .padding(.bottom, 22)
            .padding(.leading, 18)
            .padding(.trailing, 18)
        }
        .clipShape(DrawerShape())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }

    // MARK: Sidebar (nav rail)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            sidebarHeader
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSection.allCases) { sec in
                    SidebarItem(
                        section: sec,
                        isSelected: selection == sec,
                        onTap: { selection = sec })
                }
            }
            Spacer()
            sidebarFooter
        }
        .frame(width: 150, alignment: .leading)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 11,
                              weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text("HALO")
                .font(.system(size: 11,
                              weight: .bold))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
                .overlay(Color.white.opacity(0.08))
                .padding(.horizontal, 4)
            HStack(spacing: 6) {
                Text("v\(appVersion)")
                    .font(.system(size: 10,
                                  weight: .medium,
                                  design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                Button(action: { NSApp.terminate(nil) }) {
                    Text("Quit")
                        .font(.system(size: 10,
                                      weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Quit Halo")
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: Content column

    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            contentHeader
            Divider()
                .overlay(Color.white.opacity(0.08))
                .padding(.vertical, 14)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    sectionContent
                }
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 18)
    }

    private var contentHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selection.eyebrow)
                    .font(.system(size: 10,
                                  weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.45))
                Text(selection.title)
                    .font(.system(size: 22,
                                  weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(.white)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9,
                                  weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selection {
        case .general:
            DrawerToggle(
                title: "Show the island",
                subtitle: "When off, every publisher stops listening.",
                symbol: "circle.dashed",
                isOn: $bindings.enabled)
            DrawerToggle(
                title: "Symmetry mode",
                subtitle: "Match both wings to the wider side so the pill stays visually centred.",
                symbol: "rectangle.split.2x1",
                isOn: $bindings.symmetry)
        case .system:
            DrawerToggle(
                title: "Volume HUD",
                subtitle: "Show level on every change.",
                symbol: "speaker.wave.2.fill",
                isOn: $bindings.volume)
            DrawerToggle(
                title: "Brightness HUD",
                subtitle: "Show level on every change.",
                symbol: "sun.max.fill",
                isOn: $bindings.brightness)
            DrawerToggle(
                title: "Battery",
                subtitle: "Low / charging / full state.",
                symbol: "battery.100",
                isOn: $bindings.battery)
            DrawerToggle(
                title: "System stats",
                subtitle: "CPU / RAM / Disk rotation.",
                symbol: "cpu",
                isOn: $bindings.stats)
        case .live:
            DrawerToggle(
                title: "Now Playing",
                subtitle: "Track info from any media app.",
                symbol: "music.note",
                isOn: $bindings.nowPlaying)
            DrawerToggle(
                title: "AirPods",
                subtitle: "Per-bud battery + charging.",
                symbol: "airpods",
                isOn: $bindings.airpods)
            DrawerToggle(
                title: "Bluetooth audio",
                subtitle: "Speakers + headphones detail.",
                symbol: "hifispeaker.fill",
                isOn: $bindings.bluetoothAudio)
            DrawerToggle(
                title: "VPN",
                subtitle: "Connection + tunnel state.",
                symbol: "lock.shield.fill",
                isOn: $bindings.vpn)
            DrawerToggle(
                title: "Calendar",
                subtitle: "Countdown to next event.",
                symbol: "calendar",
                isOn: $bindings.calendar)
            DrawerToggle(
                title: "GitHub",
                subtitle: "Open PR notifications.",
                symbol: "arrow.triangle.pull",
                isOn: $bindings.github)
            DrawerToggle(
                title: "Docker",
                subtitle: "Running container count.",
                symbol: "shippingbox.fill",
                isOn: $bindings.docker)
        case .suite:
            ForEach(HaloSettings.suiteSlots) { slot in
                SuiteToggle(slot: slot,
                            bindings: bindings)
            }
        case .about:
            aboutContent
        }
    }

    private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Halo")
                .font(.system(size: 28,
                              weight: .black))
                .foregroundStyle(.white)
            Text("Version \(appVersion)")
                .font(.system(size: 11,
                              design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
            Text("The MattsSoftware Dynamic Island for the MacBook notch. Publishers stream live state from suite apps + system integrations into the pill at the top of your screen.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false,
                           vertical: true)
                .padding(.top, 4)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?[
            "CFBundleShortVersionString"
        ] as? String ?? "—"
    }
}

// MARK: - Section enum

private enum SettingsSection: String,
    Identifiable, CaseIterable
{
    case general
    case system
    case live
    case suite
    case about

    var id: String { rawValue }
    var label: String {
        switch self {
        case .general: return "General"
        case .system:  return "System"
        case .live:    return "Live"
        case .suite:   return "Suite"
        case .about:   return "About"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .system:  return "slider.horizontal.3"
        case .live:    return "wave.3.right"
        case .suite:   return "square.grid.2x2"
        case .about:   return "info.circle"
        }
    }
    var eyebrow: String {
        switch self {
        case .general: return "OVERVIEW"
        case .system:  return "SYSTEM HUDS"
        case .live:    return "LIVE ACTIVITIES"
        case .suite:   return "MATTSSOFTWARE SUITE"
        case .about:   return "ABOUT"
        }
    }
    var title: String {
        switch self {
        case .general: return "General"
        case .system:  return "System"
        case .live:    return "Live"
        case .suite:   return "Suite apps"
        case .about:   return "About Halo"
        }
    }
}

// MARK: - Sidebar item

/// Single nav-rail row. Selected = 6%-white fill + 0.98-white
/// label at weight .semibold. Hover lifts to the same fill
/// but keeps the .regular weight, so the selected state
/// reads through the bump alone. No accent color, no left
/// bar, no border — Libre.academy's monochrome treatment.
private struct SidebarItem: View {
    let section: SettingsSection
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: section.symbol)
                    .font(.system(size: 11,
                                  weight: isSelected
                                    ? .semibold
                                    : .regular))
                    .frame(width: 14, height: 14)
                Text(section.label)
                    .font(.system(
                        size: 13,
                        weight: isSelected
                            ? .semibold
                            : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(
                (isSelected || isHovered)
                    ? .white
                    : .white.opacity(0.71))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6,
                                 style: .continuous)
                    .fill(
                        (isSelected || isHovered)
                            ? Color.white.opacity(0.06)
                            : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Toggle row

/// Content-column toggle row. Flush against the column — no
/// surrounding card. Title + subtitle stack on the left, an
/// SF Symbol leading the row, switch on the right. Tracks the
/// Libre.academy treatment: monochrome, hairline only when
/// structurally required, weight bump for the active state.
private struct DrawerToggle: View {
    let title: String
    let subtitle: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13,
                                  weight: .medium))
                    .foregroundStyle(
                        .white.opacity(isOn ? 0.85 : 0.5))
                    .frame(width: 18, height: 18,
                           alignment: .center)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13,
                                      weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(
                            .white.opacity(0.5))
                        .fixedSize(horizontal: false,
                                   vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(.white.opacity(0.85))
        .padding(.vertical, 6)
    }
}

/// Suite-slot variant of the toggle that reads / writes
/// through `SettingsBindings.suiteSlotEnabled` so updates
/// immediately poke the coordinator (otherwise the new
/// visibility waits up to a second for the next 1Hz poll).
private struct SuiteToggle: View {
    let slot: SuiteSlot
    let bindings: SettingsBindings

    @State private var isOn: Bool

    init(slot: SuiteSlot, bindings: SettingsBindings) {
        self.slot = slot
        self.bindings = bindings
        _isOn = State(initialValue:
            bindings.suiteSlotEnabled(slot.id))
    }

    var body: some View {
        DrawerToggle(
            title: slot.title,
            subtitle: slot.subtitle,
            symbol: slot.symbol,
            isOn: Binding(
                get: { isOn },
                set: { v in
                    isOn = v
                    bindings.setSuiteSlotEnabled(
                        slot.id, v)
                }))
    }
}
