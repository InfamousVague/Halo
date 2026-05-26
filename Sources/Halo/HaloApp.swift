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
        // No window scene — the island is the UI. Empty Settings
        // scene keeps SwiftUI quiet without spawning a real window.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) lazy var notchHost = NotchHost()
    private var statusItem: NSStatusItem!
    private var settingsPopover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Menu-bar status item so the user can quit Halo or open
        // its settings without going through the launcher.
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.dashed.and.paperclip",
                accessibilityDescription: "Halo")
            button.image?.isTemplate = true
            button.action = #selector(toggleSettings(_:))
            button.target = self
        }

        // Settings popover — small for now; phase-0 is just an
        // "Enabled" toggle + "Quit" button. Grows once we add
        // pane configuration, HUD prefs, etc.
        settingsPopover = NSPopover()
        settingsPopover.behavior = .transient
        settingsPopover.contentViewController = NSHostingController(
            rootView: SettingsView(
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
        )

        // Start the island. The host is idempotent — toggling via
        // settings just calls enable() / disable() again later.
        if HaloSettings.enabled {
            notchHost.enable()
        }
    }

    @objc private func toggleSettings(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if settingsPopover.isShown {
            settingsPopover.performClose(sender)
        } else {
            settingsPopover.show(
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .minY)
        }
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
