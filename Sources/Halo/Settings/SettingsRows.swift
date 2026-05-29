import SwiftUI

// MARK: - Sidebar item

/// Single nav-rail row. Selected = 6%-white fill + 0.98-white
/// label at weight .semibold. Hover lifts to the same fill
/// but keeps the .regular weight, so the selected state
/// reads through the bump alone. No accent color, no left
/// bar, no border — Libre.academy's monochrome treatment.
struct SidebarItem: View {
    let section: SettingsSection
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: section.symbol)
                    .font(.system(size: 11,
                                  weight: isSelected
                                    ? .semibold
                                    : .regular))
                    .frame(width: 14, height: 14)
                Text(section.label)
                    .font(.system(
                        size: 13,
                        weight: isSelected
                            ? .semibold
                            : .regular))
                    // Sidebar is sized for the longest
                    // single-word label; lineLimit(1) is
                    // the safety net so anything that
                    // exceeds the rail still tail-truncates
                    // instead of wrapping mid-word.
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(
                (isSelected || isHovered)
                    ? .white
                    : .white.opacity(0.71))
            // Uniform 10pt pad on every edge — the previous
            // 10/6 split made the highlighted pill read
            // wider than tall against its content. Symmetric
            // insets give the row a balanced silhouette,
            // matching Apple's own sidebar treatment in
            // System Settings.
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 6,
                                 style: .continuous)
                    .fill(
                        (isSelected || isHovered)
                            ? Color.white.opacity(0.06)
                            : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Toggle row

/// Content-column toggle row. Flush against the column — no
/// surrounding card. Title + subtitle stack on the left, an
/// SF Symbol leading the row, switch on the right. Tracks the
/// Libre.academy treatment: monochrome, hairline only when
/// structurally required, weight bump for the active state.
struct DrawerToggle: View {
    let title: String
    let subtitle: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        // Explicit HStack with Spacer so the switch hard-
        // right-aligns to the row's trailing edge regardless
        // of how short or long the title/subtitle is. The
        // built-in `Toggle` label layout pushes the switch
        // away from the trailing edge once the label is
        // narrow, which made the column of switches look
        // ragged.
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13,
                              weight: .medium))
                .foregroundStyle(isOn
                    ? AnyShapeStyle(Color.haloBrand)
                    : AnyShapeStyle(
                        Color.white.opacity(0.5)))
                .frame(width: 18, height: 18,
                       alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13,
                                  weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false,
                               vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Color.haloBrand)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 10pt vertical pad mirrors the sidebar pill's own
        // 10pt — toggle rows on the right and nav rows on the
        // left share the same row height so the eye reads the
        // drawer as one consistent grid.
        .padding(.vertical, 10)
    }
}

/// Suite-slot variant of the toggle that reads / writes
/// through `SettingsBindings.suiteSlotEnabled` so updates
/// immediately poke the coordinator (otherwise the new
/// visibility waits up to a second for the next 1Hz poll).
struct SuiteToggle: View {
    let slot: SuiteSlot
    let bindings: SettingsBindings

    @State private var isOn: Bool

    init(slot: SuiteSlot, bindings: SettingsBindings) {
        self.slot = slot
        self.bindings = bindings
        _isOn = State(initialValue:
            bindings.suiteSlotEnabled(slot.id))
    }

    var body: some View {
        DrawerToggle(
            title: slot.title,
            subtitle: slot.subtitle,
            symbol: slot.symbol,
            isOn: Binding(
                get: { isOn },
                set: { v in
                    isOn = v
                    bindings.setSuiteSlotEnabled(
                        slot.id, v)
                }))
    }
}

/// Extension-toggle row — same pattern as SuiteToggle but
/// gated on `extensionEnabled` / `setExtensionEnabled` so
/// toggling restarts the publishers pipeline (the matching
/// extension class spins up or tears down).
struct ExtensionToggle: View {
    let extensionMeta: ExtensionMeta
    let bindings: SettingsBindings

    @State private var isOn: Bool

    init(extensionMeta: ExtensionMeta,
         bindings: SettingsBindings) {
        self.extensionMeta = extensionMeta
        self.bindings = bindings
        _isOn = State(initialValue:
            bindings.extensionEnabled(extensionMeta.id))
    }

    var body: some View {
        DrawerToggle(
            title: extensionMeta.title,
            subtitle: extensionMeta.subtitle,
            symbol: extensionMeta.symbol,
            isOn: Binding(
                get: { isOn },
                set: { v in
                    isOn = v
                    bindings.setExtensionEnabled(
                        extensionMeta.id, v)
                }))
    }
}
