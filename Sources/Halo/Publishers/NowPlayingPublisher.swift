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

    /// Try sources in order:
    ///   1. MediaRemote — when it works, this is the cheapest
    ///      + broadest source (catches Apple Music, podcasts,
    ///      browsers etc. on macOS where the entitlement gate
    ///      hasn't bitten us).
    ///   2. Spotify via AppleScript — only path that works on
    ///      macOS 14.4+ for Spotify specifically.
    ///   3. Music.app via AppleScript — for users on macOS
    ///      versions where MediaRemote silently returned empty
    ///      for Apple Music too.
    /// First source with a non-empty playing track wins.
    private func publishCurrent() {
        // Try AppleScript Spotify first — when it's playing
        // it's almost always the user's primary source.
        if let info = SpotifyScripter.readNowPlaying() {
            NowPlayingDebugLog.append(
                "\(Date()) Spotify: \(info.title) — \(info.artist ?? "?") play=\(info.isPlaying)\n")
            inject(info)
            return
        }
        // Music.app fallback.
        if let info = MusicScripter.readNowPlaying() {
            NowPlayingDebugLog.append(
                "\(Date()) Music: \(info.title) — \(info.artist ?? "?") play=\(info.isPlaying)\n")
            inject(info)
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
        // Compact label: position / duration when we know
        // both — the album cover already identifies the
        // track, and a live "1:23 / 3:45" gives the user a
        // scrubber-y readout right in the menu bar. Falls
        // back to the truncated title for sources that don't
        // surface position (rare on AppleScript paths).
        let label: String
        if let pos = media.positionSeconds,
           let dur = media.durationSeconds, dur > 0 {
            label = "\(Self.formatTime(pos)) / \(Self.formatTime(dur))"
        } else {
            label = Self.truncate(media.title, max: 24)
        }
        let payload = LiveActivityCoordinator.Resolved(
            id: id,
            compactLeadingImage:
                LiveActivityCoordinator.symbolImage("music.note"),
            compactTrailingText: label,
            compactTrailingImage: nil,
            tint: .white,
            priority: 60,
            media: media)
        coordinator?.inject(payload)
    }

    private static func truncate(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        return s.prefix(max - 1) + "…"
    }

    /// Seconds → "MM:SS". Both fields are zero-padded so the
    /// label never changes width — "01:23" → "01:24" rolls
    /// digit-for-digit through `.contentTransition(.numericText())`
    /// without the pill having to re-flow when the minute
    /// crosses a one-/two-digit boundary at 9:59 → 10:00.
    private static func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
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
