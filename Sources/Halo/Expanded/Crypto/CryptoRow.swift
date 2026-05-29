import SwiftUI

struct CryptoRow: View {
    let ticker: LiveActivityCoordinator.CryptoTicker
    let fiat: String

    var body: some View {
        HStack(spacing: 10) {
            coinLogo
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                // Symbol painted in the asset's brand colour
                // — Bitcoin orange, Ethereum purple-blue,
                // Solana mint, etc. — so the eye links the
                // logo and the text as one identity. Falls
                // back to white when we don't have a known
                // brand colour for the coin.
                Text(ticker.symbol)
                    .font(.system(size: 13,
                                  weight: .bold,
                                  design: .rounded))
                    .foregroundStyle(ticker.brandColor)
                Text(ticker.name)
                    .font(.system(size: 10))
                    .foregroundStyle(.haloSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            // Mini 7-day chart between the name + the
            // price/change column. Tinted by overall
            // direction (green up, red down) so even before
            // the user reads the percent change, the
            // chart's colour matches the trend.
            if !ticker.sparkline.isEmpty {
                Sparkline(points: ticker.sparkline,
                          tint: changeColor)
                    .frame(width: 60, height: 10)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(priceLabel)
                    .font(.system(size: 12,
                                  weight: .semibold,
                                  design: .monospaced))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .animation(
                        .linear(duration: 0.3),
                        value: ticker.price)
                // Change rendered as an HStack so the arrow
                // SF Symbol can sit alongside the percent
                // without the unicode-triangle font hinting
                // making it look misaligned at small sizes.
                HStack(spacing: 2) {
                    Image(systemName:
                        ticker.change24h >= 0
                            ? "arrow.up"
                            : "arrow.down")
                        .font(.system(size: 8,
                                      weight: .heavy))
                    Text(String(
                        format: "%.2f%%",
                        abs(ticker.change24h)))
                        .font(.system(size: 11,
                                      weight: .semibold,
                                      design: .rounded))
                        .contentTransition(.numericText())
                }
                .foregroundStyle(changeColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6,
                             style: .continuous)
                .fill(Color.haloSurfaceFaint))
    }

    // (Brand colour now lives on `CryptoTicker.brandColor`
    // so both the compact-pill wing and this row read from
    // the same lookup table.)

    /// Per-coin logo from the publisher's cache, or a tinted
    /// SF Symbol fallback while the fetch is in flight. The
    /// async logo arrival re-renders the parent on the next
    /// publish tick, so the placeholder lifetime is ≤ one
    /// publisher poll.
    @ViewBuilder
    private var coinLogo: some View {
        if let img = CryptoTrackerExtension.cachedLogo(
            url: ticker.imageURL) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .clipShape(Circle())
        } else {
            ZStack {
                Circle()
                    .fill(Color.haloSurfaceFaint)
                Text(String(ticker.symbol.prefix(1)))
                    .font(.system(size: 9,
                                  weight: .bold,
                                  design: .rounded))
                    .foregroundStyle(.haloSecondary)
            }
        }
    }

    /// `$42,500.00` for high-value coins, `$0.0823` for
    /// fractional ones — keep meaningful precision both
    /// directions without trailing zeros on big numbers.
    private var priceLabel: String {
        let symbol = fiatSymbol(for: fiat)
        let p = ticker.price
        if p >= 1000 {
            return String(format: "%@%,.0f", symbol, p)
        }
        if p >= 1 {
            return String(format: "%@%.2f", symbol, p)
        }
        // Sub-dollar coins: show enough decimals to read
        // the value (DOGE at $0.0823, SHIB at $0.0000234).
        if p >= 0.01 {
            return String(format: "%@%.4f", symbol, p)
        }
        return String(format: "%@%.6f", symbol, p)
    }

    private var changeLabel: String {
        let arrow = ticker.change24h >= 0 ? "▲" : "▼"
        return String(format: "%@ %.2f%%",
                      arrow, abs(ticker.change24h))
    }

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

/// Mini line chart for the leaderboard rows. Plots N price
/// points across the view's width, normalised so the chart
/// fills the full vertical range regardless of absolute
/// price (a $0.05 coin looks the same shape as a $40,000
/// one). Tinted by the row's 24h change colour — green for
/// up, red for down — so the chart's hue and direction
/// agree at a glance.
///
/// Renders as a stroked Path with `.round` caps so the line
/// keeps its weight at the endpoints. The shape conforms
/// to `Animatable` via SwiftUI's default — animation between
/// consecutive 168-point arrays is fine on every tick.
///
/// Non-private so NotchView can also render a smaller
/// variant inside the compact pill's trailing wing — same
/// drawing code, smaller frame.
