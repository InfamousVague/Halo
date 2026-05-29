import AppKit
import SwiftUI

/// Builds the right-hand half of the compact pill — the read-out
/// (battery %, music time, stats value, etc.). Pairs with the
/// leading half in `NotchView+LeadingPill`.
extension NotchView {
    @ViewBuilder
    func trailingContent(
        for a: LiveActivityCoordinator.Resolved
    ) -> some View {
        if a.id == "worktree", let info = a.worktree {
            // Worktree puts the project name in the leading
            // wing, so the trailing wing carries ONLY the
            // current branch (plus a dirty marker if the
            // working tree has uncommitted changes). White
            // text — branch is the primary data the user
            // reads on the right.
            let marker = info.isDirty ? "*" : ""
            Text("\(info.currentBranch)\(marker)")
                .font(.system(size: 13))
                .foregroundStyle(
                    Self.pillTrailingTextColor(for: a))
                .lineLimit(1)
                .fixedSize()
                .id("trail-worktree-\(info.currentBranch)")
        } else if a.id == "halo.ext.crypto",
                  let info = a.crypto,
                  !info.tickers.isEmpty {
            // Crypto trailing wing: mini sparkline + signed
            // 24h percent change. Mirrors the leaderboard
            // row's right-side stack at compact-pill scale.
            // The sparkline takes the lion's share of the
            // visual weight — at a glance the user reads
            // the trend (green up / red down line) before
            // they parse the number.
            let coin = info.tickers[
                min(info.currentIndex,
                    info.tickers.count - 1)]
            let up = coin.change24h >= 0
            let trendColor: Color = up
                ? Color(red: 0.30,
                        green: 0.83, blue: 0.50)
                : Color(red: 1.00,
                        green: 0.38, blue: 0.35)
            HStack(spacing: 4) {
                if !coin.sparkline.isEmpty {
                    Sparkline(points: coin.sparkline,
                              tint: trendColor)
                        .frame(width: 36, height: 7)
                }
                Image(systemName: up
                      ? "arrow.up" : "arrow.down")
                    .font(.system(size: 9,
                                  weight: .heavy))
                    .foregroundStyle(trendColor)
                Text(String(format: "%.2f%%",
                            abs(coin.change24h)))
                    .font(.system(size: 12,
                                  weight: .semibold,
                                  design: .rounded))
                    .foregroundStyle(trendColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.numericText())
                    .animation(
                        .linear(duration: 0.35),
                        value: coin.change24h)
            }
            .id("trail-crypto-\(coin.symbol)")
        } else if let text = a.compactTrailingText {
            // Letter unit suffixes (the 'h'/'m'/'s' after
            // digits in things like "1h30m" or "5m 23s") drop
            // to 50% — the number is the data, the unit is the
            // label. Pure-letter strings (branch names, etc.)
            // stay at 100%.
            //
            // `.contentTransition(.numericText())` gives
            // numeric digit changes the iOS-style slot-machine
            // roll. Espresso's 1Hz countdown / music position
            // / volume HUD percentages now ticker rather than
            // crossfade.
            //
            // Optional `compactTrailingPrefixSymbol` (SF Symbol
            // name) renders inline as a glyph BEFORE the
            // dimmed text — used by the battery pill to
            // prepend a bolt when the Mac is charging.
            let baseColor = Self.pillTrailingTextColor(for: a)
            HStack(spacing: 3) {
                if let sym = a.compactTrailingPrefixSymbol {
                    Image(systemName: sym)
                        .font(.system(size: 11,
                                      weight: .semibold))
                        .foregroundStyle(baseColor)
                }
                // Plain `Text(text)` — not the per-character
                // dimmedUnitsText. SwiftUI's
                // `.contentTransition(.numericText())` slot-
                // machine roll only fires on a single coherent
                // Text identity; the previous AttributedString
                // approach (and its predecessor concatenated
                // `Text + Text + …`) both fragmented the
                // identity enough that SwiftUI fell back to
                // a crossfade. We trade per-character leading-
                // zero / unit dimming for the rolling
                // animation here — the digit roll is the
                // visual cue the pill is live.
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(baseColor)
                    // Monospaced numerals so a `5` and an
                    // `8` occupy the same horizontal slot —
                    // the roll lines up cleanly and the pill
                    // never reshapes a hair as digits tick.
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.numericText())
                    // Drive the digit-by-digit roll on a
                    // linear clock; the parent ZStack's
                    // spring animation otherwise carries the
                    // text change and overrides the
                    // contentTransition's frame budget,
                    // collapsing it to a crossfade.
                    .animation(
                        .linear(duration: 0.35),
                        value: text)
            }
            .id("trail-text-\(a.id)")
        } else if let img = a.compactTrailingImage {
            Image(nsImage: tintImage(
                img, color: Self.pillIconColor(for: a)))
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .opacity(0.9)
                .id("trail-img-\(a.id)")
                .animation(nil, value: a.compactTrailingText)
        }
    }

    /// Concatenates the string as `Text` runs, dimming the
    /// "labels" around digits while leaving the meaningful
    /// digits at full punch. Three categories of dim:
    ///
    /// * **Unit letters** at 50% — `h`/`m`/`s`/`d` after a
    ///   digit in `1h30m`, `5m 23s`, `1d4h`.
    /// * **Leading zeros** at 50% — a `0` that starts a
    ///   digit-run AND is padding a real (non-zero) value.
    ///   So both `0`s in `03:00 / 03:29` dim (each is padding
    ///   the leading `3`), the `0` in `01:23` dims, and the
    ///   `0` after `:` in `01:05` also dims (it's padding the
    ///   `5`). But the `00` in `10:00` or `00:48` stays
    ///   bright — the whole digit-run is zero, no real value
    ///   to pad, the `0`s *are* the value.
    /// * **Numeric punctuation** at 70% — `:`, `/`, `%` when
    ///   the string is clearly a numeric label (a digit
    ///   immediately followed by `:` or `%` somewhere). At
    ///   70% rather than 50% so the structural separators
    ///   stay readable; the units / leading-zero placeholders
    ///   are quieter (50%) since they're labels, not glyphs
}
