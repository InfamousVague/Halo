import SwiftUI

/// Brand assets — the literal colour values and composited
/// vector marks Halo paints for specific third-party brands.
/// Pure design data (no decision logic) — when the YouTube
/// favicon updates or Git changes its primary hex, those edits
/// land here in isolation.
extension NotchView {
    /// The official Git logo colour
    /// ([git-scm.com](https://git-scm.com)), used so the
    /// Jason Long Git icon reads in its native palette
    /// rather than tinted to match the worktree-green
    /// hex.
    static let gitBrandColor = Color(
        red: 0.945, green: 0.314, blue: 0.184)

    /// Composited YouTube logo — red rounded rectangle with a
    /// white play triangle on top. The single SF Symbol
    /// `play.rectangle.fill` template-tints into a solid red
    /// square (everything inside the rect becomes the same
    /// colour as the fill), so the triangle has to be a
    /// separate layer. Same aspect / proportions as the
    /// official YouTube favicon — wider than tall.
    static var youTubeLogo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4,
                             style: .continuous)
                .fill(Color(red: 1.0,
                            green: 0.0,
                            blue: 0.0))
            Image(systemName: "play.fill")
                .font(.system(size: 8,
                              weight: .black))
                .foregroundStyle(.white)
                // Optical centring — a right-pointing
                // triangle's geometric centre sits left of
                // its visual centre of mass, so we nudge it
                // half a point to the right.
                .offset(x: 0.5, y: 0)
        }
        .frame(width: 22, height: 16)
    }
}
