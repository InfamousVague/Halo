import SwiftUI

/// Self-measuring preference key — `ExpandedCard.body`
/// publishes its rendered height through this, `NotchView`
/// observes it, and `NotchHost` uses the measured value to
/// size the NSPanel to exactly the content's natural height.
/// Removes the need to hand-maintain an `expandedExtraHeight`
/// heuristic for every activity.
///
/// (Visual tokens used by expanded sub-views — `.haloSecondary`
/// et al — live in `Sources/Halo/Styles/Colors.swift`, not
/// here. This file is just the size-measurement plumbing.)
struct ExpandedCardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat,
                       nextValue: () -> CGFloat) {
        // Take the most recent value, not the max — when
        // activities cycle the card's content shrinks/grows
        // and we want the panel to track the current value,
        // not the all-time-max.
        value = nextValue()
    }
}
