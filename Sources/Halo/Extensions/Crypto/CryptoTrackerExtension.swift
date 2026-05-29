import AppKit

/// Crypto tracker — Halo's first extension. Polls CoinGecko's
/// public `/coins/markets` REST endpoint for a configurable
/// list of coins, surfaces a cycling pill in the island
/// rotation, and feeds a sortable leaderboard into the
/// expanded card.
///
/// ## Why polling, not WebSockets
/// CoinGecko's public API is REST-only — there's no WebSocket
/// endpoint, even on the paid Pro tier. We poll the markets
/// endpoint every `pollInterval` seconds (default 20s) which
/// sits comfortably inside the free tier's "10-50 calls per
/// minute" envelope while giving the user near-real-time
/// updates. For true streaming we'd subscribe to a real
/// exchange's WebSocket (Coinbase Advanced, Binance, Kraken)
/// and reconcile coin metadata from CoinGecko on a slower
/// cadence; that's a future enhancement.
///
/// ## Pill behaviour
/// The compact pill cycles through tracked coins every
/// `compactCycleInterval` seconds (default 6s) so the user
/// glances and sees a rotating ticker: BTC → ETH → SOL → …
/// The leading icon is the coin's SF Symbol when one exists,
/// the trailing text is the ticker + 24h percent change with
/// a directional arrow. The expanded card shows everything.
///
/// ## Priority
/// 35 — ambient, below Now Playing (60) and transient HUDs
/// (90). Sits alongside Stats / Battery in the rotation.
@MainActor
final class CryptoTrackerExtension: HaloPublisher {
    let id = "halo.ext.crypto"

    private weak var coordinator: LiveActivityCoordinator?

    /// How many coins from the top-by-market-cap universe
    /// to fetch on each poll. CoinGecko's `/coins/markets`
    /// caps `per_page` at 250, so 1,000 means 4 paginated
    /// calls per refresh. Wider universe means Top Movers
    /// surfaces actual ten-baggers from low-cap coins, not
    /// just whatever the top 100 is doing.
    let fetchCount: Int = 1000

    /// Page size CoinGecko allows. We chunk `fetchCount`
    /// into batches of this size and fan the requests out
    /// concurrently — 4 calls in parallel for 1000 coins.
    let perPage: Int = 250

    /// How many coins the compact pill rotates through. We
    /// fetch the wider universe for the dropdown but only
    /// cycle the top N on the compact pill — otherwise a
    /// full rotation would take 1000 × 6s = 100 minutes.
    /// Cycles through the highest market caps, where the
    /// user's eye is already trained.
    let cycleCount: Int = 6

    /// REST poll cadence. With 1000 coins coming back across
    /// 4 paginated calls, 90s = ~2.7 calls/minute averaged —
    /// comfortably under CoinGecko's free-tier 5-15
    /// calls/minute envelope. Crypto prices don't move
    /// enough in 90 seconds for the pacing to feel slow.
    let pollInterval: TimeInterval = 90

    /// How often the compact pill rotates between tracked
    /// coins. 6s is long enough to read the ticker + change,
    /// short enough to feel live.
    let compactCycleInterval: TimeInterval = 6

    var pollTimer: Timer?
    var cycleTimer: Timer?

    /// Latest fetched tickers, ordered as `trackedIDs` was
    /// (CoinGecko returns them in the same order we
    /// requested). Empty until the first refresh completes.
    var latest: [LiveActivityCoordinator.CryptoTicker] = []
    var lastUpdated: Date = .distantPast
    var cycleIndex: Int = 0
    let fiat: String = "usd"

    /// Stablecoin / pegged-asset symbols filtered out of
    /// the leaderboard. They cluster at the top of the
    /// market-cap list but don't move — including them
    /// buries actual coins under a wall of "$1.00 ▲ 0.01%"
    /// rows. Now also covers tokenized treasuries (BUIDL)
    /// and the newer fiat-pegged stables CoinGecko
    /// surfaces.
    let stablecoinSymbols: Set<String> = [
        "USDT", "USDC", "DAI", "BUSD", "TUSD",
        "FRAX", "FDUSD", "USDE", "USDP", "GUSD",
        "LUSD", "PYUSD", "USDD", "USDS", "RLUSD",
        "USTC", "EURT", "EURC", "JPYC", "AEUR",
        "USD1", "USDG", "USDY", "USYC", "USDF",
        "BUIDL", "EUSD", "PAXG", "XAUT",
    ]

    /// Known-good Binance USDT-quoted symbols. A combined-
    /// stream subscription is all-or-nothing: ONE invalid
    /// symbol makes Binance reject the entire handshake
    /// with HTTP 400. CoinGecko's top-50 by market cap
    /// often includes exchange-only or DeFi tokens that
    /// aren't listed on Binance (or whose ticker collides
    /// with something Binance lists under a different
    /// symbol), so we explicitly subscribe to this curated
    /// list of major coins we KNOW Binance trades against
    /// USDT. Realtime updates flow for these; everything
    /// else still updates on the 90s REST cadence.
    let knownBinanceUSDTSymbols: Set<String> = [
        "BTC", "ETH", "SOL", "BNB", "XRP", "DOGE",
        "ADA", "TRX", "AVAX", "LINK", "DOT", "SHIB",
        "MATIC", "LTC", "BCH", "XMR", "UNI", "ATOM",
        "ETC", "FIL", "ARB", "NEAR", "APT", "ALGO",
        "ICP", "INJ", "RNDR", "PEPE", "HBAR", "STX",
        "AAVE", "MKR", "TIA", "GRT", "JASMY", "FTM",
        "WIF", "SUI", "ONDO", "TON", "FET", "FLOW",
        "QNT", "PYTH", "RUNE", "ENS", "OP", "GALA",
        "SAND", "MANA", "AXS", "CHZ", "EGLD", "XLM",
        "XTZ", "NEO", "ZEC", "DASH", "BAT", "BNT",
        "FLOKI", "BONK", "JTO", "SEI", "TAO", "VET",
    ]

    /// Binance WebSocket for realtime price + 24h percent
    /// updates. CoinGecko has no public WebSocket; Binance
    /// pushes `<symbol>@ticker` events every 1s for as
    /// many subscriptions as fit in a combined stream.
    var webSocket: URLSessionWebSocketTask?
    var wsBackoffSeconds: Double = 1
    var wsSubscribedSymbols: Set<String> = []
    /// Set true on the first successfully-decoded WS event
    /// per connection — used purely so we log "first
    /// message" exactly once, helping confirm the pipe is
    /// alive without spamming on every tick.
    var wsFirstMessageLogged = false
    /// Wall-clock for the last republish driven by a WS
    /// event. Used by `wsPublishThrottle` below.
    var lastWSPublishAt: Date = .distantPast
    /// Throttle floor for republishes driven by WebSocket
    /// updates. 150ms = ~6.7 publishes/sec — fast enough
    /// that price ticks feel genuinely realtime, slow
    /// enough that the SwiftUI diff path through the
    /// 1000-entry ticker array doesn't burn CPU on changes
    /// the user can't perceive anyway.
    let wsPublishThrottle: TimeInterval = 0.15

    init(coordinator: LiveActivityCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        // Kick off first fetch immediately; subsequent ticks
        // come from the timer. Fire-and-forget — the timer
        // will retry if this initial one fails.
        Task { @MainActor in
            await self.refresh()
            self.connectWebSocketIfNeeded()
        }
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: pollInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        cycleTimer = Timer.scheduledTimer(
            withTimeInterval: compactCycleInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.advanceCycle() }
        }
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        cycleTimer?.invalidate(); cycleTimer = nil
        disconnectWebSocket()
        coordinator?.clear(id: id)
    }

    // MARK: - Cycle

    private func advanceCycle() {
        let count = cycleableCount
        guard count > 0 else { return }
        cycleIndex = (cycleIndex + 1) % count
        publishCurrent()
    }

}

// MARK: - Publish

extension CryptoTrackerExtension {
    // MARK: - Publish

    func publishCurrent() {
        guard !latest.isEmpty else {
            coordinator?.clear(id: id)
            return
        }
        // Compact pill cycles through only the top
        // `cycleCount` by market cap — the dropdown still
        // sees the full universe so Top Movers works
        // across the wider list.
        let cycleSafeIndex = min(
            cycleIndex, cycleableCount - 1)
        let coin = latest[cycleSafeIndex]
        let arrow = coin.change24h >= 0 ? "↑" : "↓"
        let absChange = abs(coin.change24h)
        // Trailing label: "BTC ↑ 2.51%". Symbol prefix keeps
        // it clear which coin the change refers to as the
        // pill cycles; the arrow gives direction at a glance
        // even before the user processes the percent value.
        let label = String(
            format: "%@ %@ %.2f%%",
            coin.symbol, arrow, absChange)
        // Prefer the cached CoinGecko logo for the leading
        // icon — proper coin branding (the BTC orange, the
        // ETH black diamond, etc.). Fall back to the SF
        // Symbol on cache miss so the first tick before the
        // logo fetch completes still renders something.
        let leading: NSImage? =
            Self.cachedLogo(url: coin.imageURL)
                ?? LiveActivityCoordinator.symbolImage(
                    symbolForCoin(coin.symbol))
        let info = LiveActivityCoordinator.CryptoInfo(
            tickers: latest,
            currentIndex: cycleIndex,
            lastUpdated: lastUpdated,
            fiat: fiat)
        let payload = LiveActivityCoordinator.Resolved(
            id: id,
            compactLeadingImage: leading,
            compactTrailingText: label,
            compactTrailingImage: nil,
            tint: .white,
            // Bumped from 35 → 45 so the crypto pill
            // surfaces in the rotation more reliably —
            // matches AirPods / Bluetooth Audio so it
            // doesn't get buried under a Stats or Battery
            // publisher.
            priority: 45,
            crypto: info)
        coordinator?.inject(payload)
    }

    /// SF Symbol that doubles as the coin's glyph in the
    /// compact pill. macOS ships symbols for the major
    /// currencies; everything else falls back to a generic
    /// circle so the pill still has a leading mark.
    private func symbolForCoin(_ symbol: String) -> String {
        switch symbol.uppercased() {
        case "BTC": return "bitcoinsign.circle.fill"
        case "ETH": return "centsign.circle.fill"
            // SF Symbols doesn't ship an ETH glyph; the cent
            // sign is a passable monogram. Future: bundle a
            // proper Ξ asset.
        case "DOGE": return "pawprint.circle.fill"
        case "USDT", "USDC", "DAI":
            return "dollarsign.circle.fill"
        default: return "circle.grid.cross.fill"
        }
    }
}
