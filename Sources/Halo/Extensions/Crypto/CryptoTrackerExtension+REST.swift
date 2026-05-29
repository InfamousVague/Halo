import AppKit
import Foundation

/// REST polling against CoinGecko's `/coins/markets`. Walks four
/// pages of 250 coins each to cover the top 1,000, dedupes /
/// filters stablecoins, then publishes the merged list. WebSocket
/// subscriptions live in `CryptoTrackerExtension+WebSocket`.
extension CryptoTrackerExtension {
    // MARK: - REST

    func refresh() async {
        // Sequentially walk the 4 pages — each returns up
        // to `perPage` coins. CoinGecko's /coins/markets is
        // ordered by market cap across pages, so the
        // concatenated result preserves rank order.
        // Sequential rather than parallel because (a)
        // CoinGecko throttles concurrent calls more
        // aggressively than spaced ones and (b) the actor
        // boundary makes parallel fetch awkward without
        // duplicating state.
        let pages = Int((Double(fetchCount)
                         / Double(perPage)).rounded(.up))
        var allMarkets: [CoinGeckoMarket] = []
        for page in 1...pages {
            let pageData = await fetchPage(page)
            if pageData.isEmpty { continue }
            allMarkets.append(contentsOf: pageData)
        }
        guard !allMarkets.isEmpty else { return }

        // Drop stablecoins — they cluster at the top of the
        // market-cap list but don't move, which buries
        // actual coins under a wall of $1.00 rows.
        let filtered = allMarkets.filter { m in
            !stablecoinSymbols.contains(
                m.symbol.uppercased())
        }
        latest = filtered.map { m in
            if let img = m.image, !img.isEmpty {
                Self.warmLogoCache(url: img)
            }
            return LiveActivityCoordinator.CryptoTicker(
                id: m.id,
                symbol: m.symbol.uppercased(),
                name: m.name,
                price: m.current_price ?? 0,
                change1h:
                    m.price_change_percentage_1h_in_currency
                        ?? 0,
                change24h:
                    m.price_change_percentage_24h
                        ?? m.price_change_percentage_24h_in_currency
                        ?? 0,
                marketCap: m.market_cap,
                rank: m.market_cap_rank,
                imageURL: m.image,
                sparkline:
                    m.sparkline_in_7d?.price ?? [])
        }
        lastUpdated = Date()
        if cycleIndex >= cycleableCount {
            cycleIndex = 0
        }
        publishCurrent()
        CryptoDebugLog.append("REST refresh complete: " +
                              "\(latest.count) coins " +
                              "(filtered from " +
                              "\(allMarkets.count))")
        // Re-subscribe the WebSocket if the top-50 symbol
        // set drifted significantly (new coin entered the
        // top, an old one fell out). Keeps the realtime
        // feed pointed at coins we actually care about.
        reconcileWebSocketSubscriptions()
    }

    /// Single CoinGecko page fetch — returns an empty array
    /// on any failure so the outer loop can collect the
    /// rest without crashing the whole refresh.
    func fetchPage(
        _ page: Int
    ) async -> [CoinGeckoMarket] {
        let urlStr = "https://api.coingecko.com/api/v3/coins" +
            "/markets?vs_currency=\(fiat)" +
            "&order=market_cap_desc" +
            "&per_page=\(perPage)&page=\(page)" +
            "&sparkline=true" +
            "&price_change_percentage=1h,24h"
        guard let url = URL(string: urlStr) else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0",
                         forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared
                .data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200
            else { return [] }
            return try JSONDecoder().decode(
                [CoinGeckoMarket].self, from: data)
        } catch {
            CryptoDebugLog.append("[halo.crypto] page \(page) failed: " +
                  "\(error)")
            return []
        }
    }

    /// How many of `latest`'s entries the compact pill
    /// cycles through — capped at `cycleCount` (currently
    /// 6) so the rotation completes in a reasonable window.
    var cycleableCount: Int {
        min(cycleCount, latest.count)
    }
}

// MARK: - CoinGecko response shape

/// Subset of CoinGecko's `/coins/markets` response we decode.
/// Field names match the API exactly (snake_case) and all
/// numeric fields are optional because the endpoint will
/// occasionally omit them for low-volume coins.
struct CoinGeckoMarket: Decodable {
    let id: String
    let symbol: String
    let name: String
    let image: String?
    let current_price: Double?
    let market_cap: Double?
    let market_cap_rank: Int?
    let price_change_percentage_24h: Double?
    /// CoinGecko's `price_change_percentage=1h,24h` query
    /// adds these `_in_currency` variants. The 1h field
    /// only ever comes back via this path; the 24h
    /// variant is identical to the bare field above and is
    /// kept here as a defensive fallback.
    let price_change_percentage_1h_in_currency: Double?
    let price_change_percentage_24h_in_currency: Double?
    let sparkline_in_7d: Sparkline?

    struct Sparkline: Decodable {
        let price: [Double]
    }
}
