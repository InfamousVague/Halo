import SwiftUI

struct Sparkline: View {
    let points: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            // Render only if we have enough data to draw a
            // line — a single point would crash addLine.
            if points.count >= 2,
               let lo = points.min(),
               let hi = points.max(),
               hi > lo {
                Path { p in
                    let step = w / CGFloat(points.count - 1)
                    let range = hi - lo
                    for (i, v) in points.enumerated() {
                        let x = CGFloat(i) * step
                        // Normalise to [0, 1] then flip
                        // (SwiftUI's y grows downward, we
                        // want higher prices to render
                        // higher on screen).
                        let n = (v - lo) / range
                        let y = h - CGFloat(n) * h
                        if i == 0 {
                            p.move(to: CGPoint(x: x, y: y))
                        } else {
                            p.addLine(
                                to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(tint,
                        style: StrokeStyle(
                            lineWidth: 1,
                            lineCap: .round,
                            lineJoin: .round))
            } else {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h / 2))
                    p.addLine(to: CGPoint(x: w, y: h / 2))
                }
                .stroke(Color.haloTertiary,
                        style: StrokeStyle(
                            lineWidth: 1, lineCap: .round))
            }
        }
    }
}

