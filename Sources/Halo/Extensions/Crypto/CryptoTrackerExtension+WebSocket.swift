import AppKit
import Foundation

/// Realtime price + 24h-change updates from Binance.us combined
/// streams. CoinGecko has no public WebSocket; Binance gives us
/// 24hrTicker events for the top-50 we subscribe to. REST is the
/// floor (90s cadence); this is the live overlay (~6.7Hz throttle).
extension CryptoTrackerExtension {
    // MARK: - WebSocket (Binance realtime)

    /// How many of the top tickers we subscribe to on
    /// Binance. 50 covers the compact pill's cycle (top 6)
    /// plus a wide enough buffer that "Top 9 movers" usually
    /// finds its picks among subscribed coins. Coins outside
    /// the 50 still update at the 90s REST cadence.
    private var wsTopN: Int { 50 }

    /// Build the set of Binance stream-name subscriptions.
    /// Subscribes to EVERY known-good Binance USDT pair
    /// that's present in `latest` — not just the top-N by
    /// market cap. Top Movers often surface low-cap coins
    /// that wouldn't make a market-cap-top-50 cut, so
    /// pointing the realtime feed at the full known list
    /// gives the leaderboard live data across a much wider
    /// pool. The `@ticker` suffix is Binance's stream type
    /// for 24hr ticker updates.
    private var desiredWSSymbols: Set<String> {
        let latestSymbols = Set(latest.map {
            $0.symbol.uppercased()
        })
        let active = knownBinanceUSDTSymbols
            .intersection(latestSymbols)
        return Set(active.map {
            $0.lowercased() + "usdt@ticker"
        })
    }

    func connectWebSocketIfNeeded() {
        guard webSocket == nil else { return }
        let symbols = desiredWSSymbols
        guard !symbols.isEmpty else {
            CryptoDebugLog.append("ws: no symbols yet")
            return
        }
        // Use the dynamic-subscribe endpoint `/ws` instead
        // of `/stream?streams=…`. Combined-stream URLs were
        // failing handshake with HTTP 400 (likely Binance
        // rejecting one of the symbols and killing the
        // whole connection); /ws lets us SUBSCRIBE after
        // the socket is open and ignore individual symbol
        // failures.
        guard let url = URL(string:
            "wss://stream.binance.us:9443/ws")
        else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        webSocket = task
        wsSubscribedSymbols = symbols
        wsFirstMessageLogged = false
        task.resume()
        CryptoDebugLog.append("ws → /ws connect, " +
                              "\(symbols.count) syms")
        // Send the SUBSCRIBE message right after `resume()`.
        // Binance accepts it as soon as the socket is open;
        // the server queues anything that arrives before
        // upgrade completes.
        let subscribe: [String: Any] = [
            "method": "SUBSCRIBE",
            "params": Array(symbols),
            "id": 1,
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: subscribe),
           let str = String(data: data, encoding: .utf8) {
            task.send(.string(str)) { error in
                if let error {
                    CryptoDebugLog.append(
                        "ws subscribe send err: \(error)")
                }
            }
        }
        Task { @MainActor in
            await self.runReceiveLoop(task)
        }
    }

    private func runReceiveLoop(
        _ task: URLSessionWebSocketTask
    ) async {
        while !Task.isCancelled, webSocket === task {
            do {
                let message = try await task.receive()
                handleWSMessage(message)
                if !wsFirstMessageLogged {
                    wsFirstMessageLogged = true
                    CryptoDebugLog.append("[halo.crypto] ws first " +
                          "message received ✓")
                }
                wsBackoffSeconds = 1
            } catch {
                CryptoDebugLog.append("[halo.crypto] ws err: \(error)")
                await scheduleWSReconnect()
                return
            }
        }
    }

    func disconnectWebSocket() {
        webSocket?.cancel(with: .goingAway,
                          reason: nil)
        webSocket = nil
        wsSubscribedSymbols = []
    }

    /// If `latest`'s top 50 has drifted enough that more
    /// than ~20% of subscriptions are now stale, reconnect
    /// with the fresh set. Cheaper than reconnecting on
    /// every refresh; still keeps the feed pointed at
    /// useful coins as the market shifts.
    func reconcileWebSocketSubscriptions() {
        let desired = desiredWSSymbols
        if wsSubscribedSymbols.isEmpty {
            connectWebSocketIfNeeded()
            return
        }
        let stale = wsSubscribedSymbols
            .subtracting(desired).count
        let threshold = wsSubscribedSymbols.count / 5
        guard stale > threshold else { return }
        CryptoDebugLog.append("[halo.crypto] ws resubscribing: " +
              "\(stale) stale > \(threshold)")
        disconnectWebSocket()
        connectWebSocketIfNeeded()
    }

    /// Exponential backoff up to 30s so a flapping network
    /// doesn't slam the Binance endpoint.
    private func scheduleWSReconnect() async {
        webSocket = nil
        let delay = min(30, wsBackoffSeconds)
        wsBackoffSeconds = min(30, wsBackoffSeconds * 2)
        let nanos = UInt64(delay * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
        connectWebSocketIfNeeded()
    }

    private func handleWSMessage(
        _ message: URLSessionWebSocketTask.Message
    ) {
        let data: Data
        switch message {
        case .data(let d): data = d
        case .string(let s):
            data = s.data(using: .utf8) ?? Data()
        @unknown default: return
        }
        // `/ws` endpoint sends raw ticker payloads with no
        // wrapping envelope. SUBSCRIBE confirmations come
        // back as `{ "result": null, "id": 1 }` — skipping
        // anything missing `s` lets us cheaply ignore
        // control messages.
        guard let upd = try? JSONDecoder().decode(
            BinanceTicker.self, from: data)
        else {
            if !wsFirstMessageLogged,
               let s = String(data: data, encoding: .utf8) {
                CryptoDebugLog.append(
                    "ws non-ticker: \(s.prefix(120))")
            }
            return
        }
        let symbol = String(upd.s.dropLast(4))  // strip USDT
        guard let idx = latest.firstIndex(
            where: { $0.symbol == symbol })
        else { return }
        guard let newPrice = Double(upd.c),
              let newChange = Double(upd.P)
        else { return }
        let prev = latest[idx]
        // Skip identical updates — the stream sends 1Hz
        // events even when no trade happened, no point
        // churning the UI for those.
        guard newPrice != prev.price
            || newChange != prev.change24h
        else { return }
        latest[idx] = .init(
            id: prev.id,
            symbol: prev.symbol,
            name: prev.name,
            price: newPrice,
            change1h: prev.change1h,  // WS doesn't carry 1h
            change24h: newChange,
            marketCap: prev.marketCap,
            rank: prev.rank,
            imageURL: prev.imageURL,
            sparkline: prev.sparkline)
        // Throttled republish — ensures the leaderboard AND
        // the compact pill see WS updates without flooding
        // the coordinator with 50 events/sec across all
        // subscribed symbols.
        let now = Date()
        guard now.timeIntervalSince(lastWSPublishAt)
                >= wsPublishThrottle
        else { return }
        lastWSPublishAt = now
        publishCurrent()
    }
}

// MARK: - Binance WebSocket shape

/// Combined-stream envelope. Binance wraps each per-symbol
/// ticker payload in `{ "stream": "<sub>", "data": {...} }`
/// when you connect via `/stream?streams=...`. The inner
/// `data` is the full 24hr ticker event.
private struct BinanceTickerEnvelope: Decodable {
    let stream: String
    let data: BinanceTicker
}

/// Subset of Binance's 24hr ticker payload we use. All
/// numeric fields come down as strings — Binance is strict
/// about not losing precision on JSON parsing — so we
/// `Double(s)` them ourselves.
private struct BinanceTicker: Decodable {
    let s: String   // symbol, e.g. "BTCUSDT"
    let c: String   // close (last) price
    let P: String   // 24h price change percent

    enum CodingKeys: String, CodingKey {
        case s, c
        case P = "P"
    }
}
