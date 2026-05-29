import AppKit
import SwiftUI

// MARK: - Worktree

/// Branch switcher. Top row shows the current repo + branch +
/// dirty marker; below it a list of OTHER local branches the
/// user can switch to with a tap. Posts a distributed
/// notification — Worktree's listener does the auto-stash +
/// switch + pop on the other side.
/// Full-fidelity Worktree control surface inside Halo's
/// expanded card. Renders everything the standalone Worktree
/// popover does — header with bookmark toggle, status pills,
/// follow-focus banner when pinned, local + remote branches,
/// worktrees, saved projects — and writes user actions back
/// through the command channel (`WorktreeCommands`) so the
/// user never has to open Worktree.app to manage state.
///
/// Phase 1 (read) + Phase 2 (quick actions) + Phase 3 (create
/// sheets) all live here. New-worktree's directory picker
/// still defers to Worktree.app (NSOpenPanel inside a transient
/// hovering panel is brittle); everything else is fully in
/// Halo's surface.
struct WorktreeExpandedView: View {
    let activity: LiveActivityCoordinator.Resolved

    @State var showNewBranchSheet = false
    @State var newBranchName = ""
    @State var showNewWorktreeSheet = false
    @State var newWorktreeBranch = ""
    @State var newWorktreeCreateNew = true

    var info: LiveActivityCoordinator.WorktreeInfo? {
        activity.worktree
    }

    /// Brand colour Worktree publishes via the activity's tint.
    /// Used for status pills, action accents, the bookmark fill.
    var brand: Color {
        NotchView.pillTextColor(for: activity)
    }

    /// Local branches that aren't the current one — Halo offers
    /// them as switch targets. Worktree already sorts the
    /// `branches` array by committer date (newest first) via
    /// `git for-each-ref --sort=-committerdate`, so we just
    /// keep that order and take the top 6 — exactly enough to
    /// fill the expanded card's 3×2 quick-switch grid.
    var switchableLocal: [String] {
        guard let info else { return [] }
        return info.branches
            .filter { $0 != info.currentBranch }
            .prefix(6)
            .map { $0 }
    }

    /// Remote refs minus origin/HEAD (filtered by Worktree's
    /// own remoteBranches resolver, but defence-in-depth).
    var remotes: [String] {
        guard let info else { return [] }
        return info.remoteBranches
            .filter { !$0.hasSuffix("/HEAD") }
            .sorted()
    }

    /// True if `repoPath` matches one of the saved projects —
    /// drives the bookmark fill / outline state.
    var currentIsSaved: Bool {
        guard let info else { return false }
        return info.savedProjects
            .contains(where: { $0.path == info.repoPath })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if info?.isPinned == true { followFocusBanner }
            headerRow
            if let err = info?.lastError, !err.isEmpty {
                errorBanner(err)
            }
            // Sections render at their natural height — the
            // panel + IslandShape both size to whatever this
            // VStack measures, so we don't need a ScrollView
            // here. (A ScrollView's intrinsic height is 0
            // which made the height-measurement pipeline
            // capture a stale "headers + footer only" value,
            // and any worktrees / saved rows then rendered
            // BELOW the IslandShape's bottom edge.)
            VStack(alignment: .leading, spacing: 8) {
                branchesSection
                if !remotes.isEmpty { remotesSection }
                if let wts = info?.worktrees, !wts.isEmpty {
                    worktreesSection(wts)
                }
                if let saved = info?.savedProjects,
                   !saved.isEmpty {
                    savedSection(saved)
                }
            }
            footerActions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showNewBranchSheet) { newBranchSheet }
        .sheet(isPresented: $showNewWorktreeSheet) { newWorktreeSheet }
        // Auto-refresh the remote-branch / ahead-behind state
        // as soon as the card appears so the grid shows
        // recently-pushed commits without the user having to
        // click Fetch. Throttled on the Worktree side — see
        // `fetchIfStale` (30s cooldown).
        .onAppear { WorktreeCommands.fetchIfStale() }
    }

    // MARK: Header + banners

    var headerRow: some View {
        HStack(spacing: 10) {
            if let img = activity.compactLeadingImage {
                Image(nsImage: NotchView.tinted(
                    img,
                    color: NotchView.pillIconColor(for: activity)))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(info?.currentBranch ?? "—")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.haloSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            statusPills
            Button {
                WorktreeCommands.toggleSaveCurrent()
            } label: {
                Image(systemName: currentIsSaved
                      ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 12))
                    .foregroundStyle(currentIsSaved
                                     ? brand : .haloTertiary)
            }
            .buttonStyle(.plain)
            .help(currentIsSaved
                  ? "Remove from saved" : "Save this project")
        }
    }

    var displayName: String {
        info?.displayName
            ?? (info.map {
                ($0.repoPath as NSString).lastPathComponent
            } ?? "WORKTREE")
    }

    @ViewBuilder
    var statusPills: some View {
        if let info {
            HStack(spacing: 3) {
                if info.ahead > 0 {
                    statusPill("↑\(info.ahead)", color: .green)
                }
                if info.behind > 0 {
                    statusPill("↓\(info.behind)", color: .orange)
                }
                if info.dirtyCount > 0 {
                    statusPill("\(info.dirtyCount)*",
                               color: .yellow)
                }
            }
        }
    }

    func statusPill(_ text: String,
                            color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold,
                          design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    var followFocusBanner: some View {
        Button {
            WorktreeCommands.returnToFocus()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.left")
                    .font(.system(size: 9, weight: .semibold))
                Text("Following saved project")
                    .font(.system(size: 10, weight: .medium))
                Spacer()
                Text("Follow focus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(brand)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(brand.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6,
                                         style: .continuous))
        }
        .buttonStyle(.plain)
    }

    func errorBanner(_ msg: String) -> some View {
        Text(msg)
            .font(.system(size: 10))
            .foregroundStyle(.red)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 5,
                                         style: .continuous))
    }

}
