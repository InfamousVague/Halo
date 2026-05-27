import Foundation
import SuiteKit

/// Halo → Worktree command channel. The expanded WorktreeCard
/// calls into this when the user picks a branch, taps fetch /
/// pull / save toggle, picks a saved project, etc. We append
/// the command to `worktree.commands.json` and post a
/// distributed notification so Worktree's drainer wakes up
/// without waiting for its 1Hz fallback poll.
///
/// All actions are fire-and-forget from Halo's side — Worktree
/// republishes the rich state after executing so the UI
/// updates within the next coordinator tick. We don't model
/// pending / error / success states here; the JSON rich-state's
/// `lastError` field carries any failure message back.
@MainActor
enum WorktreeCommands {

    /// Append a fully-formed command to the queue.
    static func send(_ command: SuiteLiveActivityStore.WorktreeCommand) {
        do {
            try SuiteLiveActivityStore.appendCommand(
                command, for: "worktree")
            // Worktree subscribes to this exact name + drains
            // on receipt. The notification is also posted by
            // appendCommand's general refresh ping, but having
            // a dedicated channel keeps Worktree from waking
            // up for every Halo poll-tick refresh too.
            DistributedNotificationCenter.default()
                .postNotificationName(
                    Notification.Name(
                        "com.mattssoftware.worktree.commands.posted"),
                    object: nil,
                    deliverImmediately: true)
        } catch {
            NSLog("[halo] worktree command write failed: \(error)")
        }
    }

    // MARK: Convenience builders

    static func switchBranch(_ branch: String) {
        send(.init(action: "switchBranch", branch: branch))
    }

    static func createBranch(_ name: String) {
        send(.init(action: "createBranch", branch: name))
    }

    static func fetch() {
        send(.init(action: "fetch"))
    }

    static func pull() {
        send(.init(action: "pull"))
    }

    static func checkoutRemote(_ ref: String) {
        send(.init(action: "checkoutRemote", ref: ref))
    }

    static func toggleSaveCurrent() {
        send(.init(action: "toggleSaveCurrent"))
    }

    static func viewSaved(_ path: String) {
        send(.init(action: "viewSaved", path: path))
    }

    static func returnToFocus() {
        send(.init(action: "returnToFocus"))
    }

    static func removeSaved(_ path: String) {
        send(.init(action: "removeSaved", path: path))
    }

    static func addWorktree(branch: String,
                            createNew: Bool,
                            atPath path: String) {
        send(.init(action: "addWorktree",
                   branch: branch,
                   path: path,
                   createNew: createNew))
    }

    static func openInFinder(_ path: String) {
        send(.init(action: "openInFinder", path: path))
    }
}
