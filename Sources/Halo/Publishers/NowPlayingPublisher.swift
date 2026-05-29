import AppKit

/// Polls `MediaRemote.framework` (PRIVATE) for system-wide now-
/// playing info and surfaces the current track in the island.
///
/// Private API caveats:
///   • Apple started gating MediaRemote in macOS 14.4 — third-
///     party apps without `com.apple.developer.media-app-services`
///     get empty payloads. Restored on 15+. This publisher silently
///     no-ops if the framework returns nothing; it doesn't crash
///     the rest of Halo.
///   • Function pointers are resolved via `CFBundleGetFunction
///     PointerForName` at first use. If symbols vanish in a
///     future macOS, `publishCurrent()` skips.
///
/// Publishing strategy:
///   • Steady-state priority 60 (above Espresso at 60 ties, below
///     transient HUDs at 90).
///   • Withdraws (`coordinator.clear`) when nothing is playing or
///     when the front media app pauses.
///   • Refreshes on `kMRMediaRemote…DidChangeNotification`
///     deliveries from the framework — no polling.
@MainActor
final class NowPlayingPublisher: HaloPublisher {
    let id = "halo.nowplaying"

    private weak var coordinator: LiveActivityCoordinator?
    private var observers: [NSObjectProtocol] = []
    private var registered = false

    init(coordinator: LiveActivityCoordinator) {
        self.coordinator = coordinator
    }

    /// Backup poll for the AppleScript fallback path — Spotify
    /// doesn't fire MediaRemote notifications on macOS 14.4+
    /// without a private entitlement we don't have. Polling at
    /// 1.5s catches track changes within the rapid-update
    /// window so they don't constantly grab focus.
    private var pollTimer: Timer?

    func start() {
        NowPlayingDebugLog.append("\(Date()) start()\n")
        if MediaRemote.shared != nil {
            NowPlayingDebugLog.append(
                "\(Date()) MediaRemote loaded\n")
            // Subscribe BEFORE calling Register so the first
            // notif arrives at us.
            for name in [
                "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            ] {
                let obs = NotificationCenter.default.addObserver(
                    forName: NSNotification.Name(name),
                    object: nil, queue: .main
                ) { [weak self] note in
                    NowPlayingDebugLog.append(
                        "\(Date()) notif: \(note.name.rawValue)\n")
                    Task { @MainActor in self?.publishCurrent() }
                }
                observers.append(obs)
            }
            MediaRemote.shared?.registerForNotifications(queue: .main)
            registered = true
        } else {
            NowPlayingDebugLog.append(
                "\(Date()) MediaRemote.framework UNAVAILABLE\n")
        }
        // Always start the AppleScript poller — Spotify on
        // macOS 14.4+ is invisible to MediaRemote without
        // private entitlements, so we ALSO ask Spotify
        // directly via its scripting dictionary. Cheap (a
        // single AppleScript dispatch every 1.5s).
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: 1.5, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.publishCurrent() }
        }
        publishCurrent()
    }

    func stop() {
        for o in observers {
            NotificationCenter.default.removeObserver(o)
        }
        observers.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        coordinator?.clear(id: id)
    }

    // MARK: - Publish

    /// Collect candidates from every AppleScript source we
    /// have, prefer one that's actually playing, fall back to
    /// MediaRemote when nothing else turns anything up.
    ///
    /// Why prefer-playing instead of priority-ordered:
    /// Spotify's AppleScript reports a track even when paused,
    /// so the old "Spotify first → win" rule meant a paused
    /// Spotify hid an actively-playing YouTube tab. We now
    /// pick the playing source across all candidates and only
    /// fall back to a paused source if NOTHING is playing
    /// (so the user still sees "the last thing I was
    /// listening to" when nothing is live).
    private func publishCurrent() {
        let candidates: [LiveActivityCoordinator.MediaInfo] = [
            SpotifyScripter.readNowPlaying(),
            MusicScripter.readNowPlaying(),
            BrowserMediaScripter.readNowPlaying(),
        ].compactMap { $0 }
        if let playing = candidates.first(
            where: { $0.isPlaying }
        ) {
            NowPlayingDebugLog.append(
                "\(Date()) playing: \(playing.source) " +
                "— \(playing.title)\n")
            inject(playing)
            return
        }
        if let any = candidates.first {
            NowPlayingDebugLog.append(
                "\(Date()) paused: \(any.source) " +
                "— \(any.title)\n")
            inject(any)
            return
        }
        // MediaRemote async query — last resort, often empty
        // post-14.4 without the private entitlement.
        guard let mr = MediaRemote.shared else {
            coordinator?.clear(id: id)
            return
        }
        mr.getNowPlayingInfo(queue: .main) { [weak self] dict in
            Task { @MainActor in self?.applyMediaRemote(dict) }
        }
    }

    private func applyMediaRemote(_ info: [String: Any]) {
        let keys = info.keys.sorted().joined(separator: ",")
        let title = info["kMRMediaRemoteNowPlayingInfoTitle"]
            as? String
        let artist = info["kMRMediaRemoteNowPlayingInfoArtist"]
            as? String
        let album = info["kMRMediaRemoteNowPlayingInfoAlbum"]
            as? String
        let playbackRate = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"]
            as? NSNumber)?.doubleValue ?? 0
        let elapsed = (info["kMRMediaRemoteNowPlayingInfoElapsedTime"]
            as? NSNumber)?.doubleValue
        let duration = (info["kMRMediaRemoteNowPlayingInfoDuration"]
            as? NSNumber)?.doubleValue
        var artwork: NSImage?
        if let data = info["kMRMediaRemoteNowPlayingInfoArtworkData"]
            as? Data {
            artwork = NSImage(data: data)
        }
        NowPlayingDebugLog.append(
            "\(Date()) apply(MR): title=\(title ?? "nil") rate=\(playbackRate) keys=\(keys)\n")
        guard let title, !title.isEmpty, playbackRate > 0 else {
            coordinator?.clear(id: id)
            return
        }
        inject(LiveActivityCoordinator.MediaInfo(
            title: title,
            artist: artist,
            album: album,
            artwork: artwork,
            positionSeconds: elapsed,
            durationSeconds: duration,
            isPlaying: playbackRate > 0,
            source: "MediaRemote"))
    }

    private func inject(
        _ media: LiveActivityCoordinator.MediaInfo
    ) {
        // Trailing label: position / duration when we know
        // both. Falls back to nil when the title is already
        // riding on the leading wing — the artwork (Spotify)
        // and source-icon-without-artwork paths
        // (YouTube/SoundCloud/etc.) both put the title on
        // the left, so the trailing slot stays clean. The
        // bare title only goes in the trailing slot when we
        // have NEITHER position nor a leading title slot
        // (the MediaRemote-only path with no artwork).
        let label: String?
        if let pos = media.positionSeconds,
           let dur = media.durationSeconds, dur > 0 {
            // Switch to H:MM:SS the moment the content is
            // an hour or longer — a 1h23m video reads as
            // `0:22:40 / 1:23:45`, not `22:40 / 83:45`.
            // Both halves of the readout share the same
            // format so the divider stays aligned through
            // the transition (a 59:59 → 1:00:00 jump on
            // a long video doesn't reshape the pill).
            let useHours = dur >= 3600
            label = "\(Self.formatTime(pos, hours: useHours)) / \(Self.formatTime(dur, hours: useHours))"
        } else if let dur = media.durationSeconds,
                  dur > 0 {
            // Position unknown (Chromium browsers without
            // 'Allow JavaScript from Apple Events' enabled,
            // YouTube duration fetched via URL scrape, …) —
            // at least surface the total length so the user
            // sees something on the right.
            label = Self.formatTime(dur, hours: dur >= 3600)
        } else if media.artwork != nil
                  || Self.titleRendersOnLeading(media) {
            label = nil
        } else {
            label = Self.truncate(media.title, max: 24)
        }
        let payload = LiveActivityCoordinator.Resolved(
            id: id,
            compactLeadingImage:
                LiveActivityCoordinator.symbolImage(
                    Self.leadingSymbol(for: media)),
            compactTrailingText: label,
            compactTrailingImage: nil,
            tint: .white,
            priority: 60,
            media: media)
        coordinator?.inject(payload)
    }

    /// SF Symbol that doubles as the source's logo when we
    /// don't have artwork. Brand-tinted by `pillIconColor` to
    /// match the source colour the accent line is already
    /// painting (red for YouTube, orange for SoundCloud, …).
    private static func leadingSymbol(
        for media: LiveActivityCoordinator.MediaInfo
    ) -> String {
        switch media.source {
        case "YouTube", "YouTube Music":
            // Play-in-a-rectangle reads as YouTube once it's
            // tinted in the source's red.
            return "play.rectangle.fill"
        case "SoundCloud":
            return "cloud.fill"
        case "Bandcamp":
            return "music.note.list"
        case "Twitch":
            return "tv.fill"
        case "Vimeo":
            return "play.rectangle.fill"
        case "Spotify Web":
            return "music.note"
        default:
            return "music.note"
        }
    }

    /// True for sources where NotchView should render the
    /// track title to the right of the leading icon (mirroring
    /// the Spotify-with-artwork layout) instead of trailing.
    /// Keeps the trailing slot reserved for the time read-out.
    nonisolated static func titleRendersOnLeading(
        _ media: LiveActivityCoordinator.MediaInfo
    ) -> Bool {
        switch media.source {
        case "YouTube", "YouTube Music",
             "SoundCloud", "Bandcamp",
             "Twitch", "Vimeo", "Spotify Web":
            return true
        default:
            return false
        }
    }

    private static func truncate(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        return s.prefix(max - 1) + "…"
    }

    /// Seconds → display string. Two layouts:
    ///   • `hours = false` → "MM:SS" (zero-padded), used for
    ///     anything under an hour. Both fields padded so the
    ///     label never changes width — "01:23" → "01:24"
    ///     rolls digit-for-digit through
    ///     `.contentTransition(.numericText())` without the
    ///     pill having to re-flow when the minute crosses a
    ///     one-/two-digit boundary at 9:59 → 10:00.
    ///   • `hours = true` → "H:MM:SS" (hour unpadded, MM+SS
    ///     padded). Used the moment the content duration
    ///     hits an hour so the readout never grows minute-
    ///     beyond-60 ("83:45" looks broken; "1:23:45" reads
    ///     naturally).
    private static func formatTime(
        _ seconds: Double, hours: Bool
    ) -> String {
        let total = max(0, Int(seconds.rounded()))
        if hours {
            let h = total / 3600
            let m = (total % 3600) / 60
            let s = total % 60
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - MediaRemote wrapper

/// Singleton `dlopen`-based binding to `MediaRemote.framework`.
/// Returns `nil` if the framework fails to load or any symbol
/// is missing — callers can no-op rather than crashing.
@MainActor
private final class MediaRemote {

    typealias GetNowPlayingInfoFn = @convention(c) (
        DispatchQueue,
        @escaping ([String: Any]) -> Void
    ) -> Void

    typealias RegisterFn = @convention(c) (DispatchQueue) -> Void

    static let shared: MediaRemote? = MediaRemote()

    private let getNowPlayingInfoSym: GetNowPlayingInfoFn
    private let registerSym: RegisterFn

    private init?() {
        let path =
            "/System/Library/PrivateFrameworks/MediaRemote.framework"
        guard let url = URL(string: "file://\(path)"),
              let bundle = CFBundleCreate(nil, url as CFURL),
              CFBundleLoadExecutable(bundle)
        else { return nil }
        let getPtr = CFBundleGetFunctionPointerForName(
            bundle,
            "MRMediaRemoteGetNowPlayingInfo" as CFString)
        let regPtr = CFBundleGetFunctionPointerForName(
            bundle,
            "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString)
        guard let getPtr, let regPtr else { return nil }
        self.getNowPlayingInfoSym = unsafeBitCast(
            getPtr, to: GetNowPlayingInfoFn.self)
        self.registerSym = unsafeBitCast(
            regPtr, to: RegisterFn.self)
    }

    func getNowPlayingInfo(
        queue: DispatchQueue,
        completion: @escaping ([String: Any]) -> Void
    ) {
        getNowPlayingInfoSym(queue, completion)
    }

    func registerForNotifications(queue: DispatchQueue) {
        registerSym(queue)
    }
}

// MARK: - Debug log

/// `/tmp/halo-nowplaying.log` — same pattern as the AirPods
/// debug log. Bypasses NSLog's privacy redaction so we can see
/// what MediaRemote returns (and whether Spotify shows up).
/// Capped at 64KB.
enum NowPlayingDebugLog {
    nonisolated(unsafe) private static var didTruncate = false
    private static let path = "/tmp/halo-nowplaying.log"

    static func append(_ line: String) {
        if !didTruncate {
            try? "".write(toFile: path, atomically: true,
                          encoding: .utf8)
            didTruncate = true
        }
        guard let handle = FileHandle(forWritingAtPath: path),
              let data = line.data(using: .utf8)
        else { return }
        handle.seekToEndOfFile()
        if handle.offsetInFile > 64_000 {
            try? handle.close()
            try? "".write(toFile: path, atomically: true,
                          encoding: .utf8)
            if let h2 = FileHandle(forWritingAtPath: path) {
                try? h2.write(contentsOf: data)
                try? h2.close()
            }
            return
        }
        try? handle.write(contentsOf: data)
        try? handle.close()
    }
}
