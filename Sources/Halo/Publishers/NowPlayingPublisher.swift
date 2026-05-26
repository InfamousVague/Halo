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

    func start() {
        guard MediaRemote.shared != nil else {
            NSLog("[halo] NowPlaying: MediaRemote.framework unavailable")
            return
        }
        // Subscribe to MediaRemote's change notifications BEFORE
        // calling Register* — otherwise the first event may fire
        // before our observers attach.
        for name in [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        ] {
            let obs = NotificationCenter.default.addObserver(
                forName: NSNotification.Name(name),
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.publishCurrent() }
            }
            observers.append(obs)
        }
        MediaRemote.shared?.registerForNotifications(queue: .main)
        registered = true
        // Initial query — at launch, something may already be
        // playing.
        publishCurrent()
    }

    func stop() {
        for o in observers {
            NotificationCenter.default.removeObserver(o)
        }
        observers.removeAll()
        coordinator?.clear(id: id)
    }

    // MARK: - Publish

    private func publishCurrent() {
        guard let mr = MediaRemote.shared else { return }
        mr.getNowPlayingInfo(queue: .main) { [weak self] info in
            Task { @MainActor in self?.apply(info: info) }
        }
    }

    private func apply(info: [String: Any]) {
        // No info or paused (playbackRate 0) → withdraw.
        let playbackRate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"]
            as? Double ?? 0
        let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String
        let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String

        guard let title, !title.isEmpty, playbackRate > 0 else {
            coordinator?.clear(id: id)
            return
        }

        // Trailing label: title only — artist would require a
        // separate region the compact slot doesn't have yet.
        // (Phase 2: artist on the expanded view.)
        let truncated = truncate(title, max: 24)
        _ = artist  // reserved for the expanded card

        let payload = LiveActivityCoordinator.Resolved(
            id: id,
            compactLeadingImage:
                LiveActivityCoordinator.symbolImage("music.note"),
            compactTrailingText: truncated,
            compactTrailingImage: nil,
            tint: .white,
            priority: 60)
        coordinator?.inject(payload)
    }

    private func truncate(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        return s.prefix(max - 1) + "…"
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
