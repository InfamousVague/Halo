import SwiftUI

// MARK: - Marquee text

/// Single-line text that ping-pongs horizontally if its drawn
/// width exceeds `maxWidth` — radio-style ticker. Pauses
/// briefly at each end before reversing so the user can
/// actually read the full label. Falls back to a static frame
/// at the text's natural width if it already fits.
struct MarqueeText: View {
    let text: String
    let font: Font
    let fontSize: CGFloat
    let color: Color
    let maxWidth: CGFloat
    /// Marquee scroll speed in points per second.
    let speed: Double = 30
    /// Pause at each end of the scroll, in seconds.
    let endPause: Double = 1.5

    var body: some View {
        let measured = Geometry.measureText(text, size: fontSize)
        let overflow = max(0, measured - maxWidth)
        // Always render at full `maxWidth` so the parent's
        // geometry doesn't shift when the text content changes.
        // Short labels pad inside the slot (alignment: .leading);
        // long labels scroll inside the same slot.
        Group {
            if overflow > 0 {
                TimelineView(.animation) { context in
                    label
                        .offset(x: -offset(
                            at: context.date,
                            overflow: overflow))
                        .frame(width: maxWidth,
                               alignment: .leading)
                        .clipped()
                }
            } else {
                label
                    .frame(width: maxWidth,
                           alignment: .leading)
            }
        }
        // Restart the marquee when the text content changes
        // (skip to next track) so we don't carry over a
        // half-scrolled offset.
        .id(text)
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }

    /// Where in the ping-pong cycle we are right now, expressed
    /// as a horizontal offset to apply to the text. Cycle:
    /// pause at start → scroll left → pause at end → scroll
    /// back to start → repeat.
    private func offset(
        at date: Date, overflow: CGFloat
    ) -> CGFloat {
        let scrollDur = Double(overflow) / speed
        let cycle = (endPause + scrollDur) * 2
        let t = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycle)
        if t < endPause {
            return 0
        } else if t < endPause + scrollDur {
            let p = (t - endPause) / scrollDur
            return CGFloat(p) * overflow
        } else if t < endPause * 2 + scrollDur {
            return overflow
        } else {
            let p = (t - endPause * 2 - scrollDur) / scrollDur
            return overflow * CGFloat(1 - p)
        }
    }
}

