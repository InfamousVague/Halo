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

    var body: some Scene {
        // MenuBarExtra gives SwiftUI a concrete scene to render
        // and reliably bootstraps the AppDelegate adaptor. The
        // menu is the user's way to open settings + quit; the
        // island itself is the AppDelegate's NSPanel.
        MenuBarExtra("Halo", systemImage: "circle.dashed") {
            Button("Show Settings…") {
                if let d = NSApp.delegate as? AppDelegate {
                    d.openSettings()
                }
            }
            Divider()
            Button("Quit Halo") { NSApp.terminate(nil) }
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
    }

    /// Show the settings window. Called from the MenuBarExtra
    /// "Show Settings…" menu item. Uses a real NSWindow so the
    /// toggle reliably accepts input (NSPopover from a SwiftUI
    /// menu bar item has activation quirks on macOS 14+).
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
                set: HaloSettings.setAirpodsEnabled)
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

/// Settings window. Master "Show the island" toggle on top, then
/// a per-publisher list so users can turn off any feature that
/// duplicates a tool they already run (e.g. someone with a
/// MediaMate-style HUD already installed switches ours off).
private struct SettingsView: View {
    let onQuit: () -> Void
    @Binding var isEnabledBinding: Bool
    @Binding var volumeBinding: Bool
    @Binding var brightnessBinding: Bool
    @Binding var nowPlayingBinding: Bool
    @Binding var airpodsBinding: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.dashed.and.paperclip")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tint)
                Text("HALO")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(2)
                Spacer()
            }
            Divider()
            Toggle("Show the island", isOn: $isEnabledBinding)
                .font(.system(size: 12, weight: .semibold))

            Divider()
            Text("FEATURES")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(.secondary)
            Toggle("Volume HUD", isOn: $volumeBinding)
                .font(.system(size: 12))
                .disabled(!isEnabledBinding)
            Toggle("Brightness HUD", isOn: $brightnessBinding)
                .font(.system(size: 12))
                .disabled(!isEnabledBinding)
            Toggle("Now Playing", isOn: $nowPlayingBinding)
                .font(.system(size: 12))
                .disabled(!isEnabledBinding)
            Toggle("AirPods battery", isOn: $airpodsBinding)
                .font(.system(size: 12))
                .disabled(!isEnabledBinding)

            Divider()
            HStack {
                Spacer()
                Button("Quit Halo", action: onQuit)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}
