import AppKit
import SwiftUI

/// Small rendering primitives shared by the leading + trailing pill
/// builders: the h/m/s unit-dimming text renderer and the NSImage
/// tinting helpers.
extension NotchView {
    static func dimmedUnitsText(
        _ s: String,
        baseColor: Color = .white
    ) -> Text {
        // Builds the result as a single `AttributedString`
        // with per-character `foregroundColor` attributes,
        // not as a chain of `Text + Text + …` concatenations.
        // SwiftUI's `.contentTransition(.numericText())` only
        // does the slot-machine roll when the value is ONE
        // coherent Text — a chain of per-character Text runs
        // gets treated as several independent transition
        // units and falls back to crossfade, losing the
        // digit-by-digit ticker effect. AttributedString
        // preserves a single identity so the roll animation
        // fires across the whole string.
        let chars = Array(s)
        // Detect "this is a numeric label" — a digit
        // immediately followed by `:` or `%` somewhere in the
        // string. Used to gate the punctuation dimming.
        let isNumericContext: Bool = {
            for i in 0..<chars.count where chars[i].isNumber {
                guard i + 1 < chars.count else { continue }
                let next = chars[i + 1]
                if next == ":" || next == "%" { return true }
            }
            return false
        }()
        // Precompute the indices of every leading-zero
        // character. A `0` dims iff it sits in the
        // "leading-zero run" of its token — i.e. start of
        // string / whitespace / `/`, followed by zero or
        // more consecutive `0`s, before the first non-`0`
        // character. So `00:53` dims both prefix zeros (the
        // whole minutes field is zero-padded), `01:23` dims
        // only the first, `10:00` dims none (the trailing
        // zeros come after a non-zero digit), and `0%` dims
        // the lone `0` because it's still the leading zero
        // of its token.
        let leadingZeroIndices: Set<Int> = {
            var indices: Set<Int> = []
            var inLeadingRun = true
            for i in 0..<chars.count {
                let ch = chars[i]
                if inLeadingRun && ch == "0" {
                    indices.insert(i)
                } else if ch == "0" {
                    // 0 outside a run: ignored, no state change
                } else if ch.isWhitespace || ch == "/" {
                    // Token boundary — re-enter the run for
                    // the next token's prefix.
                    inLeadingRun = true
                } else {
                    // Anything else (digits 1-9, `:`, `%`,
                    // letters…) ends the current run.
                    inLeadingRun = false
                }
            }
            return indices
        }()
        var attr = AttributedString()
        for i in 0..<chars.count {
            let ch = chars[i]
            let opacity: Double = {
                // Single-letter unit after a digit (h/m/s/d).
                if ch.isLetter {
                    guard i > 0, chars[i - 1].isNumber else {
                        return 1.0
                    }
                    // The next char (if any) should NOT also
                    // be a letter — otherwise we'd be in the
                    // middle of a word ("Mango" with a
                    // preceding "10").
                    if i + 1 < chars.count,
                       chars[i + 1].isLetter {
                        return 1.0
                    }
                    return 0.5
                }
                // Numeric punctuation in a numeric run.
                if isNumericContext &&
                   (ch == ":" || ch == "/" || ch == "%") {
                    return 0.7
                }
                // Leading zero — precomputed above. Dims
                // the whole zero-prefix of each token,
                // including all-zero runs like the `00` in
                // `00:53` (the minutes value is zero,
                // padded for width). Mid-token zeros stay
                // bright (`03:09`'s second `0`).
                if leadingZeroIndices.contains(i) {
                    return 0.5
                }
                return 1.0
            }()
            var charAttr = AttributedString(String(ch))
            charAttr.foregroundColor =
                baseColor.opacity(opacity)
            attr.append(charAttr)
        }
        return Text(attr)
    }

    /// Paint a template NSImage with the activity's tint.
    func tintImage(_ img: NSImage, color: Color) -> NSImage {
        Self.tinted(img, color: color)
    }

    /// Static variant the expanded views in `ExpandedCard` use
    /// to colour their header glyphs without each one having
    /// to re-implement the source-atop fill.
    static func tinted(_ img: NSImage, color: Color) -> NSImage {
        let nsColor = NSColor(color)
        let copy = img.copy() as! NSImage
        copy.isTemplate = false
        copy.lockFocus()
        nsColor.set()
        let rect = NSRect(origin: .zero, size: copy.size)
        rect.fill(using: .sourceAtop)
        copy.unlockFocus()
        return copy
    }
}
