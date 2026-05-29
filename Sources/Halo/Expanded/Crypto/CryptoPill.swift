import SwiftUI

struct CryptoPill: View {
    let ticker: LiveActivityCoordinator.CryptoTicker
    let fiat: String

    private var changeColor: Color {
        if ticker.change24h > 0 {
            return Color(red: 0.30,
                         green: 0.83, blue: 0.50)
        }
        if ticker.change24h < 0 {
            return Color(red: 1.00,
                         green: 0.38, blue: 0.35)
        }
        return .haloSecondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Top row — logo + ticker on the left, change
            // percent on the right. The two anchor the pill
            // visually; price + sparkline fill in below.
            HStack(spacing: 5) {
                logo
                    .frame(width: 16, height: 16)
                Text(ticker.symbol)
                    .font(.system(size: 12,
                                  weight: .bold,
                                  design: .rounded))
                    .foregroundStyle(ticker.brandColor)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: ticker.change24h >= 0
                      ? "arrow.up" : "arrow.down")
                    .font(.system(size: 7,
                                  weight: .heavy))
                    .foregroundStyle(changeColor)
                Text(String(format: "%.2f%%",
                            abs(ticker.change24h)))
                    .font(.system(size: 9,
                                  weight: .semibold,
                                  design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(changeColor)
                    .contentTransition(.numericText())
            }
            Text(priceLabel)
                .font(.system(size: 11,
                              weight: .semibold,
                              design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
                .animation(.linear(duration: 0.3),
                           value: ticker.price)
            // Sparkline anchored at the bottom edge of the
            // pill so the trend reads as a chart "shelf"
            // under the data.
            if !ticker.sparkline.isEmpty {
                Sparkline(points: ticker.sparkline,
                          tint: changeColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: 10)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8,
                             style: .continuous)
                .fill(Color.haloSurfaceFaint))
    }

    @ViewBuilder
    private var logo: some View {
        if let img = CryptoTrackerExtension.cachedLogo(
            url: ticker.imageURL) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .clipShape(Circle())
        } else {
            ZStack {
                Circle()
                    .fill(Color.haloSurfaceSoft)
                Text(String(ticker.symbol.prefix(1)))
                    .font(.system(size: 8,
                                  weight: .bold,
                                  design: .rounded))
                    .foregroundStyle(.haloSecondary)
            }
        }
    }

    private var priceLabel: String {
        let symbol = fiatSymbol(for: fiat)
        let p = ticker.price
        if p >= 1000 {
            // `String(format:)` printf doesn't actually
            // honour `%,.0f` for grouping — it's a printf
            // extension on some platforms (Linux) but not
            // on Apple's libc. Use Swift's locale-aware
            // `Int.formatted()` so 42500 renders as
            // "$42,500" instead of the format-string
            // garbage `$,.0f` we were emitting before.
            return symbol + Int(p).formatted()
        }
        if p >= 1 {
            return String(format: "%@%.2f", symbol, p)
        }
        if p >= 0.01 {
            return String(format: "%@%.4f", symbol, p)
        }
        return String(format: "%@%.6f", symbol, p)
    }

    private func fiatSymbol(for code: String) -> String {
        switch code.lowercased() {
        case "usd": return "$"
        case "eur": return "€"
        case "gbp": return "£"
        case "jpy": return "¥"
        case "btc": return "₿"
        default:    return ""
        }
    }
}

/// (Older single-column row view, kept private in case we
/// reintroduce a "list mode" toggle later. Not used by the
/// current grid-only layout.)
