import AppKit
import Foundation

/// In-process logo cache. CoinGecko serves PNG logos at fixed CDN
/// URLs — we fetch lazily on first publish, NSImage decodes once,
/// and every subsequent render hits the cache.
extension CryptoTrackerExtension {
    // MARK: - Logo cache

    /// Per-URL cache for coin logos. SwiftUI views look up
    /// images via `cachedLogo(url:)` synchronously; cache
    /// misses fall back to the SF Symbol while the async
    /// fetcher warms the entry. `nonisolated(unsafe)` is
    /// fine because access is funnelled through MainActor —
    /// only the warmer hops off-actor and back.
    nonisolated(unsafe)
        private static var logoCache: [String: NSImage] = [:]
    nonisolated(unsafe)
        private static var logoPending: Set<String> = []

    static func cachedLogo(url: String?) -> NSImage? {
        guard let url, !url.isEmpty else { return nil }
        return logoCache[url]
    }

    static func warmLogoCache(url: String) {
        if logoCache[url] != nil { return }
        if logoPending.contains(url) { return }
        logoPending.insert(url)
        Task.detached(priority: .utility) {
            let img = await fetchLogo(url: url)
            await MainActor.run {
                logoPending.remove(url)
                if let img { logoCache[url] = img }
            }
        }
    }

    nonisolated private static func fetchLogo(
        url urlStr: String
    ) async -> NSImage? {
        guard let url = URL(string: urlStr) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0",
                         forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared
                .data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let img = NSImage(data: data)
            else { return nil }
            return img
        } catch {
            return nil
        }
    }
}
