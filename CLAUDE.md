# halo

Native macOS Dynamic Island for the MacBook notch. Standalone
LSUIElement agent that owns a borderless `NSPanel` pinned at the
top of the screen and renders a rounded-rectangle island shape
hanging from the screen edge. Polls the shared on-disk
`SuiteLiveActivityStore` and renders the highest-priority
payload — every MattsSoftware suite app (and any third-party
publisher) writes there.

## Commit Convention

Angular commits with required scope. See @.claude/rules/commit-rules.md.

## Code Style

See @.claude/rules/code-style.md.

## Architecture

- `Sources/Halo/HaloApp.swift` — `@main` SwiftUI App + AppDelegate
  (NSStatusItem for settings + Quit; settings popover). Empty
  Scene because the island IS the UI.
- `Sources/Halo/NotchHost.swift` — borderless `NSPanel` at
  `.popUpMenu` level, full-screen-width, click-through. Owns the
  `LiveActivityCoordinator`. Resolves notch geometry on screen-
  parameter changes (re-positions on dock / undock).
- `Sources/Halo/LiveActivityCoordinator.swift` — 1 Hz poll of
  `~/Library/Application Support/MattsSoftware/live-activity/*.json`.
  Decodes `SuiteLiveActivityStore.Payload`, drops stale (>30s),
  publishes via `@Observable`.
- `Sources/Halo/NotchView.swift` — SwiftUI shape:
  `UnevenRoundedRectangle` with small top corners + larger
  bottom corners, hanging from the screen top. Icon left, text
  right inside the "tray" band below the menu-bar level.
- `Sources/Halo/HaloSettings.swift` — UserDefaults facade.

## Suite integration

Any app — pane, standalone agent, or third-party — publishes a
`SuiteLiveActivityStore.Payload` JSON to the shared dir to claim
a slot. Halo reads, sorts by priority, renders the winner.

Example (from Espresso when its keep-awake is active):

```swift
try SuiteLiveActivityStore.write(
    .init(
        compactLeadingSymbol: "cup.and.saucer.fill",
        compactTrailingText: "1:23",
        tintHex: "#CD9E6B",
        priority: 60),
    for: "espresso")
```

Idle / quit → call `SuiteLiveActivityStore.clear("espresso")` so
the pill disappears.

## Running

```
swift build
swift run                 # island appears at top of screen
bash scripts/make-app.sh  # produces Halo.app + Halo.dmg
                          # (Developer-ID signed + notarized)
open Halo.app             # run the bundled agent
```

## Permissions

None. Halo doesn't read other processes, doesn't observe focus,
doesn't tap events. It only writes the on-disk shared-store
directory and renders into its own NSPanel.
