import AppKit
import Foundation

/// YouTube-specific extras the parser can't infer from the tab
/// title alone: the thumbnail image (fetched from i.ytimg.com),
/// a best-effort position estimator, the duration cache, and
/// the video-id extractor that drives all of the above.
extension BrowserMediaScripter {
    static func cachedOrFetchYouTubeThumbnail(
        videoID: String
    ) -> NSImage? {
        if let cached = youtubeThumbnailCache[videoID] {
            return cached
        }
        guard !youtubeThumbnailPending.contains(videoID)
        else { return nil }
        youtubeThumbnailPending.insert(videoID)
        Task.detached(priority: .utility) {
            let img = await fetchYouTubeThumbnail(
                videoID: videoID)
            await MainActor.run {
                youtubeThumbnailPending.remove(videoID)
                if let img {
                    youtubeThumbnailCache[videoID] = img
                    NowPlayingDebugLog.append(
                        "\(Date()) YT thumb: " +
                        "\(videoID) → \(img.size)\n")
                }
            }
        }
        return nil
    }

    /// YouTube serves thumbnails at `img.youtube.com/vi/<id>/
    /// <quality>.jpg`. `maxresdefault` is highest quality
    /// (1280×720) when available; `hqdefault` (480×360) is
    /// the universal fallback (every public video has one).
    /// `mqdefault` (320×180) is the wide-aspect-ratio
    /// version which renders perfectly in the expanded card.
    /// We try maxres first, fall back if it 404s or returns
    /// the 120×90 placeholder YouTube serves for missing
    /// images.
    nonisolated private static func fetchYouTubeThumbnail(
        videoID: String
    ) async -> NSImage? {
        let candidates = [
            "https://i.ytimg.com/vi/\(videoID)/maxresdefault.jpg",
            "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg",
            "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg",
        ]
        for urlStr in candidates {
            guard let url = URL(string: urlStr)
            else { continue }
            var request = URLRequest(url: url)
            request.setValue(
                "Mozilla/5.0",
                forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 5
            do {
                let (data, response) = try await URLSession
                    .shared.data(for: request)
                guard let http = response
                        as? HTTPURLResponse,
                      http.statusCode == 200,
                      let img = NSImage(data: data)
                else { continue }
                // YouTube returns a 120×90 grey placeholder
                // when the resolution doesn't exist — skip
                // those and fall through to the next quality.
                if img.size.width < 200 { continue }
                return img
            } catch {}
        }
        return nil
    }

    /// Position estimate for a YouTube video. The first
    /// publish for a video pins t=0 to the wall clock; every
    /// subsequent call returns `(now - pinned) % duration`.
    /// Modulo so a video that loops past its length wraps
    /// instead of sticking at the end indefinitely.
    static func estimatedYouTubePosition(
        videoID: String, duration: Double
    ) -> Double {
        let now = Date()
        let firstSeen: Date
        if let existing = youtubeFirstSeenAt[videoID] {
            firstSeen = existing
        } else {
            firstSeen = now
            youtubeFirstSeenAt[videoID] = now
            // Prune so the cache doesn't grow without bound.
            if youtubeFirstSeenAt.count > 50 {
                youtubeFirstSeenAt = [videoID: now]
            }
        }
        let elapsed = now.timeIntervalSince(firstSeen)
        let wrapped = elapsed.truncatingRemainder(
            dividingBy: max(duration, 1))
        return wrapped >= 0 ? wrapped : 0
    }

    static func cachedOrFetchYouTubeDuration(
        videoID: String
    ) -> Double? {
        if let cached = youtubeDurationCache[videoID] {
            return cached
        }
        guard !youtubeFetchPending.contains(videoID)
        else { return nil }
        youtubeFetchPending.insert(videoID)
        Task.detached(priority: .utility) {
            let dur = await fetchYouTubeDurationFromPage(
                videoID: videoID)
            await MainActor.run {
                youtubeFetchPending.remove(videoID)
                if let dur {
                    youtubeDurationCache[videoID] = dur
                    NowPlayingDebugLog.append(
                        "\(Date()) YT scrape: " +
                        "\(videoID) → \(dur)s\n")
                } else {
                    NowPlayingDebugLog.append(
                        "\(Date()) YT scrape: " +
                        "\(videoID) → failed\n")
                }
            }
        }
        return nil
    }

    /// Hits the YouTube watch page and grep's `lengthSeconds`
    /// out of the embedded ytInitialPlayerResponse JSON.
    /// Works without an API key — the field is in the public
    /// HTML for every public video. Times out at 5s so a slow
    /// network doesn't hang the next publish.
    nonisolated private static func fetchYouTubeDurationFromPage(
        videoID: String
    ) async -> Double? {
        guard let url = URL(
            string:
                "https://www.youtube.com/watch?v=\(videoID)")
        else { return nil }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 5
        do {
            let (data, _) = try await URLSession.shared
                .data(for: request)
            guard let html = String(data: data,
                                    encoding: .utf8)
            else { return nil }
            // Pattern: `"lengthSeconds":"NNN"`. Appears
            // multiple times in the page; first hit is the
            // current video's length.
            let pattern = "\"lengthSeconds\":\"(\\d+)\""
            guard let re = try? NSRegularExpression(
                pattern: pattern) else { return nil }
            let range = NSRange(
                html.startIndex..., in: html)
            if let m = re.firstMatch(in: html, range: range),
               let r = Range(m.range(at: 1), in: html),
               let n = Double(html[r]), n > 0 {
                return n
            }
        } catch {}
        return nil
    }

    /// Parses out the YouTube video ID from any of the URL
    /// forms we recognise — `youtu.be/<id>`,
    /// `youtube.com/watch?v=<id>`, `youtube.com/shorts/<id>`,
    /// `youtube.com/embed/<id>`.
    static func extractYouTubeVideoID(
        from url: String
    ) -> String? {
        guard let comps = URLComponents(string: url)
        else { return nil }
        let host = (comps.host ?? "").lowercased()
        let path = comps.path
        if host == "youtu.be" {
            let id = path.hasPrefix("/")
                ? String(path.dropFirst()) : path
            return id.isEmpty ? nil : id
        }
        guard host.contains("youtube.com") else { return nil }
        if path == "/watch" {
            return comps.queryItems?.first(where: {
                $0.name == "v"
            })?.value
        }
        let shorts = "/shorts/"
        if path.hasPrefix(shorts) {
            return String(path.dropFirst(shorts.count))
                .components(separatedBy: "/").first
        }
        let embed = "/embed/"
        if path.hasPrefix(embed) {
            return String(path.dropFirst(embed.count))
                .components(separatedBy: "/").first
        }
        return nil
    }

}
