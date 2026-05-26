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
            )
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
}

/// Small settings popover. Will grow as Halo gains features —
/// for phase 0 it's just the master toggle + the quit button so
/// the user has a real way out of the agent.
private struct SettingsView: View {
    let onQuit: () -> Void
    @Binding var isEnabledBinding: Bool

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
                .font(.system(size: 12))
            Divider()
            HStack {
                Spacer()
                Button("Quit Halo", action: onQuit)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 240)
    }
}
