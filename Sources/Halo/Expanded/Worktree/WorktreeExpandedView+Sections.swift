import AppKit
import SwiftUI

/// All of the scrolling content rows in the worktree dropdown:
/// the LOCAL branches grid, the REMOTES list, the WORKTREES list,
/// and the SAVED projects list. Sheets + footer actions live in
/// the sibling `WorktreeExpandedView+Footer` file.
extension WorktreeExpandedView {
    // MARK: Branches + Remotes

    var branchesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader(
                "RECENT BRANCHES",
                trailingButton: (
                    label: "Fetch",
                    icon: "arrow.down.circle",
                    action: { WorktreeCommands.fetch() }))
            if switchableLocal.isEmpty {
                Text("Only branch — \(info?.currentBranch ?? "")")
                    .font(.system(size: 10))
                    .foregroundStyle(.haloTertiary)
                    .padding(.horizontal, 8)
            } else {
                // 3-column grid showing the 6 most-recently-
                // committed branches. Worktree feeds the array
                // in newest-first order (`git for-each-ref
                // --sort=-committerdate`), so the top-left cell
                // is "the branch you most recently touched"
                // and the read flows naturally left-to-right,
                // top-to-bottom toward the older ones.
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 4),
                        GridItem(.flexible(), spacing: 4),
                        GridItem(.flexible(), spacing: 4)
                    ],
                    spacing: 4
                ) {
                    ForEach(switchableLocal, id: \.self) { b in
                        BranchCell(name: b, tint: brand) {
                            WorktreeCommands.switchBranch(b)
                        }
                    }
                }
            }
        }
    }

    var remotesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("REMOTES (\(remotes.count))")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(.haloTertiary)
                .padding(.horizontal, 8)
                .padding(.top, 2)
            VStack(spacing: 3) {
                ForEach(remotes, id: \.self) { r in
                    remoteBranchRow(r)
                }
            }
        }
    }

    func remoteBranchRow(_ name: String) -> some View {
        Button {
            WorktreeCommands.checkoutRemote(name)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cloud")
                    .font(.system(size: 10))
                    .foregroundStyle(.haloTertiary)
                Text(name)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.haloTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.system(size: 9))
                    .foregroundStyle(.haloTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5,
                                 style: .continuous)
                    .fill(Color.haloSurfaceFaint))
        }
        .buttonStyle(.plain)
        .help("Check out \(name) as a local tracking branch")
    }

    // MARK: Worktrees

    func worktreesSection(
        _ worktrees: [LiveActivityCoordinator.WorktreeEntryInfo]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WORKTREES (\(worktrees.count))")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(.haloTertiary)
                .padding(.horizontal, 8)
                .padding(.top, 2)
            VStack(spacing: 3) {
                ForEach(worktrees, id: \.path) { w in
                    worktreeRow(w)
                }
            }
        }
    }

    func worktreeRow(
        _ w: LiveActivityCoordinator.WorktreeEntryInfo
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: w.isCurrent
                  ? "folder.fill" : "folder")
                .font(.system(size: 10))
                .foregroundStyle(w.isCurrent
                                  ? brand : .haloTertiary)
            VStack(alignment: .leading, spacing: 0) {
                Text((w.path as NSString).lastPathComponent
                     + (w.isMain ? " (main)" : ""))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.haloSecondary)
                    .lineLimit(1)
                if let b = w.branch {
                    Text(b)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.haloTertiary)
                }
            }
            Spacer(minLength: 0)
            Button {
                WorktreeCommands.openInFinder(w.path)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10))
                    .foregroundStyle(.haloTertiary)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.haloSurfaceFaint))
    }

    // MARK: Saved projects

    func savedSection(
        _ saved: [LiveActivityCoordinator.SavedProjectInfo]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SAVED (\(saved.count))")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(.haloTertiary)
                .padding(.horizontal, 8)
                .padding(.top, 2)
            VStack(spacing: 3) {
                ForEach(saved, id: \.path) { p in
                    savedRow(p)
                }
            }
        }
    }

    func savedRow(
        _ p: LiveActivityCoordinator.SavedProjectInfo
    ) -> some View {
        let isCurrent = p.path == info?.repoPath
        return Button {
            WorktreeCommands.viewSaved(p.path)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCurrent
                      ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 10))
                    .foregroundStyle(isCurrent
                                      ? brand : .haloTertiary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(p.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.haloSecondary)
                        .lineLimit(1)
                    if let b = p.lastKnownBranch {
                        Text(b)
                            .font(.system(size: 9,
                                          design: .monospaced))
                            .foregroundStyle(.haloTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5,
                                 style: .continuous)
                    .fill(Color.haloSurfaceFaint))
        }
        .buttonStyle(.plain)
        .help(isCurrent
              ? "Currently viewing \(p.displayName)"
              : "Switch to \(p.displayName)")
        .contextMenu {
            Button("Remove from saved", role: .destructive) {
                WorktreeCommands.removeSaved(p.path)
            }
        }
    }

}
