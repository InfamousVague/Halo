import SwiftUI

// MARK: - Crypto (extension)

/// Leaderboard of tracked coins. Three sort tabs across the
/// top — Market Cap (default), 24h Change, Top Movers (sort
/// by absolute 24h % so a -8% sell-off and a +8% rally both
/// surface) — and a scrollable list of rows underneath with
/// the coin symbol, name, price, and a colour-coded 24h
/// change. The publisher polls CoinGecko every 20s; the
/// footer shows the last update time so the user knows how
struct CryptoExpandedView: View {
    let activity: LiveActivityCoordinator.Resolved

    // Default the dropdown to 1h movers — the user opens
    // the card to see what's moving NOW, not yesterday.
    // Market Cap + 24h tabs are one click away.
    @State private var sort: SortMode = .topMovers1h

    private enum SortMode: String, CaseIterable, Identifiable {
        case marketCap   = "Market Cap"
        case topMovers1h = "1h Movers"
        case topMovers   = "24h Movers"
        var id: String { rawValue }
    }

    private var info: LiveActivityCoordinator.CryptoInfo? {
        activity.crypto
    }

    private var sortedTickers:
        [LiveActivityCoordinator.CryptoTicker]
    {
        guard let info else { return [] }
        switch sort {
        case .marketCap:
            return info.tickers.sorted {
                ($0.marketCap ?? 0) > ($1.marketCap ?? 0)
            }
        case .topMovers1h:
            return info.tickers.sorted {
                abs($0.change1h) > abs($1.change1h)
            }
        case .topMovers:
            return info.tickers.sorted {
                abs($0.change24h) > abs($1.change24h)
            }
        }
    }

    private var brand: Color {
        NotchView.pillTextColor(for: activity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header removed — the "Crypto Tracker" title +
            // "Top 9 of N" chip were taking up vertical
            // space without giving the user something to
            // glance at. Sort tabs sit at the top of the
            // card now; the LIVE badge on the 24h tab is
            // where the realtime signal lives.
            sortStrip
            // Eager grid — `LazyVGrid` defers cell mounting
            // until each one enters the visible bounds,
            // which means the pills don't participate in
            // the parent's slide-in transition (they pop in
            // AFTER the sort strip + footer have already
            // animated into place). Nested VStack+HStack
            // mounts every cell up front so all 9 pills
            // slide down with the rest of the sheet.
            pillGrid
            updatedFooter
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 3×3 grid built as a VStack of HStacks so every cell
    /// is mounted eagerly. `.frame(maxWidth: .infinity)` on
    /// each cell evenly distributes column widths — same
    /// visual result as `LazyVGrid` with three flexible
    /// columns, just with eager mounting.
    private var pillGrid: some View {
        let visible = Array(sortedTickers.prefix(9))
        return VStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { col in
                        let idx = row * 3 + col
                        if idx < visible.count {
                            CryptoPill(
                                ticker: visible[idx],
                                fiat: info?.fiat ?? "usd")
                                .frame(maxWidth: .infinity)
                        } else {
                            // Placeholder to keep the row's
                            // column widths even when we
                            // have fewer than 9 tickers
                            // (the first refresh has only
                            // arrived for some coins).
                            Color.clear
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    /// Three pill-shaped sort tabs. Tap to re-sort the
    /// leaderboard client-side — no refetch needed, the
    /// payload carries every ticker.
    private var sortStrip: some View {
        HStack(spacing: 6) {
            ForEach(SortMode.allCases) { mode in
                Button {
                    sort = mode
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 10,
                                      weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(sort == mode
                            ? AnyShapeStyle(Color.white)
                            : AnyShapeStyle(
                                Color.haloSecondary))
                        .background(
                            Capsule()
                                .fill(sort == mode
                                      ? brand.opacity(0.25)
                                      : Color
                                        .haloSurfaceFaint))
                        .overlay(
                            Capsule()
                                .stroke(sort == mode
                                        ? brand.opacity(0.5)
                                        : .clear,
                                        lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            // 24h sort is driven by Binance's realtime
            // ticker stream (1s push); 1h + Market Cap
            // update on the 90s REST cadence. Tag the
            // realtime path so the user knows when the
            // grid is genuinely live.
            if sort == .topMovers {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color(red: 0.30,
                                    green: 0.83,
                                    blue: 0.50))
                        .frame(width: 6, height: 6)
                    Text("LIVE")
                        .font(.system(size: 9,
                                      weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(
                        Color.white.opacity(0.08)))
            }
        }
    }

    /// Minimal top section — title on the left wing,
    /// "Top N movers of M" chip on the right. No bitcoin
    /// logo, no EXTENSION eyebrow; the grid below carries
    /// the visual weight. Mirrors the compact pill's
    /// left-symbol + right-data split, just at expanded
    /// scale.
    // (headerRow removed — sort tabs sit at the top now.)

    private var updatedFooter: some View {
        HStack(spacing: 4) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 8))
            Text(updatedLabel)
                .font(.system(size: 9))
            Spacer(minLength: 0)
            Text("via CoinGecko")
                .font(.system(size: 9))
        }
        .foregroundStyle(.haloTertiary)
        .padding(.horizontal, 4)
    }

    private var updatedLabel: String {
        guard let last = info?.lastUpdated,
              last != .distantPast
        else { return "fetching…" }
        let delta = Date().timeIntervalSince(last)
        if delta < 5 { return "live" }
        if delta < 60 {
            return "updated \(Int(delta))s ago"
        }
        let mins = Int(delta / 60)
        return "updated \(mins)m ago"
    }
}

/// One grid-cell pill in the crypto leaderboard. Compact
/// 4-up layout — logo + ticker symbol on top, price below,
/// 24h change at the bottom with a green-up / red-down
/// arrow. Brand-coloured symbol text and a mini sparkline
/// underneath the price so each pill reads as its own
/// little card.
