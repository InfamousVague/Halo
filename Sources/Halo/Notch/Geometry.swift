import AppKit
import SwiftUI

// MARK: - Geometry

/// Shared layout math for the island. The body of `NotchView`
/// uses it to lay the SwiftUI content out; `NotchHost`'s
/// hit-test view uses the same numbers to decide whether a
/// mouse event lands inside the visible pill.
///
/// Single source of truth — both sides have to agree on the
/// pill's bounds or hit-testing drifts from the visible shape.
enum Geometry {
    /// Minimum width past the notch's edges on each side. The
    /// pill grows past this when content demands.
    static let sidePad: CGFloat = 40
    /// Radius of the concave outer corner (matches the masking
    /// circle that lives just outside the pill on each side).
    static let punchRadius: CGFloat = 12
    /// Convex radius at the pill body's bottom corners.
    static let bottomCornerRadius: CGFloat = 10
    /// Inset between the pill's outer edge and the leading/
    /// trailing content.
    static let contentInset: CGFloat = 22
    /// Minimum gap between content and the physical notch
    /// cutout so the icon/text never sit under the camera.
    static let notchClearance: CGFloat = 12
    /// Standard fixed width the island always grows to when
    /// expanded. Every dropdown sits in the exact same
    /// footprint regardless of which activity is driving it
    /// (Port grid, Worktree branches, Now Playing controls,
    /// AirPods cells, …) — the card centres on the notch
    /// and the compact pill morphs into / out of this single
    /// canonical shape on hover. Sized to comfortably hold
    /// the Now-Playing compact row (18pt artwork + 6pt gap
    /// + 120pt title slot + insets + notch + trailing time)
    /// which is the widest of any pill we render.
    static let expandedWidth: CGFloat = 480

    /// Predicted width of the leading content slot for an
    /// activity. Mirrors `NotchView.leadingContent`'s sizes:
    /// just the 18pt artwork / icon thumbnail by default, but
    /// for now-playing pills the song title sits next to the
    /// album cover so the slot widens to include it (capped
    /// at `maxTitleWidth` to keep an enormous track name from
    /// pushing the pill off the screen).
    static func leadingWidth(
        for a: LiveActivityCoordinator.Resolved?
    ) -> CGFloat {
        guard let a else { return 0 }
        // Now-playing sources without artwork render the
        // brand-tinted source icon next to the track title
        // on the leading wing (same shape as Spotify's
        // artwork-with-title, just with a logo standing in
        // for the thumbnail). YouTube's logo is 22pt wide
        // (the proper aspect ratio of the play-rectangle
        // mark) — everyone else stays at the standard 18pt.
        if a.id == "halo.nowplaying",
           let media = a.media,
           media.artwork == nil,
           !media.title.isEmpty,
           NowPlayingPublisher.titleRendersOnLeading(media) {
            let iconW: CGFloat =
                (media.source == "YouTube"
                 || media.source == "YouTube Music")
                ? 22 : 18
            return iconW + 6 + 120
        }
        if a.id == "worktree", let info = a.worktree {
            // Git icon + project name (capped at 140pt so a
            // huge folder name doesn't push the trailing
            // branch off the screen). Mirror the renderer.
            let projectName = info.displayName
                ?? ((info.repoPath as NSString)
                        .lastPathComponent)
            let w = min(140,
                        measureText(projectName, size: 13))
            return 18 + 6 + w
        }
        if a.id == "halo.ext.crypto",
           let info = a.crypto,
           !info.tickers.isEmpty {
            // Logo (18) + spacing (5) + ticker symbol text
            // at 13pt bold rounded. Mirror the renderer.
            let coin = info.tickers[
                min(info.currentIndex,
                    info.tickers.count - 1)]
            return 18 + 5
                + measureText(coin.symbol, size: 13)
        }
        if a.media?.title != nil {
            // Pinned width regardless of the song's natural
            // text width. Used to be \`min(measured, cap)\`,
            // which made the pill (and the expanded dropdown
            // that grows from it) shrink and grow with each
            // track. That reflow was jarring when skipping
            // — fix at the cap so "Bad Habit" and "I Had
            // Some Help (Feat. Morgan Wallen)" produce the
            // same compact + expanded geometry; MarqueeText
            // pads short titles inside the slot and tickers
            // long ones.
            let titleSlot: CGFloat = 120
            // artwork (18) + HStack spacing (6) + title slot
            return 18 + 6 + titleSlot
        }
        return a.compactLeadingImage != nil ? 18 : 0
    }

    /// Predicted width of the trailing content slot. Text is
    /// measured with NSString's typesetting against the same
    /// font NotchView renders with.
    static func trailingWidth(
        for a: LiveActivityCoordinator.Resolved?
    ) -> CGFloat {
        guard let a else { return 0 }
        if a.id == "worktree", let info = a.worktree {
            // Just the current branch + optional dirty
            // marker — no longer the full project·branch
            // label the previous layout packed in here.
            let marker = info.isDirty ? "*" : ""
            return measureText(
                "\(info.currentBranch)\(marker)", size: 13)
        }
        if a.id == "halo.ext.crypto",
           let info = a.crypto,
           !info.tickers.isEmpty {
            // Sparkline (36) + spacing (4) + arrow glyph
            // (~10) + spacing (4) + percent text. Mirror
            // the renderer's HStack so the pill sizes
            // tight to whatever the change number renders
            // at.
            let coin = info.tickers[
                min(info.currentIndex,
                    info.tickers.count - 1)]
            let pct = String(
                format: "%.2f%%", abs(coin.change24h))
            let textW = measureText(pct, size: 12)
            return 36 + 4 + 10 + 4 + textW
        }
        if let text = a.compactTrailingText {
            var w = measureText(text, size: 13)
            // The inline glyph (bolt for the charging battery
            // pill, …) renders at ~11pt + a 3pt gap before
            // the text. Add it to the measured width so the
            // pill grows enough to fit both.
            if a.compactTrailingPrefixSymbol != nil {
                w += 13
            }
            return w
        }
        if a.compactTrailingImage != nil { return 16 }
        return 0
    }

    /// Per-activity extra height for the expanded card. Sums
    /// the activity's intrinsic content height + the card's
    /// internal padding (12 top + 14 bottom = 26pt). Lets the
    /// island fit content tightly rather than sitting on a
    /// fixed bottom-padding floor.
    static func expandedExtraHeight(
        for a: LiveActivityCoordinator.Resolved?,
        hasAirpods: Bool = false
    ) -> CGFloat {
        // 16 top + 16 bottom — symmetric vertical insets,
        // matches `ExpandedCard`'s internal padding. Both
        // edges get the same breathing room so the dropdown
        // reads as a balanced canvas regardless of which
        // sub-view is mounted inside it. Crypto uses 4/16
        // (see ExpandedCard.body's per-id override) so the
        // dense grid title doesn't sit too low.
        let padding: CGFloat = a?.id == "halo.ext.crypto"
            ? (4 + 16) : (16 + 16)
        let content: CGFloat
        switch a?.id {
        case "halo.stats":
            // 3 rows × 24pt (bar + two-line right column with
            // % over an absolute-value sublabel) + 2 gaps × 10pt
            // = 92pt
            content = 92
        case "halo.battery":
            // Mac header row (~38pt — eyebrow + percentage +
            // optional Charging pill) + divider + a row per
            // connected device (~32pt: 11pt label + 5pt vert
            // pad × 2 + breathing). Plus +1 row when AirPods
            // is active (surfaced by BatteryExpandedView from
            // the sibling `halo.airpods` activity). Empty-
            // state shows a small "no devices" placeholder.
            let hidCount = a?.battery?.devices.count ?? 0
            let rowCount = max(1,
                hidCount + (hasAirpods ? 1 : 0))
            content = 38 + 12 + CGFloat(rowCount) * 32
        case "halo.airpods":
            // Header row (~26pt with the device name on its
            // second line) + divider + the row of three
            // battery cells (~44pt: 9pt label + 4pt gap +
            // 4pt bar + 5pt × 2 vertical pad + breathing).
            content = 26 + 12 + 44
        case "halo.bluetoothaudio":
            // Header row + divider + a small battery-bar /
            // codec block. When battery is known: ~64pt for
            // the bar row. When not known: just the
            // connection eyebrow.
            let hasBat = a?.bluetoothAudio?
                .batteryPercent != nil
            content = 36 /* header */
                + 12 /* divider */
                + (hasBat ? 36 : 20)
        case "halo.ext.crypto":
            // Sort-tab strip (~24pt) at the top + 3×3 grid
            // of compact pills (3 rows × 66pt each — 16pt
            // logo+symbol row + 14pt price + 10pt sparkline
            // + 7pt vert pad × 2 + 3pt VStack spacing × 2 +
            // 6pt slack for SwiftUI's rounded-design font
            // line metrics) + footer (~16pt) for the
            // "updated X ago" timestamp.
            let pillCount = min(9,
                a?.crypto?.tickers.count ?? 0)
            let rows = max(1, (pillCount + 2) / 3)
            content = 24 + 8 /* sort strip + gap */
                + CGFloat(rows) * 66 + CGFloat(rows - 1) * 6
                + 8 /* gap */ + 16

        case "halo.nowplaying":
            // Artwork is 44pt tall and dominates the row. The
            // title + artist + scrubber stack and the
            // controls + time-readout stack both fit inside
            // that height, so 44 is exactly the row height —
            // anything extra is dead space below the card.
            content = 44
        case "worktree":
            // Repo header + recent-branches grid + footer
            // actions. The branches grid is 3 columns × up to
            // 2 rows (≤ 6 branches) — ceil((branches - current)
            // / 3) gives the row count. Each grid cell is
            // ~32pt tall (5pt vpad × 2 + 11pt text + a touch).
            // Anything else the WorktreeExpandedView renders
            // (REMOTES, WORKTREES, SAVED) lives inside its own
            // ScrollView, which scrolls inside this frame
            // rather than growing the card.
            let switchable = min(6, max(0,
                (a?.worktree?.branches.count ?? 1) - 1))
            let gridRows = max(1, (switchable + 2) / 3)
            let gridBlock = CGFloat(gridRows) * 32 + 20
                /* + 20pt for the section's RECENT BRANCHES
                   eyebrow + the inter-row breathing space */
            content = 36 /* header */
                + 8 /* gap */ + gridBlock
                + 8 /* gap */ + 28 /* footer */
        case "port":
            // Header row (eyebrow + count, ~30pt) + divider +
            // 2-column grid of port rows. With the standard
            // `expandedMinWidth` (440pt) we fit two cards per
            // row comfortably; up to 6 entries means at most
            // ceil(6 / 2) = 3 grid rows, exactly filling the
            // 2×3 grid. 30pt per row covers the 12pt label
            // + the row's vertical padding plus a touch for
            // the inter-row gap.
            let entryCount = min(6,
                a?.port?.entries.count ?? 0)
            let gridRows = (entryCount + 1) / 2
            let headerHeight: CGFloat = 30
            let dividerPad: CGFloat = 12
            let rowsHeight = gridRows > 0
                ? CGFloat(gridRows) * 30 + dividerPad
                : 0
            content = headerHeight + rowsHeight
        case "espresso":
            // State row (~26pt: eyebrow + value + the End button,
            // all on one line). Timed sessions add a second row
            // (~24pt) of quick-extend pills + an 8pt gap;
            // indefinite "ON" / "OFF" are a single row.
            let txt = a?.compactTrailingText ?? "OFF"
            let timed = txt != "OFF" && txt != "ON"
            content = 26 + (timed ? 8 + 24 : 0)
        default:
            // Generic row: 26pt icon + spacing ≈ 30pt
            content = 30
        }
        return content + padding
    }

    /// The visible pill's frame in panel-local coordinates with
    /// the SwiftUI convention (origin top-left). The pill's
    /// left and right wings size INDEPENDENTLY to their own
    /// content — long trailing text doesn't force an empty
    /// left wing to match, and vice versa.
    ///
    /// When `expanded`, the island grows **straight down** —
    /// same width and same horizontal position as the compact
    /// pill, just taller by `expandedExtraHeight`. The compact
    /// row fades to opacity 0 but keeps its layout space so
    /// the pill doesn't shift sideways on hover.
    static func islandFrame(
        for a: LiveActivityCoordinator.Resolved?,
        layout: NotchLayout,
        expanded: Bool = false,
        hasAirpods: Bool = false,
        measuredExpandedHeight: CGFloat = 0
    ) -> CGRect {
        let notchW = layout.notchTrailingX - layout.notchLeadingX
        let leadW = leadingWidth(for: a)
        let trailW = trailingWidth(for: a)
        var leftHalf = max(
            leadW + contentInset + notchClearance,
            sidePad)
        var rightHalf = max(
            trailW + contentInset + notchClearance,
            sidePad)
        // Symmetry mode — both wings sized to the wider of the
        // two so the pill stays visually centred on the notch's
        // hardware midpoint instead of sliding left/right as
        // content widens on one side. Optional because the
        // asymmetric form is more space-efficient when only one
        // side has data (e.g. battery's trailing percentage
        // with an empty leading wing).
        if HaloSettings.symmetryEnabled {
            let half = max(leftHalf, rightHalf)
            leftHalf = half
            rightHalf = half
        }
        var totalWidth = leftHalf + notchW + rightHalf
        var totalHeight = layout.menuBarHeight + 1
        // When compact the pill hangs asymmetrically off the
        // notch's leading edge so it tracks the menu bar's
        // built-in clock. When expanded we snap to a single
        // canonical `expandedWidth` and centre on the notch
        // — every dropdown reads as the same UI element
        // regardless of which publisher is driving it (Port
        // grid, Worktree branches, Now Playing controls, …).
        // The width is a strict force, not a minimum: even
        // pills that are naturally wider than the expanded
        // width (the Now Playing title slot is borderline)
        // get squeezed down to match so the card outline is
        // visually consistent.
        var leftEdge = layout.notchLeadingX - leftHalf
        if expanded {
            // Prefer SwiftUI's measurement when available
            // — pixel-perfect, no manual maintenance. Fall
            // back to the heuristic on first render before
            // the measurement has propagated.
            let extra = measuredExpandedHeight > 0
                ? measuredExpandedHeight
                : expandedExtraHeight(
                    for: a, hasAirpods: hasAirpods)
            totalHeight += extra
            let notchCenter =
                layout.notchLeadingX + notchW / 2
            totalWidth = expandedWidth
            leftEdge = notchCenter - totalWidth / 2
        }
        return CGRect(
            x: leftEdge, y: 0,
            width: totalWidth, height: totalHeight)
    }

    /// Measure a string's drawn width using NSString's
    /// typesetting. Matches `Text(.system(size: 13))` — same
    /// regular-weight system font the menu-bar clock uses.
    static func measureText(
        _ s: String, size: CGFloat
    ) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        return ceil((s as NSString).size(
            withAttributes: attrs).width) + 2
    }
}

