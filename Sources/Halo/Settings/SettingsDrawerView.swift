import AppKit
import SwiftUI

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
struct SettingsDrawerView: View {
    @State var bindings: SettingsBindings
    @Bindable var controller: DrawerController
    let onClose: () -> Void

    @State private var selection: SettingsSection = .general
    /// Horizontal offset applied to the BODY + content
    /// stack. The body starts fully off-screen to the right
    /// (`slideOffset = panelWidth`) and translates leftward
    /// to 0 (its natural position) on appear. The WINGS are
    /// rendered as a separate layer and DON'T receive this
    /// offset — they stay anchored to the screen edge for
    /// the entire animation, just like the macOS notch's
    /// top corners stay anchored during its downward expand.
    @State private var slideOffset: CGFloat = 520
    private let panelWidth: CGFloat = 520

    var body: some View {
        ZStack {
            // STICKY layer — the wing ears at the screen
            // right edge. Visible from T=0 throughout the
            // animation; they don't translate.
            WingsShape()
                .fill(Color.black)

            // SLIDING layer — the body + its content,
            // translated as a unit. The body shape provides
            // the rounded-rect background; the content
            // (sidebar + column) sits inside it. Both move
            // together so the content's positioning relative
            // to the body stays correct.
            ZStack {
                BodyShape()
                    .fill(Color.black)

                HStack(spacing: 0) {
                    sidebar
                    contentColumn
                }
                // Visible content gutters:
                //   top  28
                //   bot  28
                //   left 24
                //   right 24 (trailing 38 − wedge 14 = 24)
                // Top + bottom run a touch heavier than left
                // + right because the content has more
                // vertical real estate; the optical balance
                // reads as uniform.
                .padding(.top, 28)
                .padding(.bottom, 28)
                .padding(.leading, 12)
                .padding(.trailing, 28)
            }
            .offset(x: slideOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        // Without this, SwiftUI's safe-area insets shrink the
        // shape away from the screen edge — leaving a visible
        // gap on the right where the panel "doesn't extend".
        // The drawer's intentional flush-right alignment
        // requires drawing into the safe-area band on the
        // trailing edge.
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        // Slide the body in from off-screen-right. The wings
        // are already on-screen so the user sees the body's
        // rounded-left edge emerging from behind them, sliding
        // leftward into place — true horizontal motion, not a
        // shape morph.
        .onAppear {
            withAnimation(.easeOut(duration: 0.34)) {
                slideOffset = 0
            }
        }
        // When the AppKit controller flips `shouldClose`
        // (from `SettingsDrawer.hide()`), slide back out
        // rightward. The AppKit side waits for this
        // animation to finish before calling `orderOut`.
        .onChange(of: controller.shouldClose) { _, close in
            guard close else { return }
            withAnimation(.easeIn(duration: 0.22)) {
                slideOffset = panelWidth
            }
        }
    }

    // MARK: Sidebar (nav rail)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { sec in
                SidebarItem(
                    section: sec,
                    isSelected: selection == sec,
                    onTap: { selection = sec })
            }
            Spacer()
            sidebarFooter
        }
        // Bumped 112 → 140 so longer section names
        // ("Extensions") render on a single line without
        // wrapping mid-word. Sidebar still feels narrow next
        // to the wider content column — the visual rail
        // proportion is preserved.
        .frame(width: 140, alignment: .leading)
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
                .padding(.vertical, 12)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    sectionContent
                }
                // .padding(.bottom, 8)
                .frame(maxWidth: .infinity,
                       alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 18pt gap between the sidebar and the content
        // column — matches the body's outer 18pt insets so
        // the whole drawer reads on a single 18pt grid.
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
        case .extensions:
            ForEach(HaloSettings.extensions) { ext in
                ExtensionToggle(extensionMeta: ext,
                                bindings: bindings)
            }
            // Footer copy that explains the framework's
            // status — first proof of concept, more coming.
            Text("Extensions are opt-in publishers that "
                 + "fetch data from the network. Future "
                 + "extensions will load from .haloext "
                 + "bundles in ~/Library/Application "
                 + "Support/Halo/Extensions.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 8)
                .padding(.horizontal, 4)
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

enum SettingsSection: String,
    Identifiable, CaseIterable
{
    case general
    case system
    case live
    case suite
    case extensions
    case about

    var id: String { rawValue }
    var label: String {
        switch self {
        case .general:    return "General"
        case .system:     return "System"
        case .live:       return "Live"
        case .suite:      return "Suite"
        case .extensions: return "Extensions"
        case .about:      return "About"
        }
    }
    var symbol: String {
        switch self {
        case .general:    return "gearshape"
        case .system:     return "slider.horizontal.3"
        case .live:       return "wave.3.right"
        case .suite:      return "square.grid.2x2"
        case .extensions: return "puzzlepiece.extension"
        case .about:      return "info.circle"
        }
    }
    var eyebrow: String {
        switch self {
        case .general:    return "OVERVIEW"
        case .system:     return "SYSTEM HUDS"
        case .live:       return "LIVE ACTIVITIES"
        case .suite:      return "MATTSSOFTWARE SUITE"
        case .extensions: return "EXTENSIONS"
        case .about:      return "ABOUT"
        }
    }
    var title: String {
        switch self {
        case .general:    return "General"
        case .system:     return "System"
        case .live:       return "Live"
        case .suite:      return "Suite apps"
        case .extensions: return "Extensions"
        case .about:      return "About Halo"
        }
    }
}
