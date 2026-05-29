import AppKit
import Foundation

// MARK: - Helpers

@MainActor
func isRunning(_ bundleID: String) -> Bool {
    NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier == bundleID
    }
}

@MainActor
func runAppleScript(_ source: String) -> String? {
    guard let script = NSAppleScript(source: source) else { return nil }
    var err: NSDictionary?
    let result = script.executeAndReturnError(&err)
    if let err {
        NowPlayingDebugLog.append(
            "\(Date()) AppleScript err: \(err)\n")
        return nil
    }
    return result.stringValue
}
