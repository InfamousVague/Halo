# Code Style

- Mirror sibling suite apps (`worktree-swift`, `espresso-swift`,
  `seasick-swift`): SwiftPM, `@main` SwiftUI + `@MainActor`
  AppDelegate, LSUIElement.
- UI state lives in dedicated `@Observable @MainActor` types
  (`LiveActivityCoordinator`); views stay declarative.
- All windowing (`NSPanel`, hosting view, screen observers) lives
  in `NotchHost`. The SwiftUI layer never touches AppKit window
  APIs directly.
- The island must be **click-through** during Phase 0
  (`ignoresMouseEvents = true`). Phase 2 introduces custom
  `NSView.hitTest` geometry so hover-to-expand can land taps on
  the island only — without that, full-screen-width capture
  would swallow the entire menu bar.
- All cross-process publishes go through `SuiteLiveActivityStore`
  in SuiteKit. Halo never reads in-process pane state directly.
- Coordinate polling at 1 Hz unless there's a concrete reason to
  go faster (Espresso's countdown precision is the current
  baseline; nothing else needs sub-second).
