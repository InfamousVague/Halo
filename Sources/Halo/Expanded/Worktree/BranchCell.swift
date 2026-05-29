import SwiftUI

/// Grid-cell branch chip used by the recent-branches 3-column
/// grid. Compact (~125pt wide) — just the branch icon + name,
/// no trailing arrow / chevron since the whole cell is the
/// switch button. Truncates long names with a tail ellipsis
/// and shows the full name on hover.
struct BranchCell: View {
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

struct BranchRow: View {
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
