import AppKit

/// Current browser tab via each browser's AppleScript
/// dictionary. Visible only when the matching browser is the
/// frontmost app — once you Cmd-Tab away, the pill withdraws
/// (the title isn't useful when you can't see the browser).
///
/// Supports Safari + Chrome + Arc (Chrome-family dict). Each
/// needs the same one-time AppleEvents permission the music
/// publishers ask for.
@MainActor
final class BrowserTabPublisher: HaloPublisher {
    let id = "halo.browser"

    private weak var coordinator: LiveActivityCoordinator?
    private var pollTimer: Timer?
    private var focusObserver: NSObjectProtocol?

    init(coordinator: LiveActivityCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        focusObserver = NSWorkspace.shared.notificationCenter
            .addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        // 4s tick covers in-app tab switches — the user
        // navigates within the same browser process so the
        // focus notification doesn't fire.
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: 4, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let o = focusObserver {
            NSWorkspace.shared.notificationCenter
                .removeObserver(o)
            focusObserver = nil
        }
        coordinator?.clear(id: id)
    }

    private func refresh() {
        guard let bundleID = NSWorkspace.shared
                .frontmostApplication?.bundleIdentifier,
              let info = readTab(bundleID: bundleID)
        else {
            coordinator?.clear(id: id)
            return
        }
        let truncated = info.title.count > 32
            ? String(info.title.prefix(31)) + "…"
            : info.title
        let payload = LiveActivityCoordinator.Resolved(
            id: id,
            compactLeadingImage:
                LiveActivityCoordinator.symbolImage(info.symbol),
            compactTrailingText: truncated,
            compactTrailingImage: nil,
            tint: .white,
            priority: 30)
        coordinator?.inject(payload)
    }

    private struct TabInfo {
        let title: String
        let symbol: String
    }

    /// Try each known browser bundle id and run its AppleScript
    /// dictionary's name-of-current-tab snippet. Returns nil
    /// for any non-browser frontmost app or when AppleEvents
    /// permission is denied for that bundle.
    private func readTab(bundleID: String) -> TabInfo? {
        switch bundleID {
        case "com.apple.Safari":
            return runScript(#"""
            tell application id "com.apple.Safari"
                if it is running then
                    try
                        return name of front document
                    on error
                        return ""
                    end try
                end if
            end tell
            return ""
            """#).map { TabInfo(title: $0, symbol: "safari") }
        case "com.google.Chrome",
             "company.thebrowser.Browser",
             "com.brave.Browser",
             "com.microsoft.edgemac",
             "com.vivaldi.Vivaldi":
            // Chrome-family dict — every browser cloned from
            // Chromium exposes the same "title of active tab"
            // path under their own bundle id.
            let symbol: String
            switch bundleID {
            case "com.google.Chrome":           symbol = "globe"
            case "company.thebrowser.Browser":  symbol = "globe"
            case "com.brave.Browser":           symbol = "shield.lefthalf.filled"
            case "com.microsoft.edgemac":       symbol = "globe"
            default:                            symbol = "globe"
            }
            return runScript(#"""
            tell application id "\#(bundleID)"
                if it is running then
                    try
                        return title of active tab of front window
                    on error
                        return ""
                    end try
                end if
            end tell
            return ""
            """#).map { TabInfo(title: $0, symbol: symbol) }
        default:
            return nil
        }
    }

    private func runScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source)
        else { return nil }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if err != nil { return nil }
        let str = result.stringValue ?? ""
        return str.isEmpty ? nil : str
    }
}
