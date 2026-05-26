import AppKit

/// Watches the main display's backlight brightness and emits a
/// 2s-TTL HUD on every change — same UX as the system bezel.
///
/// Why polling: macOS has no public brightness API and no
/// reliable public notification for backlight changes. F1/F2
/// keystrokes are intercepted by the WindowServer on Apple
/// Silicon before any event monitor sees them. A 250ms poll
/// against the private `DisplayServicesGetBrightness` symbol
/// catches every change within one tick — cheap (a single
/// float read per quarter second) and works on every Mac with
/// a backlight, internal or external.
@MainActor
final class BrightnessPublisher: HaloPublisher {
    let id = "halo.brightness"

    private weak var coordinator: LiveActivityCoordinator?
    private var pollTimer: Timer?
    private var lastBrightness: Float = -1

    init(coordinator: LiveActivityCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        guard DisplayServices.shared != nil else {
            NSLog("[halo] Brightness: DisplayServices.framework unavailable")
            return
        }
        // Prime the cache silently so we don't pop a HUD at
        // app launch.
        lastBrightness = readBrightness()
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: 0.25, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        coordinator?.clear(id: id)
    }

    // MARK: - Polling

    private func tick() {
        let b = readBrightness()
        let delta = abs(b - lastBrightness)
        // Filter auto-brightness ramps. The ambient-light
        // sensor drifts brightness in tiny ~0.5–2% steps every
        // few seconds; pressing F1/F2 jumps a discrete
        // 6.25% (1/16) step. A 5% threshold catches
        // user-initiated presses without firing the HUD every
        // time the sensor adjusts to changing room light.
        guard delta >= 0.05 else {
            lastBrightness = b  // keep the cache fresh so a
                                // future big jump compares to
                                // current, not stale, value
            return
        }
        lastBrightness = b
        publishCurrent(b: b)
    }

    private func readBrightness() -> Float {
        guard let ds = DisplayServices.shared else { return 0 }
        var b: Float = 0
        _ = ds.getBrightness(CGMainDisplayID(), &b)
        return b
    }

    private func publishCurrent(b: Float) {
        let clamped = max(0, min(1, b))
        let pct = Int(round(clamped * 100))
        // Sun glyph weight tracks brightness so the icon
        // "matches" the level — same trick the system bezel uses.
        let symbol: String
        switch clamped {
        case ..<0.34: symbol = "sun.min.fill"
        case ..<0.67: symbol = "sun.max.fill"
        default: symbol = "sun.max.fill"
        }
        let payload = LiveActivityCoordinator.Resolved(
            id: id,
            compactLeadingImage:
                LiveActivityCoordinator.symbolImage(symbol),
            compactTrailingText: "\(pct)%",
            compactTrailingImage: nil,
            tint: .white,
            priority: 90)
        coordinator?.inject(payload, ttl: 2)
    }
}

// MARK: - DisplayServices wrapper

/// `dlopen`-based binding to the private DisplayServices
/// framework. Returns `nil` if the framework / symbol is
/// unavailable so `BrightnessPublisher.start()` can no-op.
@MainActor
private final class DisplayServices {

    typealias GetBrightnessFn = @convention(c) (
        CGDirectDisplayID,
        UnsafeMutablePointer<Float>
    ) -> Int32

    static let shared: DisplayServices? = DisplayServices()

    private let getBrightnessSym: GetBrightnessFn

    private init?() {
        let path =
            "/System/Library/PrivateFrameworks/DisplayServices.framework"
        guard let url = URL(string: "file://\(path)"),
              let bundle = CFBundleCreate(nil, url as CFURL),
              CFBundleLoadExecutable(bundle),
              let ptr = CFBundleGetFunctionPointerForName(
                bundle,
                "DisplayServicesGetBrightness" as CFString)
        else { return nil }
        self.getBrightnessSym = unsafeBitCast(
            ptr, to: GetBrightnessFn.self)
    }

    func getBrightness(
        _ id: CGDirectDisplayID,
        _ value: UnsafeMutablePointer<Float>
    ) -> Int32 {
        getBrightnessSym(id, value)
    }
}
