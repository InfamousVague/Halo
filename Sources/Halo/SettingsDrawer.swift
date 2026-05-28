import AppKit
import SwiftUI

/// Slide-in settings drawer pinned to the screen's right edge.
/// Mirrors the island's visual language — OLED black surface,
/// thin specular accent down the leading edge, soft inner glow,
/// dim eyebrows over bright primary text. Drops out the legacy
/// `NSWindow + TabView` settings sheet in favour of something
/// that reads as part of the island, not part of System
/// Settings.
///
/// Lifecycle: `show()` creates the panel just off-screen at
/// `screen.maxX` and animates it leftward to `maxX - width`.
/// `hide()` reverses. The drawer is borderless / non-activating
/// so opening it doesn't steal focus from whatever the user was
/// just doing (a key consideration for a quick-access settings
/// drawer that needs to feel transient).
@MainActor
final class SettingsDrawer {
    /// Pixel width of the drawer when fully open. Calibrated to
    /// fit two columns of feature toggles with comfortable
    /// breathing room — narrower than a Settings.app pane,
    /// wider than a popover.
    private let width: CGFloat = 380

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

        // Match the screen we're docked on so the slide-in
        // lands at the right physical edge regardless of
        // which display has the menu bar. Inset 24pt off the
        // top + bottom so the drawer floats inside the
        // screen frame instead of meeting the very corners.
        let topInset: CGFloat = 24
        let bottomInset: CGFloat = 24
        let h = screen.frame.height
            - topInset - bottomInset
        let onX = screen.frame.maxX - width
        let offX = screen.frame.maxX
        let y = screen.frame.minY + bottomInset

        let p = SettingsDrawerPanel(
            contentRect: NSRect(
                x: offX, y: y,
                width: width, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.hasShadow = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
        ]
        p.isReleasedWhenClosed = false
        // Round the visible corners — straight where it meets
        // the screen edge, rounded on the inside-facing side.
        p.contentView?.wantsLayer = true
        p.contentView?.layer?.cornerRadius = 14
        p.contentView?.layer?.maskedCorners = [
            .layerMinXMinYCorner,
            .layerMinXMaxYCorner,
        ]
        p.contentView?.layer?.masksToBounds = true

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
        // focused. Returning nil swallows the event so it
        // doesn't propagate to whatever the focused control was.
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
/// for the toggles and text fields inside the drawer. Returning
/// `true` for both `canBecomeKey` and `canBecomeMain` keeps the
/// drawer responsive without re-activating the host app
/// (`.nonactivatingPanel` still suppresses the focus steal).
private final class SettingsDrawerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Bindings

/// Bundles every UserDefaults toggle the drawer mutates into
/// one observable object so the SwiftUI view can read / write
/// without each row needing its own custom Binding factory.
/// Mirrors the legacy SettingsView's plumbing but as a typed
/// observable instead of seven separate `@Binding<Bool>` args.
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

/// SwiftUI root of the drawer. OLED-black surface, a thin
/// glowing trace down the leading edge that picks up the same
/// design language as the island's screen-top accent, and
/// section blocks that mirror the expanded-card visual
/// hierarchy (dim eyebrows, bright primary text, faint surface
/// tiles for rows).
private struct SettingsDrawerView: View {
    @State var bindings: SettingsBindings
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            // Base OLED layer — pure black for proper contrast
            // with the white-on-black design system, and so the
            // pixel switch-off on OLED displays really kicks in.
            Color.black
                .ignoresSafeArea()

            // Soft inner glow on the leading edge. Reads as a
            // gentle highlight where the drawer meets the
            // screen interior — same trick the island's
            // bottom-corner radius does at a smaller scale.
            LinearGradient(
                colors: [
                    Color.white.opacity(0.06),
                    Color.white.opacity(0.0),
                ],
                startPoint: .leading,
                endPoint: .center
            )
            .frame(width: 60)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                    .overlay(Color.white.opacity(0.08))
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading,
                           spacing: 22) {
                        generalSection
                        systemHUDsSection
                        liveSection
                        suiteSection
                        aboutSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 18)
                }
            }
        }
        .overlay(alignment: .leading) {
            // 1pt glowing trace down the leading edge.
            // Two layers — a sharp inner stroke for the
            // hairline and a softer outer shadow for the
            // bloom. Matches the screen-top accent's stroke
            // weight so the drawer reads as continuous with
            // the island visual language.
            Rectangle()
                .fill(LinearGradient(
                    colors: [
                        Color.white.opacity(0.08),
                        Color(red: 0.55, green: 0.65,
                              blue: 1.0).opacity(0.55),
                        Color.white.opacity(0.08),
                    ],
                    startPoint: .top,
                    endPoint: .bottom))
                .frame(width: 1)
                .shadow(color: Color(red: 0.55,
                                     green: 0.65,
                                     blue: 1.0)
                                    .opacity(0.45),
                        radius: 6, x: 2, y: 0)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .leading)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .strokeBorder(LinearGradient(
                        colors: [
                            Color.white.opacity(0.4),
                            Color.white.opacity(0.05),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing),
                                  lineWidth: 1)
                    .frame(width: 22, height: 22)
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11,
                                  weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("HALO")
                    .font(.system(size: 10,
                                  weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.55))
                Text("Settings")
                    .font(.system(size: 17,
                                  weight: .semibold))
                    .foregroundStyle(.white)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10,
                                  weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: Sections

    private var generalSection: some View {
        Section(eyebrow: "GENERAL") {
            DrawerToggle(
                title: "Show the island",
                subtitle: "When off, every publisher stops listening too.",
                symbol: "circle.dashed",
                isOn: $bindings.enabled)
        }
    }

    private var systemHUDsSection: some View {
        Section(eyebrow: "SYSTEM HUDS") {
            DrawerToggle(
                title: "Volume",
                subtitle: "Show level on every change",
                symbol: "speaker.wave.2.fill",
                isOn: $bindings.volume)
            DrawerToggle(
                title: "Brightness",
                subtitle: "Show level on every change",
                symbol: "sun.max.fill",
                isOn: $bindings.brightness)
            DrawerToggle(
                title: "Battery",
                subtitle: "Low / charging / full state",
                symbol: "battery.100",
                isOn: $bindings.battery)
        }
    }

    private var liveSection: some View {
        Section(eyebrow: "LIVE") {
            DrawerToggle(
                title: "Now Playing",
                subtitle: "Track from any media app",
                symbol: "music.note",
                isOn: $bindings.nowPlaying)
            DrawerToggle(
                title: "AirPods",
                subtitle: "Per-bud battery + charging",
                symbol: "airpods",
                isOn: $bindings.airpods)
            DrawerToggle(
                title: "Bluetooth audio",
                subtitle: "Speakers + headphones detail",
                symbol: "hifispeaker.fill",
                isOn: $bindings.bluetoothAudio)
            DrawerToggle(
                title: "Stats",
                subtitle: "CPU / RAM / Disk rotation",
                symbol: "cpu",
                isOn: $bindings.stats)
            DrawerToggle(
                title: "VPN",
                subtitle: "Connection + tunnel state",
                symbol: "lock.shield.fill",
                isOn: $bindings.vpn)
            DrawerToggle(
                title: "Calendar",
                subtitle: "Countdown to next event",
                symbol: "calendar",
                isOn: $bindings.calendar)
            DrawerToggle(
                title: "GitHub",
                subtitle: "Open PR notifications",
                symbol: "arrow.triangle.pull",
                isOn: $bindings.github)
            DrawerToggle(
                title: "Docker",
                subtitle: "Running container count",
                symbol: "shippingbox.fill",
                isOn: $bindings.docker)
        }
    }

    private var suiteSection: some View {
        Section(eyebrow: "MATTSSOFTWARE APPS") {
            ForEach(HaloSettings.suiteSlots) { slot in
                SuiteToggle(slot: slot,
                            bindings: bindings)
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ABOUT")
                .font(.system(size: 10,
                              weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.45))
                .padding(.bottom, 4)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Halo")
                        .font(.system(size: 13,
                                      weight: .semibold))
                        .foregroundStyle(.white)
                    Text("v\(appVersion)")
                        .font(.system(size: 11,
                                      design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Button("Quit Halo") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11,
                              weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.08)))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.12),
                                lineWidth: 0.5))
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8,
                                 style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: 8,
                            style: .continuous)
                            .stroke(
                                Color.white.opacity(0.08),
                                lineWidth: 0.5)))
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?[
            "CFBundleShortVersionString"
        ] as? String ?? "—"
    }
}

// MARK: - Section / row primitives

/// Eyebrow-titled block. Eyebrows are 50% white tracked-out
/// caps so the section heading reads as label, not data.
private struct Section<Content: View>: View {
    let eyebrow: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow)
                .font(.system(size: 10,
                              weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.45))
                .padding(.bottom, 2)
            VStack(spacing: 4) {
                content()
            }
        }
    }
}

/// One row inside a section. Icon + title + subtitle + toggle,
/// rendered on a faint white-on-black surface tile that matches
/// the expanded-card row styling.
private struct DrawerToggle: View {
    let title: String
    let subtitle: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12,
                                      weight: .medium))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(
                            .white.opacity(0.5))
                        .lineLimit(1)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Color(red: 0.55, green: 0.65, blue: 1.0))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8,
                             style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(
                        cornerRadius: 8,
                        style: .continuous)
                        .stroke(Color.white.opacity(0.06),
                                lineWidth: 0.5)))
    }
}

/// Suite-slot variant of the toggle that reads / writes through
/// `SettingsBindings.suiteSlotEnabled` so updates immediately
/// poke the coordinator (otherwise the new visibility waits up
/// to a second for the next 1Hz poll).
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
