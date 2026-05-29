import AppKit
import SwiftUI

/// Footer action buttons (commit, branch, worktree, refresh), the
/// shared section-header helper used by every `+Sections` block,
/// and the two modal sheets ("new branch", "new worktree").
extension WorktreeExpandedView {
    // MARK: Footer

    var footerActions: some View {
        HStack(spacing: 6) {
            actionButton("+ Branch", icon: "plus.circle") {
                newBranchName = ""
                showNewBranchSheet = true
            }
            actionButton("+ Worktree",
                         icon: "square.split.bottomrightquarter") {
                newWorktreeBranch = ""
                newWorktreeCreateNew = true
                showNewWorktreeSheet = true
            }
            Spacer(minLength: 0)
            Button {
                WorktreeCommands.pull()
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 11))
                    .foregroundStyle(.haloSecondary)
            }
            .buttonStyle(.plain)
            .help("git pull --ff-only")
        }
        .padding(.top, 2)
    }

    func actionButton(_ label: String, icon: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(.haloSecondary)
            .background(
                RoundedRectangle(cornerRadius: 5,
                                 style: .continuous)
                    .fill(Color.haloSurfaceFaint))
        }
        .buttonStyle(.plain)
    }

    func sectionHeader(
        _ title: String,
        trailingButton: (label: String, icon: String,
                          action: () -> Void)?
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(.haloTertiary)
            Spacer()
            if let t = trailingButton {
                Button(action: t.action) {
                    HStack(spacing: 3) {
                        Image(systemName: t.icon)
                            .font(.system(size: 9))
                        Text(t.label)
                            .font(.system(size: 9,
                                          weight: .semibold))
                            .tracking(0.5)
                    }
                    .foregroundStyle(brand)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: Sheets

    var newBranchSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New branch")
                .font(.system(size: 13, weight: .semibold))
            TextField("name (e.g. feat/preset-picker)",
                      text: $newBranchName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showNewBranchSheet = false }
                Button("Create") {
                    let n = newBranchName.trimmingCharacters(
                        in: .whitespaces)
                    if !n.isEmpty {
                        WorktreeCommands.createBranch(n)
                    }
                    showNewBranchSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newBranchName.trimmingCharacters(
                    in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    var newWorktreeSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New worktree")
                .font(.system(size: 13, weight: .semibold))
            Text("Adds a linked working directory checked out "
                 + "to a branch — switch branches without "
                 + "stashing. Worktree.app picks the destination "
                 + "directory.")
                .font(.system(size: 10))
                .foregroundStyle(.haloSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Create new branch",
                   isOn: $newWorktreeCreateNew)
            TextField(
                newWorktreeCreateNew
                    ? "new branch name"
                    : "existing branch name",
                text: $newWorktreeBranch)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showNewWorktreeSheet = false }
                Button("Create") {
                    let b = newWorktreeBranch.trimmingCharacters(
                        in: .whitespaces)
                    if !b.isEmpty,
                       let repo = info?.repoPath {
                        // Default location: sibling dir next to
                        // the main worktree, named `<repo>-<branch>`.
                        // Same suggestion the Worktree popover
                        // uses when the user leaves path empty.
                        let suggested = "\(repo)-\(b)"
                        WorktreeCommands.addWorktree(
                            branch: b,
                            createNew: newWorktreeCreateNew,
                            atPath: suggested)
                    }
                    showNewWorktreeSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newWorktreeBranch.trimmingCharacters(
                    in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
