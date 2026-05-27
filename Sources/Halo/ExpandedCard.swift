import AppKit
import Darwin
import SwiftUI

/// The rich content that materialises beneath the compact pill
/// when the user hovers for ≥1s. Dispatches by activity id to a
/// publisher-specific layout (Stats rows, AirPods per-device,
/// Worktree dirty + branch detail, etc.); falls back to a
/// generic "title + value + Open button" row for anything we
/// don't have a custom view for.
///
/// The card lays its own padding internally — the caller just
/// hands it a frame matching `Geometry.expandedExtraHeight`.
///
/// Visual hierarchy used by all sub-views:
///   • Primary text → `.white` (100%) — the data.
///   • Secondary text → `.white.opacity(0.62)` — labels,
///     subtitles, captions.
///   • Tertiary text / icons → `.white.opacity(0.4)` —
///     metadata, affordances.
///   • Faint surface → `.white.opacity(0.08)` — base of cells
///     / progress-bar tracks.
///   • Soft surface → `.white.opacity(0.14)` — pill buttons,
///     dividers.
/// `.foregroundStyle(.haloTertiary)` resolves against
/// `ShapeStyle`, not `Color` — the dot-shorthand lookup checks
/// the parameter type. Adding the tokens on
/// `ShapeStyle where Self == Color` lets both `.foregroundStyle`
/// (ShapeStyle) and direct `Color.haloX` usage work.
extension ShapeStyle where Self == Color {
    fileprivate static var haloSecondary: Color {
        Color.white.opacity(0.62)
    }
    fileprivate static var haloTertiary: Color {
        Color.white.opacity(0.4)
    }
    fileprivate static var haloSurfaceFaint: Color {
        Color.white.opacity(0.08)
    }
    fileprivate static var haloSurfaceSoft: Color {
        Color.white.opacity(0.14)
    }
}

extension Color {
    fileprivate static var haloSecondary: Color {
        Color.white.opacity(0.62)
    }
    fileprivate static var haloTertiary: Color {
        Color.white.opacity(0.4)
    }
    fileprivate static var haloSurfaceFaint: Color {
        Color.white.opacity(0.08)
    }
    fileprivate static var haloSurfaceSoft: Color {
        Color.white.opacity(0.14)
    }
}

struct ExpandedCard: View {
    let activity: LiveActivityCoordinator.Resolved
    /// Every active activity — used by views that aggregate
    /// data from multiple publishers in one card (the battery
    /// card lists AirPods alongside Mac + HID accessories).
    var allActivities: [LiveActivityCoordinator.Resolved] = []

    var body: some View {
        Group {
            switch activity.id {
            case "halo.stats":
                StatsExpandedView(activity: activity)
            case "espresso":
                EspressoExpandedView(activity: activity)
            case "halo.nowplaying":
                NowPlayingExpandedView(activity: activity)
            case "worktree":
                WorktreeExpandedView(activity: activity)
            case "port":
                PortExpandedView(activity: activity)
            case "halo.airpods":
                AirPodsExpandedView(activity: activity)
            case "halo.battery":
                BatteryExpandedView(
                    activity: activity,
                    allActivities: allActivities)
            case "halo.bluetoothaudio":
                BluetoothAudioExpandedView(activity: activity)
            default:
                genericContent
            }
        }
        // 22pt horizontal inset to match the compact-row
        // icon's column. Vertical pad is asymmetric — 12pt top
        // (clear of the compact row band) + 10pt bottom — the
        // bottom inset just needs visual breathing room from
        // the pill's rounded corner, not the full side
        // breathing room.
        .padding(.horizontal, Geometry.contentInset)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var genericContent: some View {
        // Read-only for now — suite-app integrations don't yet
        // act on the Open CTA so we don't show one. Each app
        // can opt in to a real action later (open popover,
        // bring window forward, focus a specific section…).
        HStack(spacing: 12) {
            if let img = activity.compactLeadingImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .foregroundStyle(.haloTertiary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(titleForActivity)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.haloSecondary)
                if let value = activity.compactTrailingText {
                    Text(value)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Capitalised display name from the activity id —
    /// `worktree` → `WORKTREE`, `halo.volume` → `VOLUME`.
    private var titleForActivity: String {
        let trimmed = activity.id.hasPrefix("halo.")
            ? String(activity.id.dropFirst(5))
            : activity.id
        switch trimmed {
        case "nowplaying":  return "NOW PLAYING"
        default:            return trimmed.uppercased()
        }
    }
}

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
private struct WorktreeExpandedView: View {
    let activity: LiveActivityCoordinator.Resolved

    @State private var showNewBranchSheet = false
    @State private var newBranchName = ""
    @State private var showNewWorktreeSheet = false
    @State private var newWorktreeBranch = ""
    @State private var newWorktreeCreateNew = true

    private var info: LiveActivityCoordinator.WorktreeInfo? {
        activity.worktree
    }

    /// Brand colour Worktree publishes via the activity's tint.
    /// Used for status pills, action accents, the bookmark fill.
    private var brand: Color {
        NotchView.pillTextColor(for: activity)
    }

    /// Local branches that aren't the current one — Halo offers
    /// them as switch targets. Worktree already sorts the
    /// `branches` array by committer date (newest first) via
    /// `git for-each-ref --sort=-committerdate`, so we just
    /// keep that order and take the top 6 — exactly enough to
    /// fill the expanded card's 3×2 quick-switch grid.
    private var switchableLocal: [String] {
        guard let info else { return [] }
        return info.branches
            .filter { $0 != info.currentBranch }
            .prefix(6)
            .map { $0 }
    }

    /// Remote refs minus origin/HEAD (filtered by Worktree's
    /// own remoteBranches resolver, but defence-in-depth).
    private var remotes: [String] {
        guard let info else { return [] }
        return info.remoteBranches
            .filter { !$0.hasSuffix("/HEAD") }
            .sorted()
    }

    /// True if `repoPath` matches one of the saved projects —
    /// drives the bookmark fill / outline state.
    private var currentIsSaved: Bool {
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
            // Scrollable middle — branches + remotes + worktrees
            // + saved. Capped at ~280pt so the card never grows
            // past comfortable hover-height; overflow scrolls.
            ScrollView(.vertical, showsIndicators: false) {
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
            }
            .frame(maxHeight: 280)
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

    private var headerRow: some View {
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

    private var displayName: String {
        info?.displayName
            ?? (info.map {
                ($0.repoPath as NSString).lastPathComponent
            } ?? "WORKTREE")
    }

    @ViewBuilder
    private var statusPills: some View {
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

    private func statusPill(_ text: String,
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

    private var followFocusBanner: some View {
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

    private func errorBanner(_ msg: String) -> some View {
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

    // MARK: Branches + Remotes

    private var branchesSection: some View {
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

    private var remotesSection: some View {
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

    private func remoteBranchRow(_ name: String) -> some View {
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

    private func worktreesSection(
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

    private func worktreeRow(
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

    private func savedSection(
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

    private func savedRow(
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

    // MARK: Footer

    private var footerActions: some View {
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

    private func actionButton(_ label: String, icon: String,
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

    private func sectionHeader(
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

    private var newBranchSheet: some View {
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

    private var newWorktreeSheet: some View {
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

// MARK: - Port

/// Lists the top few listening ports Port surfaced in the
/// live-activity payload, with a per-row kill button. Tap a
/// row's kill icon → distributed notification → Port's
/// `killByPid` runs `kill(2)` on the owning pid. Rows
/// disappear from the next publish once the process is gone.
private struct PortExpandedView: View {
    let activity: LiveActivityCoordinator.Resolved

    private var info: LiveActivityCoordinator.PortInfo? {
        activity.port
    }
    private var brand: Color {
        NotchView.pillTextColor(for: activity)
    }
    private var totalCount: Int {
        Int(activity.compactTrailingText ?? "") ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header — total listening-port count + a small
            // "showing N of M" hint when we capped the list.
            HStack(spacing: 10) {
                if let img = activity.compactLeadingImage {
                    Image(nsImage: NotchView.tinted(
                        img, color: brand))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("LISTENING PORTS")
                        .font(.system(size: 10,
                                      weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(brand.opacity(0.85))
                    // Verbatim so the count never picks up
                    // the locale's thousands separator (1,234)
                    // — the compact pill renders the same
                    // value as a plain integer, and they
                    // should match.
                    Text(verbatim: "\(totalCount) open")
                        .font(.system(size: 12,
                                      weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                if let info, info.entries.count < totalCount {
                    Text("top \(info.entries.count)")
                        .font(.system(size: 10,
                                      weight: .medium))
                        .foregroundStyle(.haloTertiary)
                }
            }
            if let entries = info?.entries, !entries.isEmpty {
                Divider().background(Color.haloSurfaceFaint)
                // 2-column grid — at the expanded width the
                // card is wide enough to fit two port cards
                // side by side, which reads better than a
                // single tall list. Caps at 6 entries (Port
                // sorts by port number and prefixes to 6
                // before publishing), filling a 2×3 grid
                // exactly.
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(),
                                 spacing: 6),
                        GridItem(.flexible(),
                                 spacing: 6)
                    ],
                    spacing: 4
                ) {
                    ForEach(entries, id: \.self) { e in
                        PortRow(entry: e, tint: brand) {
                            kill(pid: e.pid)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func kill(pid: Int32) {
        DistributedNotificationCenter.default()
            .postNotificationName(
                Notification.Name(
                    "com.mattssoftware.port.kill"),
                object: String(pid),
                deliverImmediately: true)
    }
}

/// One row in the Port expanded card.
///
/// Layout, left to right:
///   • Port number (data; large white)
///   • Service / process name (label; secondary)
///   • Kill button (brand-tinted destructive action)
private struct PortRow: View {
    let entry: LiveActivityCoordinator.PortEntry
    let tint: Color
    let kill: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // `Text(verbatim:)` so port numbers don't pick up
            // the user's locale separator — Text's default
            // `String(describing:)` interpolation would render
            // 1900 as "1,900" in en_US.
            Text(verbatim: String(entry.port))
                .font(.system(size: 12,
                              weight: .semibold,
                              design: .monospaced))
                .foregroundStyle(.white)
                .fixedSize()
            Text(entry.proto.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(tint.opacity(0.18)))
                .foregroundStyle(tint)
                .fixedSize()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.haloSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button(action: kill) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(
                        Circle().fill(
                            Color.white.opacity(0.10)))
                    .foregroundStyle(.haloSecondary)
            }
            .buttonStyle(.plain)
            .help("Terminate pid \(entry.pid) (\(entry.process))")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5,
                             style: .continuous)
                .fill(Color.haloSurfaceFaint))
    }

    private var label: String {
        if let svc = entry.service, !svc.isEmpty {
            return svc
        }
        return entry.process
    }
}

/// Grid-cell branch chip used by the recent-branches 3-column
/// grid. Compact (~125pt wide) — just the branch icon + name,
/// no trailing arrow / chevron since the whole cell is the
/// switch button. Truncates long names with a tail ellipsis
/// and shows the full name on hover.
private struct BranchCell: View {
    let name: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                    .foregroundStyle(tint.opacity(0.85))
                Text(name)
                    .font(.system(size: 11,
                                  design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5,
                                 style: .continuous)
                    .fill(Color.haloSurfaceFaint))
        }
        .buttonStyle(.plain)
        .help("Switch to \(name)")
    }
}

private struct BranchRow: View {
    let name: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundStyle(tint.opacity(0.85))
                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(.haloSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
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
    }
}

// MARK: - AirPods

/// Per-bud battery breakdown for AirPods / Beats. Header shows
/// the device name (so a household with two pairs can tell
/// which one is connected); below, three battery pills — left
/// bud, right bud, and the case — each showing percentage,
/// charging indicator, and a tinted level bar.
///
/// Buds with `nil` battery (in case, lid closed, firmware
/// reported "unknown") render as a faint placeholder rather
/// than being hidden, so the layout doesn't shift around as
/// the buds come in and out of the case.
private struct AirPodsExpandedView: View {
    let activity: LiveActivityCoordinator.Resolved

    private var info: LiveActivityCoordinator.AirPodsInfo? {
        activity.airpods
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let img = activity.compactLeadingImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("AIRPODS")
                        .font(.system(size: 10,
                                      weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(.haloSecondary)
                    if let name = info?.deviceName,
                       !name.isEmpty {
                        Text(name)
                            .font(.system(size: 12,
                                          weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                if info?.charging == true {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9,
                                          weight: .bold))
                        Text("Charging")
                            .font(.system(size: 10,
                                          weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(
                            Color.white.opacity(0.14)))
                }
            }
            Divider().background(Color.haloSurfaceFaint)
            HStack(spacing: 8) {
                BatteryCell(label: "Left",
                            icon: "earbuds",
                            percent: info?.left)
                BatteryCell(label: "Right",
                            icon: "earbuds",
                            percent: info?.right)
                BatteryCell(label: "Case",
                            icon: "earbuds.case.fill",
                            percent: info?.caseBattery)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One battery pill in the AirPods card. `nil` percent renders
/// as a faint "—" so the row keeps its layout while a bud is
/// in the case reporting unknown.
private struct BatteryCell: View {
    let label: String
    let icon: String
    let percent: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(.haloSecondary)
                Text(label.uppercased())
                    .font(.system(size: 9,
                                  weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(.haloSecondary)
                Spacer(minLength: 0)
                if let p = percent {
                    Text("\(p)%")
                        .font(.system(size: 11,
                                      weight: .semibold,
                                      design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                } else {
                    Text("—")
                        .font(.system(size: 11,
                                      weight: .semibold))
                        .foregroundStyle(.haloTertiary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.haloSurfaceFaint)
                    Capsule()
                        .fill(barColor(for: percent))
                        .frame(
                            width: geo.size.width
                                * CGFloat(percent ?? 0) / 100)
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6,
                             style: .continuous)
                .fill(Color.haloSurfaceFaint))
        .frame(maxWidth: .infinity)
    }

    /// Bar colour mirrors the iOS battery indicator: green
    /// above 20%, amber 10–20%, red under 10%. Matches the
    /// same urgency cues the compact-pill glyph uses.
    private func barColor(for p: Int?) -> Color {
        guard let p else { return .haloSurfaceFaint }
        switch p {
        case ..<10:  return Color(red: 1.00,
                                  green: 0.38,
                                  blue: 0.35)
        case ..<20:  return Color(red: 1.00,
                                  green: 0.78,
                                  blue: 0.20)
        default:     return Color(red: 0.30,
                                  green: 0.83,
                                  blue: 0.50)
        }
    }
}

// MARK: - Bluetooth audio

/// Generic Bluetooth speaker / headphones / soundbar card.
/// Shown when the active audio output is a Bluetooth-transport
/// device that ISN'T AirPods/Beats (those have their own
/// per-bud breakdown card). The expanded card surfaces:
///
/// * The device name + form-factor SF Symbol (speaker /
///   headphones / soundbar / earbuds, inferred from name).
/// * Battery percent + level bar when `system_profiler`
///   surfaced one. Some generic AVRCP speakers don't report
///   battery — those just show "Connected".
/// * Eyebrow "BLUETOOTH AUDIO" so the user knows which pill
///   they're looking at when several audio outputs are nearby.
private struct BluetoothAudioExpandedView: View {
    let activity: LiveActivityCoordinator.Resolved

    private var info:
        LiveActivityCoordinator.BluetoothAudioInfo? {
        activity.bluetoothAudio
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: info?.symbol
                      ?? "hifispeaker.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("BLUETOOTH AUDIO")
                        .font(.system(size: 10,
                                      weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(.haloSecondary)
                    Text(info?.name ?? "Connected")
                        .font(.system(size: 13,
                                      weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Text("Connected")
                    .font(.system(size: 9,
                                  weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(
                            Color.white.opacity(0.14)))
            }
            Divider().background(Color.haloSurfaceFaint)
            if let pct = info?.batteryPercent {
                batteryRow(percent: pct)
            } else {
                Text("Battery not reported")
                    .font(.system(size: 10))
                    .foregroundStyle(.haloTertiary)
                    .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func batteryRow(percent: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: batterySymbol(for: percent))
                .font(.system(size: 11))
                .foregroundStyle(.haloSecondary)
                .frame(width: 18, alignment: .center)
            Text("Battery")
                .font(.system(size: 11))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.haloSurfaceFaint)
                Capsule()
                    .fill(barColor(for: percent))
                    .frame(width: 100
                           * CGFloat(percent) / 100)
            }
            .frame(width: 100, height: 4)
            Text("\(percent)%")
                .font(.system(size: 11,
                              weight: .semibold,
                              design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 36, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5,
                             style: .continuous)
                .fill(Color.haloSurfaceFaint))
    }

    private func batterySymbol(for p: Int) -> String {
        switch p {
        case ..<10:  return "battery.0"
        case ..<25:  return "battery.25"
        case ..<50:  return "battery.50"
        case ..<75:  return "battery.75"
        default:     return "battery.100"
        }
    }

    private func barColor(for p: Int) -> Color {
        switch p {
        case ..<10:  return Color(red: 1.00,
                                  green: 0.38,
                                  blue: 0.35)
        case ..<20:  return Color(red: 1.00,
                                  green: 0.78,
                                  blue: 0.20)
        default:     return Color(red: 0.30,
                                  green: 0.83,
                                  blue: 0.50)
        }
    }
}

// MARK: - Battery

/// Per-device battery breakdown. The top row is always the
/// Mac itself — large percentage + level bar + a bolt pill
/// when charging. Below that, a list of every connected
/// device with battery info we can read:
///
/// * HID accessories from IORegistry (Magic Mouse / Trackpad /
///   Keyboard, third-party HID with `BatteryPercent`)
/// * AirPods (read across from the AirPods publisher's
///   payload in `allActivities` — left + right + case folded
///   into a single "lowest of all" pill plus a per-bud
///   breakdown badge)
///
/// Falls back gracefully when no accessories are connected —
/// the card just shows the Mac battery on its own.
private struct BatteryExpandedView: View {
    let activity: LiveActivityCoordinator.Resolved
    let allActivities: [LiveActivityCoordinator.Resolved]

    private var info: LiveActivityCoordinator.BatteryInfo? {
        activity.battery
    }

    /// AirPods state from the sibling `halo.airpods` activity,
    /// when both publishers are active simultaneously. Lets us
    /// list AirPods alongside the Mac + HID devices instead of
    /// fragmenting battery info across two separate dropdowns.
    private var airpods: LiveActivityCoordinator.AirPodsInfo? {
        allActivities.first {
            $0.id == "halo.airpods"
        }?.airpods
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            macRow
            Divider().background(Color.haloSurfaceFaint)
            VStack(spacing: 4) {
                ForEach(info?.devices ?? [], id: \.self) { d in
                    DeviceBatteryRow(
                        name: d.name,
                        symbol: d.symbol,
                        percent: d.percent,
                        charging: false)
                }
                if let ap = airpods {
                    airpodsRow(ap)
                }
                if (info?.devices.isEmpty ?? true)
                   && airpods == nil {
                    Text("No other devices connected")
                        .font(.system(size: 10))
                        .foregroundStyle(.haloTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity,
                               alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var macRow: some View {
        HStack(spacing: 10) {
            if let img = activity.compactLeadingImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("THIS MAC")
                    .font(.system(size: 10,
                                  weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.haloSecondary)
                Text("\(info?.macPercent ?? 0)%")
                    .font(.system(size: 14,
                                  weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
            if info?.macCharging == true {
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9,
                                      weight: .bold))
                    Text("Charging")
                        .font(.system(size: 10,
                                      weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(
                        Color.white.opacity(0.14)))
            }
        }
    }

    private func airpodsRow(
        _ ap: LiveActivityCoordinator.AirPodsInfo
    ) -> some View {
        // Lowest of left / right / case for the headline
        // number — same "show the urgent value" rule the
        // AirPods compact pill uses.
        let lowest = [ap.left, ap.right, ap.caseBattery]
            .compactMap { $0 }.min() ?? 0
        let name = ap.deviceName.isEmpty
            ? "AirPods" : ap.deviceName
        return DeviceBatteryRow(
            name: name,
            symbol: "airpods",
            percent: lowest,
            charging: ap.charging)
    }
}

/// One row in the battery expanded card. Icon + name on the
/// left, percentage + level bar on the right. The whole row
/// dims when battery is unknown (-1) or below the urgency
/// threshold — matches the iOS Now-Playing battery row look.
private struct DeviceBatteryRow: View {
    let name: String
    let symbol: String
    let percent: Int
    let charging: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.haloSecondary)
                .frame(width: 18, alignment: .center)
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9,
                                  weight: .bold))
                    .foregroundStyle(.white)
            }
            // Level bar — same iOS battery palette as the
            // AirPods cells (green > 20%, amber 10-20%, red
            // < 10%).
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.haloSurfaceFaint)
                Capsule()
                    .fill(barColor(for: percent))
                    .frame(width: 60
                           * CGFloat(percent) / 100)
            }
            .frame(width: 60, height: 4)
            Text("\(percent)%")
                .font(.system(size: 11,
                              weight: .semibold,
                              design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 36, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5,
                             style: .continuous)
                .fill(Color.haloSurfaceFaint))
    }

    private func barColor(for p: Int) -> Color {
        switch p {
        case ..<10:  return Color(red: 1.00,
                                  green: 0.38,
                                  blue: 0.35)
        case ..<20:  return Color(red: 1.00,
                                  green: 0.78,
                                  blue: 0.20)
        default:     return Color(red: 0.30,
                                  green: 0.83,
                                  blue: 0.50)
        }
    }
}

// MARK: - Now Playing

/// Rich playback view: album cover thumbnail on the left,
/// title + artist + scrubber in the middle, prev/play-pause/
/// next on the right. Position refreshes on its own 1s timer
/// while visible so the scrubber moves smoothly even without
/// a fresh publish.
private struct NowPlayingExpandedView: View {
    let activity: LiveActivityCoordinator.Resolved

    @State private var livePosition: Double = 0
    @State private var positionTimer: Timer?

    private var media: LiveActivityCoordinator.MediaInfo? {
        activity.media
    }

    var body: some View {
        HStack(spacing: 12) {
            artwork
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6,
                                            style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(media?.title ?? "—")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(media?.artist ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.haloSecondary)
                    .lineLimit(1)
                scrubber
            }
            // Controls stack: play/pause row, then the
            // "position / duration" read-out underneath so
            // the user knows where the scrubber sits without
            // having to glance at the compact pill.
            VStack(spacing: 4) {
                controls
                timeReadout
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { startTicking() }
        .onDisappear { positionTimer?.invalidate() }
        .onChange(of: media?.title) { _, _ in
            livePosition = media?.positionSeconds ?? 0
        }
    }

    /// `00:42 / 03:14` — current position / total duration
    /// under the play / pause row. Uses
    /// `NotchView.dimmedUnitsText` so leading zeros and the
    /// `:` / `/` separators tone down to 50%, matching the
    /// compact pill.
    private var timeReadout: some View {
        let duration = media?.durationSeconds ?? 0
        let pos = Self.formatTime(livePosition)
        let dur = Self.formatTime(duration)
        return NotchView
            .dimmedUnitsText(
                "\(pos) / \(dur)",
                baseColor: NotchView.pillTextColor(for: activity))
            .font(.system(size: 10,
                          weight: .medium,
                          design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
    }

    private static func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    @ViewBuilder
    private var artwork: some View {
        if let img = media?.artwork {
            Image(nsImage: img)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.haloSurfaceFaint)
                Image(systemName: "music.note")
                    .font(.system(size: 18))
                    .foregroundStyle(.haloTertiary)
            }
        }
    }

    private var scrubber: some View {
        let duration = media?.durationSeconds ?? 0
        let progress: Double = {
            guard duration > 0 else { return 0 }
            return min(1, max(0, livePosition / duration))
        }()
        let tint = NotchView.pillTextColor(for: activity)
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.haloSurfaceSoft)
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, proxy.size.width
                                      * CGFloat(progress)))
            }
        }
        .frame(height: 3)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            ControlButton(symbol: "backward.fill") {
                postControl(.previous)
            }
            ControlButton(
                symbol: (media?.isPlaying ?? false)
                    ? "pause.fill" : "play.fill",
                large: true
            ) {
                postControl(.playPause)
            }
            ControlButton(symbol: "forward.fill") {
                postControl(.next)
            }
        }
    }

    // MARK: - Behaviour

    private enum Control { case playPause, next, previous }

    private func postControl(_ c: Control) {
        guard let source = media?.source else { return }
        switch (source, c) {
        case ("Spotify", .playPause): SpotifyScripter.playPause()
        case ("Spotify", .next):      SpotifyScripter.next()
        case ("Spotify", .previous):  SpotifyScripter.previous()
        case ("Music",   .playPause): MusicScripter.playPause()
        case ("Music",   .next):      MusicScripter.next()
        case ("Music",   .previous):  MusicScripter.previous()
        default:
            // MediaRemote control commands need yet another
            // private symbol set — wire on demand.
            break
        }
    }

    /// 1s tick that advances the scrubber locally so it looks
    /// alive between publishes. Re-sync with the publisher's
    /// reading every time the parent activity refreshes.
    private func startTicking() {
        livePosition = media?.positionSeconds ?? 0
        positionTimer = Timer.scheduledTimer(
            withTimeInterval: 1, repeats: true
        ) { _ in
            Task { @MainActor in
                guard media?.isPlaying ?? false else { return }
                livePosition += 1
            }
        }
    }
}

private struct ControlButton: View {
    let symbol: String
    var large: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: large ? 16 : 12,
                              weight: .semibold))
                .frame(width: large ? 28 : 22,
                       height: large ? 28 : 22)
                .foregroundStyle(.white.opacity(large ? 1 : 0.85))
                .background(
                    Circle().fill(
                        large ? Color.haloSurfaceSoft
                              : Color.haloSurfaceFaint))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Espresso

/// Header row (icon + label + countdown) above an action row
/// of quick-extend buttons + an End-session CTA. All four
/// buttons post distributed notifications — Espresso's pane
/// listens and calls `store.extend(byMinutes:)` or
/// `store.deactivate()` on the other side.
private struct EspressoExpandedView: View {
    let activity: LiveActivityCoordinator.Resolved

    private var isActive: Bool {
        // Active state is whatever the publisher chooses to
        // surface in `compactTrailingText`; idle string is
        // literally "OFF".
        (activity.compactTrailingText ?? "OFF") != "OFF"
    }
    private var brand: Color {
        NotchView.pillTextColor(for: activity)
    }
    private var isIndefinite: Bool {
        // Extend buttons only make sense when the session has
        // an end date to push out. The pane writes "ON" for
        // indefinite sessions.
        (activity.compactTrailingText ?? "OFF") == "ON"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header — current state.
            HStack(spacing: 12) {
                if let img = activity.compactLeadingImage {
                    Image(nsImage: NotchView.tinted(
                        img, color: brand))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("ESPRESSO")
                        .font(.system(size: 11,
                                      weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(brand.opacity(0.85))
                    NotchView.dimmedUnitsText(
                        activity.compactTrailingText ?? "OFF",
                        baseColor: .white)
                        .font(.system(size: 14,
                                      weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
            }
            // Action row — extend by N minutes, then End.
            if isActive {
                HStack(spacing: 6) {
                    if !isIndefinite {
                        ExtendPill(label: "+15m", tint: brand) {
                            extend(15)
                        }
                        ExtendPill(label: "+30m", tint: brand) {
                            extend(30)
                        }
                        ExtendPill(label: "+1h", tint: brand) {
                            extend(60)
                        }
                    }
                    Spacer(minLength: 0)
                    Button(action: end) {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 9))
                            Text("End")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(
                                Color.white.opacity(0.10)))
                        .foregroundStyle(.white)
                        .font(.system(size: 11,
                                      weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func extend(_ minutes: Int) {
        DistributedNotificationCenter.default()
            .postNotificationName(
                Notification.Name(
                    "com.mattssoftware.espresso.extend"),
                object: String(minutes),
                deliverImmediately: true)
    }
    private func end() {
        DistributedNotificationCenter.default()
            .postNotificationName(
                Notification.Name(
                    "com.mattssoftware.espresso.stop"),
                object: nil,
                deliverImmediately: true)
    }
}

/// Small brand-tinted pill button for Espresso's
/// quick-extend row.
private struct ExtendPill: View {
    let label: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(tint.opacity(0.18)))
                .overlay(
                    Capsule().stroke(tint.opacity(0.35),
                                     lineWidth: 0.5))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Stats widget

/// 3-row vertical layout — one row per metric, each
/// `[icon] [progress bar] [percentage]`. Samples on-appear
/// and ticks every 1s while visible (the compact-pill
/// publisher uses its own state so we re-sample here
/// independently).
private struct StatsExpandedView: View {
    let activity: LiveActivityCoordinator.Resolved

    @State private var cpu: Int = 0
    @State private var ram: Int = 0
    @State private var disk: Int = 0
    /// Bytes used / total per metric. RAM and disk surface the
    /// absolute numbers ("12.4 GB / 36.0 GB"); CPU's right
    /// column just shows the active-core count.
    @State private var ramBytes: (used: UInt64, total: UInt64) =
        (0, 0)
    @State private var diskBytes: (used: UInt64, total: UInt64) =
        (0, 0)
    /// CPU tick deltas — first sample seeds, second onwards
    /// yields a usable percentage.
    @State private var prevCPUTicks: (total: UInt64, idle: UInt64)?
    @State private var timer: Timer?

    private var brand: Color {
        NotchView.pillTextColor(for: activity)
    }
    private var cpuCores: Int {
        ProcessInfo.processInfo.activeProcessorCount
    }

    var body: some View {
        VStack(spacing: 10) {
            StatRow(
                symbol: "cpu",
                value: cpu,
                detail: "\(cpuCores) cores",
                tint: brand)
            StatRow(
                symbol: "memorychip",
                value: ram,
                detail: Self.formatBytes(ramBytes),
                tint: brand)
            StatRow(
                symbol: "internaldrive",
                value: disk,
                detail: Self.formatBytes(diskBytes),
                tint: brand)
        }
        .frame(maxWidth: .infinity)
        .onAppear { startSampling() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private func startSampling() {
        sampleAll()
        timer = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: true
        ) { _ in
            Task { @MainActor in sampleAll() }
        }
    }

    private func sampleAll() {
        cpu = sampleCPU()
        (ram, ramBytes) = sampleRAMDetail()
        (disk, diskBytes) = sampleDiskDetail()
    }

    /// `12.4 / 36 GB` — used + total in matching units. Pure
    /// "used GB" loses context; "GB free" inverts the meaning
    /// from the bar (which fills with used). This keeps both
    /// numbers and the bar reading consistently.
    private static func formatBytes(
        _ pair: (used: UInt64, total: UInt64)
    ) -> String {
        guard pair.total > 0 else { return "—" }
        let gb = 1024.0 * 1024.0 * 1024.0
        let used = Double(pair.used) / gb
        let total = Double(pair.total) / gb
        // Keep the label short — the row's right column is
        // narrow and we don't want it stealing space from the
        // bar.
        return String(format: "%.1f / %.0f GB", used, total)
    }

    private func sampleCPU() -> Int {
        var size = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size /
            MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(
                to: integer_t.self, capacity: Int(size)
            ) {
                host_statistics(
                    mach_host_self(),
                    HOST_CPU_LOAD_INFO,
                    $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let total = user + system + idle + nice
        defer { prevCPUTicks = (total, idle) }
        guard let prev = prevCPUTicks,
              total > prev.total else { return cpu }
        let totalΔ = total - prev.total
        let idleΔ = idle &- prev.idle
        let busyΔ = totalΔ &- idleΔ
        return Int((Double(busyΔ) / Double(totalΔ)) * 100)
    }

    private func sampleRAMDetail()
        -> (Int, (used: UInt64, total: UInt64))
    {
        var size = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size /
            MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(
                to: integer_t.self, capacity: Int(size)
            ) {
                host_statistics64(
                    mach_host_self(),
                    HOST_VM_INFO64,
                    $0, &size)
            }
        }
        guard result == KERN_SUCCESS
        else { return (0, (0, 0)) }
        let pageSize = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count)
                    + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count))
                    * pageSize
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return (0, (0, 0)) }
        let pct = Int((Double(used) / Double(total)) * 100)
        return (pct, (used, total))
    }

    private func sampleDiskDetail()
        -> (Int, (used: UInt64, total: UInt64))
    {
        var fs = statfs()
        guard statfs("/", &fs) == 0
        else { return (0, (0, 0)) }
        let blockSize = UInt64(fs.f_bsize)
        let total = UInt64(fs.f_blocks) * blockSize
        let free = UInt64(fs.f_bavail) * blockSize
        guard total > 0 else { return (0, (0, 0)) }
        let used = total &- free
        let pct = Int((Double(used) / Double(total)) * 100)
        return (pct, (used, total))
    }
}

/// One metric row: 18pt icon · flex-width bar (tinted in the
/// publisher's brand colour) · 38pt percentage with a small
/// secondary label underneath (RAM and disk show
/// used / total in GB, CPU shows the core count).
private struct StatRow: View {
    let symbol: String
    let value: Int
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint.opacity(0.85))
                .frame(width: 18, alignment: .leading)
            ProgressBar(
                value: Double(value) / 100.0,
                tint: tint)
                .frame(height: 5)
                .frame(maxWidth: .infinity)
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(value)%")
                    .font(.system(size: 12,
                                  weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text(detail)
                    .font(.system(size: 8,
                                  weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.haloTertiary)
            }
            .frame(minWidth: 78, alignment: .trailing)
        }
        .frame(height: 24)
    }
}

private struct ProgressBar: View {
    let value: Double  // 0...1
    let tint: Color
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.haloSurfaceSoft)
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, proxy.size.width
                                      * CGFloat(min(1, max(0, value)))))
            }
        }
    }
}
