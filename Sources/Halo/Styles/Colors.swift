import SwiftUI

/// Halo's design tokens — the single source of truth for every
/// colour value the UI reads. Adding a new tone? Add it here,
/// not on a per-view extension. Reading a value? Always go
/// through these tokens so a future theme swap is one edit.
///
/// ## Hierarchy
///
/// - **Primary text** → `.white` (100%) — the data being read.
/// - **Secondary text** → `.haloSecondary` (62%) — labels,
///   subtitles, captions sitting next to primary data.
/// - **Tertiary text / icons** → `.haloTertiary` (40%) —
///   metadata, affordances, empty-state copy.
/// - **Faint surface** → `.haloSurfaceFaint` (8%) — cell /
///   progress-bar backgrounds; the most subtle separation
///   from the island's black surface.
/// - **Soft surface** → `.haloSurfaceSoft` (14%) — pill
///   buttons, dividers, hover states.
/// - **Brand** → `.haloBrand` — warm gold, the "this control
///   is engaged" accent used by the settings drawer and any
///   on/off state that needs to read as ACTIVE.
///
/// ## Why two extensions
///
/// The tokens live on `ShapeStyle where Self == Color` so the
/// dot-shorthand `.foregroundStyle(.haloTertiary)` works (which
/// resolves against `ShapeStyle`, not `Color`), AND on plain
/// `Color` so `Color.haloX` still works for places that hand a
/// `Color` value directly into e.g. a `Shape`'s `.fill(_:)`.

extension ShapeStyle where Self == Color {
    /// 62%-white. Labels, subtitles, anything paired with
    /// primary `.white` data.
    static var haloSecondary: Color {
        Color.white.opacity(0.62)
    }
    /// 40%-white. Metadata, icons, tertiary affordances.
    static var haloTertiary: Color {
        Color.white.opacity(0.4)
    }
    /// 8%-white. Cell / track / progress-bar backgrounds.
    static var haloSurfaceFaint: Color {
        Color.white.opacity(0.08)
    }
    /// 14%-white. Pill buttons, dividers, hover states.
    static var haloSurfaceSoft: Color {
        Color.white.opacity(0.14)
    }
}

extension Color {
    /// 62%-white. See `ShapeStyle.haloSecondary` above.
    static var haloSecondary: Color {
        Color.white.opacity(0.62)
    }
    /// 40%-white. See `ShapeStyle.haloTertiary` above.
    static var haloTertiary: Color {
        Color.white.opacity(0.4)
    }
    /// 8%-white. See `ShapeStyle.haloSurfaceFaint` above.
    static var haloSurfaceFaint: Color {
        Color.white.opacity(0.08)
    }
    /// 14%-white. See `ShapeStyle.haloSurfaceSoft` above.
    static var haloSurfaceSoft: Color {
        Color.white.opacity(0.14)
    }
    /// Halo's primary brand colour — warm gold, sized to read
    /// punchy on OLED black without going neon. Used for
    /// active states: toggle on-position, selected nav row
    /// accent, the on-state of any "this is engaged" UI in
    /// the settings drawer.
    static let haloBrand = Color(
        red: 0.96, green: 0.78, blue: 0.30)
}
