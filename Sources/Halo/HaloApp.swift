import AppKit
import SwiftUI

/// Halo — the MattsSoftware suite's Dynamic Island for the
/// MacBook notch. Standalone LSUIElement agent that owns the
/// notch-pinned overlay window + the `LiveActivityCoordinator`
/// that aggregates payloads from every suite app (and any
/// third-party publisher) into a single island shape.
///
/// Conceptually a peer of Worktree / Seasick rather than a
/// SuiteKit pane — Halo runs in its own process always, so the
/// island stays alive whether or not the launcher popover is
/// open.
@main
struct HaloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// Always false — the binding lets us keep the scene so
    /// SwiftUI bootstraps the AppDelegate adaptor (a Settings-
    /// only scene won't fire it on macOS 26 / Tahoe), but the
    /// menu-bar item itself stays hidden. Halo's settings get
    /// surfaced through the MattsSoftware launcher instead.
    @State private var menuBarVisible = false

    var body: some Scene {
        MenuBarExtra("Halo", systemImage: "circle.dashed",
                     isInserted: $menuBarVisible) {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) lazy var notchHost = NotchHost()
    private var settingsWindow: NSWindow?

    override init() {
        super.init()
        NSLog("[halo] AppDelegate init")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[halo] applicationDidFinishLaunching — island enabled=\(HaloSettings.enabled)")
        NSApp.setActivationPolicy(.accessory)

        // Start the island. The host is idempotent — toggling via
        // settings just calls enable() / disable() again later.
        if HaloSettings.enabled {
            notchHost.enable()
        }

        // Cross-process settings trigger: the MattsSoftware
        // launcher posts this distributed notification when the
        // user clicks the Halo settings entry. We listen on the
        // system-wide center so the launcher (a separate
        // process) reaches us without a URL scheme or XPC. Now
        // routes through the slide-in drawer instead of the
        // legacy NSWindow so the launcher and the in-island
        // affordances open the same surface.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(
                "com.mattssoftware.halo.openSettings"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.notchHost.openSettings() }
        }
    }

    /// Show the legacy NSWindow settings sheet. Kept as a
    /// fallback the test harness can still call directly,
    /// but the user-facing entry point is now
    /// `notchHost.openSettings()` (the slide-in drawer).
    func openSettings() {
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(
            onQuit: { NSApp.terminate(nil) },
            isEnabledBinding: Binding(
                get: { [weak self] in
                    self?.notchHost.isEnabled ?? false
                },
                set: { [weak self] on in
                    if on { self?.notchHost.enable() }
                    else { self?.notchHost.disable() }
                    HaloSettings.setEnabled(on)
                }
            ),
            volumeBinding: Self.publisherBinding(
                host: self,
                get: { HaloSettings.volumeHUDEnabled },
                set: HaloSettings.setVolumeHUDEnabled),
            brightnessBinding: Self.publisherBinding(
                host: self,
                get: { HaloSettings.brightnessHUDEnabled },
                set: HaloSettings.setBrightnessHUDEnabled),
            nowPlayingBinding: Self.publisherBinding(
                host: self,
                get: { HaloSettings.nowPlayingEnabled },
                set: HaloSettings.setNowPlayingEnabled),
            airpodsBinding: Self.publisherBinding(
                host: self,
                get: { HaloSettings.airpodsEnabled },
                set: HaloSettings.setAirpodsEnabled),
            statsBinding: Self.publisherBinding(
                host: self,
                get: { HaloSettings.statsEnabled },
                set: HaloSettings.setStatsEnabled),
            // Suite-slot toggles write to UserDefaults
            // directly inside each row's binding; here we just
            // poke the coordinator to re-poll so the change
            // appears immediately (otherwise it waits up to 1s
            // for the next scheduled tick).
            onSuiteToggle: { [weak self] in
                self?.notchHost.coordinator.refreshNow()
            }
        )
        let hc = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hc)
        win.title = "Halo"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Boilerplate-free Binding factory for the per-publisher
    /// toggles. The setter writes to HaloSettings and then
    /// restarts publishers so the change takes effect immediately
    /// (the alternative is asking the user to disable/re-enable
    /// Halo, which is awful).
    private static func publisherBinding(
        host: AppDelegate,
        get: @escaping @Sendable () -> Bool,
        set: @escaping @Sendable (Bool) -> Void
    ) -> Binding<Bool> {
        Binding<Bool>(
            get: get,
            set: { [weak host] on in
                set(on)
                host?.notchHost.restartPublishers()
            }
        )
    }
}

/// Full settings window — TabView with sections for General,
/// Features (Halo's built-in publishers), Suite (per-suite-app
/// visibility), and About. Designed to look at home next to
/// the system's own Settings panes.
private struct SettingsView: View {
    let onQuit: () -> Void
    @Binding var isEnabledBinding: Bool
    @Binding var volumeBinding: Bool
    @Binding var brightnessBinding: Bool
    @Binding var nowPlayingBinding: Bool
    @Binding var airpodsBinding: Bool
    @Binding var statsBinding: Bool
    let onSuiteToggle: () -> Void

    var body: some View {
        TabView {
            GeneralTab(
                isEnabledBinding: $isEnabledBinding,
                onQuit: onQuit)
                .tabItem {
                    Label("General",
                          systemImage: "gearshape")
                }
            FeaturesTab(
                volumeBinding: $volumeBinding,
                brightnessBinding: $brightnessBinding,
                nowPlayingBinding: $nowPlayingBinding,
                airpodsBinding: $airpodsBinding,
                statsBinding: $statsBinding,
                isMasterOn: isEnabledBinding)
                .tabItem {
                    Label("Features",
                          systemImage: "slider.horizontal.3")
                }
            SuiteTab(
                onSuiteToggle: onSuiteToggle,
                isMasterOn: isEnabledBinding)
                .tabItem {
                    Label("Suite",
                          systemImage: "square.grid.2x2")
                }
            AboutTab()
                .tabItem {
                    Label("About",
                          systemImage: "info.circle")
                }
        }
        .frame(width: 520, height: 380)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Binding var isEnabledBinding: Bool
    let onQuit: () -> Void

    var body: some View {
        Form {
            Section {
                Toggle("Show the island", isOn: $isEnabledBinding)
                Text("When off, the island disappears entirely and every publisher stops listening.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Spacer()
                    Button("Quit Halo", action: onQuit)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Features (Halo's built-ins)

private struct FeaturesTab: View {
    @Binding var volumeBinding: Bool
    @Binding var brightnessBinding: Bool
    @Binding var nowPlayingBinding: Bool
    @Binding var airpodsBinding: Bool
    @Binding var statsBinding: Bool
    let isMasterOn: Bool

    var body: some View {
        Form {
            Section("System HUDs") {
                FeatureRow(
                    title: "Volume HUD",
                    subtitle: "Show level on every volume change",
                    symbol: "speaker.wave.2.fill",
                    isOn: $volumeBinding)
                FeatureRow(
                    title: "Brightness HUD",
                    subtitle: "Show level on every brightness change",
                    symbol: "sun.max.fill",
                    isOn: $brightnessBinding)
            }
            Section("Live") {
                FeatureRow(
                    title: "Now Playing",
                    subtitle: "Currently playing track from any app",
                    symbol: "music.note",
                    isOn: $nowPlayingBinding)
                FeatureRow(
                    title: "AirPods battery",
                    subtitle: "Battery level of nearby Apple buds",
                    symbol: "airpods",
                    isOn: $airpodsBinding)
                FeatureRow(
                    title: "System stats",
                    subtitle: "CPU / RAM / Disk usage, rotating",
                    symbol: "cpu",
                    isOn: $statsBinding)
            }
        }
        .formStyle(.grouped)
        .disabled(!isMasterOn)
        .padding()
    }
}

// MARK: - Suite

private struct SuiteTab: View {
    let onSuiteToggle: () -> Void
    let isMasterOn: Bool

    var body: some View {
        Form {
            Section("MattsSoftware apps") {
                ForEach(HaloSettings.suiteSlots) { slot in
                    SuiteSlotRow(slot: slot, onToggle: onSuiteToggle)
                }
            }
            Section {
                Text("Apps publish their state to a shared file store at `~/Library/Application Support/MattsSoftware/live-activity/`. Any app — first-party or third-party — can write a payload there and it'll appear in the island.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(!isMasterOn)
        .padding()
    }
}

private struct SuiteSlotRow: View {
    let slot: SuiteSlot
    let onToggle: () -> Void

    @State private var isOn: Bool

    init(slot: SuiteSlot, onToggle: @escaping () -> Void) {
        self.slot = slot
        self.onToggle = onToggle
        _isOn = State(initialValue: HaloSettings.suiteSlotEnabled(slot.id))
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { isOn },
            set: { newValue in
                isOn = newValue
                HaloSettings.setSuiteSlotEnabled(slot.id, newValue)
                onToggle()
            }
        )) {
            HStack(spacing: 10) {
                Image(systemName: slot.symbol)
                    .frame(width: 22)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(slot.title)
                    Text(slot.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Feature row helper

private struct FeatureRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 22)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"]
            as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.dashed.and.paperclip")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .padding(.top, 24)
            VStack(spacing: 4) {
                Text("Halo")
                    .font(.system(size: 24, weight: .bold,
                                  design: .rounded))
                Text("Version \(version)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("The MattsSoftware Dynamic Island for the MacBook notch.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 30)
            HStack(spacing: 12) {
                Link("mattssoftware.com",
                     destination: URL(string: "https://mattssoftware.com")!)
                Text("·").foregroundStyle(.secondary)
                Link("GitHub",
                     destination: URL(string: "https://github.com/mattssoftware/halo-swift")!)
            }
            .font(.callout)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
