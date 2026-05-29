import AppKit
import Foundation
import SwiftUI

/// All the lightweight value types nested inside
/// `LiveActivityCoordinator` — the per-publisher payload
/// shapes the renderer reads. Split out as an extension so
/// the coordinator file stays focused on state + behaviour.
extension LiveActivityCoordinator {
    /// Normalised activity ready for the UI. The store's JSON
    /// `Payload` reduces to this shape — SF Symbol names get
    /// resolved into template NSImages on this side so the
    /// renderer stays uniform.
    struct Resolved: Identifiable, Equatable {
        let id: String
        let compactLeadingImage: NSImage?
        let compactTrailingText: String?
        let compactTrailingImage: NSImage?
        let tint: Color
        let priority: Int
        /// Optional rich-media payload — present only for
        /// Now Playing. Drives the expanded card's artwork +
        /// scrubber + controls.
        let media: MediaInfo?
        /// Optional Worktree-specific payload — populated only
        /// for the `worktree` slot. Drives the branch-switcher
        /// dropdown in the expanded card.
        let worktree: WorktreeInfo?
        /// Optional Port-specific payload — listening-port
        /// rows + owning pids the expanded card renders with
        /// per-row kill buttons.
        let port: PortInfo?
        /// Optional AirPods-specific payload — left/right/case
        /// battery + charging state + device label. Drives the
        /// AirPods expanded card so hovering the pill reveals
        /// the full per-bud breakdown rather than just the
        /// single "lowest of the two" number on the pill.
        let airpods: AirPodsInfo?
        /// Optional Battery-specific payload — internal Mac
        /// state plus an enumeration of every connected HID
        /// accessory that publishes BatteryPercent in
        /// IORegistry (Magic Mouse / Trackpad / Keyboard, …).
        let battery: BatteryInfo?
        /// Optional Bluetooth-audio payload — non-AirPods/Beats
        /// audio output devices the publisher surfaces while
        /// they're the active output. AirPods/Beats keep their
        /// own dedicated pill via `AirPodsPublisher`.
        let bluetoothAudio: BluetoothAudioInfo?
        /// Optional crypto-tracker payload — the leaderboard
        /// of tracked coins that the compact pill cycles
        /// through and the expanded card renders as a sortable
        /// list. First proof-of-concept for the extensions
        /// framework.
        let crypto: CryptoInfo?
        /// Optional SF Symbol rendered inline as a glyph BEFORE
        /// the trailing text. Lets the battery pill prepend a
        /// lightning bolt when charging without having to bake
        /// it into the leading icon. Nil for activities that
        /// don't decorate their value.
        let compactTrailingPrefixSymbol: String?

        init(
            id: String,
            compactLeadingImage: NSImage?,
            compactTrailingText: String?,
            compactTrailingImage: NSImage?,
            tint: Color,
            priority: Int,
            media: MediaInfo? = nil,
            worktree: WorktreeInfo? = nil,
            port: PortInfo? = nil,
            airpods: AirPodsInfo? = nil,
            battery: BatteryInfo? = nil,
            bluetoothAudio: BluetoothAudioInfo? = nil,
            crypto: CryptoInfo? = nil,
            compactTrailingPrefixSymbol: String? = nil
        ) {
            self.id = id
            self.compactLeadingImage = compactLeadingImage
            self.compactTrailingText = compactTrailingText
            self.compactTrailingImage = compactTrailingImage
            self.tint = tint
            self.priority = priority
            self.media = media
            self.worktree = worktree
            self.port = port
            self.airpods = airpods
            self.battery = battery
            self.bluetoothAudio = bluetoothAudio
            self.crypto = crypto
            self.compactTrailingPrefixSymbol =
                compactTrailingPrefixSymbol
        }

        static func == (l: Resolved, r: Resolved) -> Bool {
            l.id == r.id &&
            l.compactTrailingText == r.compactTrailingText &&
            l.priority == r.priority &&
            l.tint == r.tint &&
            l.media?.title == r.media?.title &&
            l.media?.isPlaying == r.media?.isPlaying &&
            // Artwork-presence check — the YouTube
            // thumbnail loads async, so the first publish
            // for a video has nil artwork and the next one
            // has it. Without this, Resolved.== would say
            // the payload is unchanged and SwiftUI wouldn't
            // re-render to pick up the cover art.
            (l.media?.artwork == nil) == (r.media?.artwork == nil) &&
            l.worktree?.currentBranch == r.worktree?.currentBranch &&
            l.worktree?.branches == r.worktree?.branches &&
            l.worktree?.remoteBranches == r.worktree?.remoteBranches &&
            l.worktree?.isDirty == r.worktree?.isDirty &&
            l.worktree?.ahead == r.worktree?.ahead &&
            l.worktree?.behind == r.worktree?.behind &&
            l.worktree?.dirtyCount == r.worktree?.dirtyCount &&
            l.worktree?.isPinned == r.worktree?.isPinned &&
            l.worktree?.lastError == r.worktree?.lastError &&
            l.worktree?.worktrees == r.worktree?.worktrees &&
            l.worktree?.savedProjects == r.worktree?.savedProjects &&
            l.port?.entries == r.port?.entries &&
            l.airpods == r.airpods &&
            l.battery == r.battery &&
            l.bluetoothAudio == r.bluetoothAudio &&
            l.crypto == r.crypto &&
            l.compactTrailingPrefixSymbol
                == r.compactTrailingPrefixSymbol
        }
    }

    /// Crypto-tracker payload (first extension). Carries the
    /// full leaderboard so the expanded card can re-sort
    /// client-side (Top Movers, Market Cap, % change) without
    /// the publisher having to fan out three different views.
    /// The compact pill's text is driven by the currently-
    /// cycled coin from `tickers[currentIndex]`.
    struct CryptoInfo: Equatable {
        let tickers: [CryptoTicker]
        /// Index into `tickers` for the coin currently on
        /// the compact pill. Cycled by the publisher every
        /// few seconds so the rotation tells the user about
        /// every tracked coin without forcing a single pick.
        let currentIndex: Int
        /// Last successful refresh wall-clock — drives the
        /// "updated 5s ago" footer in the expanded card.
        let lastUpdated: Date
        /// Currency code the prices are denominated in
        /// (`usd`, `eur`, …) so the expanded card can format
        /// labels correctly.
        let fiat: String
    }

    struct CryptoTicker: Equatable, Hashable {
        let id: String        // CoinGecko id (e.g. "bitcoin")
        let symbol: String    // ticker (e.g. "btc")
        let name: String      // display name (e.g. "Bitcoin")
        let price: Double
        let change1h: Double  // percent, last hour
        let change24h: Double // percent, last 24 hours
        let marketCap: Double?
        let rank: Int?
        /// URL to CoinGecko's official coin logo (`thumb` /
        /// `small` / `large` sizes available; we pull
        /// `large` and let SwiftUI rasterise down). The
        /// publisher fetches + caches the bitmap; rendering
        /// looks it up by URL.
        let imageURL: String?
        /// 7-day hourly price points from CoinGecko's
        /// `sparkline_in_7d` field. Drives the mini line
        /// chart in the expanded leaderboard row. Empty
        /// when CoinGecko didn't return one (rare).
        let sparkline: [Double]

        /// Best-effort native brand colour for the coin's
        /// symbol text. Covers the top-20 by market cap
        /// plus a few popular memes; unknowns fall back to
        /// the Bitcoin-orange publisher tint so the pill
        /// still reads as "crypto". Lives on the model so
        /// the compact-pill renderer (NotchView) and the
        /// expanded-card renderer (CryptoRow) agree on the
        /// same lookup table.
        var brandColor: Color {
            switch symbol.uppercased() {
            case "BTC":  return Color(red: 0.97, green: 0.58, blue: 0.10)
            case "ETH":  return Color(red: 0.40, green: 0.51, blue: 0.96)
            case "SOL":  return Color(red: 0.32, green: 0.91, blue: 0.62)
            case "DOGE": return Color(red: 0.91, green: 0.76, blue: 0.30)
            case "ADA":  return Color(red: 0.25, green: 0.49, blue: 0.95)
            case "XRP":  return Color(red: 0.20, green: 0.78, blue: 0.95)
            case "BNB":  return Color(red: 0.96, green: 0.73, blue: 0.18)
            case "USDT": return Color(red: 0.15, green: 0.63, blue: 0.48)
            case "USDC": return Color(red: 0.15, green: 0.46, blue: 0.79)
            case "LTC":  return Color(red: 0.65, green: 0.71, blue: 0.78)
            case "AVAX": return Color(red: 0.91, green: 0.26, blue: 0.26)
            case "DOT":  return Color(red: 0.90, green: 0.00, blue: 0.48)
            case "MATIC", "POL":
                return Color(red: 0.51, green: 0.28, blue: 0.90)
            case "LINK": return Color(red: 0.27, green: 0.50, blue: 0.91)
            case "SHIB": return Color(red: 1.00, green: 0.55, blue: 0.20)
            case "TRX":  return Color(red: 0.94, green: 0.20, blue: 0.25)
            case "TON":  return Color(red: 0.00, green: 0.55, blue: 0.81)
            case "ATOM": return Color(red: 0.13, green: 0.10, blue: 0.37)
            case "UNI":  return Color(red: 1.00, green: 0.00, blue: 0.46)
            case "XLM":  return Color(red: 0.50, green: 0.60, blue: 0.70)
            default:     return Color(red: 0.97, green: 0.58, blue: 0.10)
            }
        }
    }

    /// Bluetooth-audio device payload — captured from
    /// CoreAudio (device name + transport) plus a best-effort
    /// battery read via `system_profiler SPBluetoothDataType`
    /// (cached, runs in the background).
    struct BluetoothAudioInfo: Equatable {
        let name: String
        /// Battery percent (0…100) or nil if unknown / not
        /// reported by the device. Generic Bluetooth speakers
        /// usually report via AVRCP and `system_profiler`
        /// exposes it; some headphones only report when paused.
        let batteryPercent: Int?
        /// Minor type / form factor inferred from the device
        /// name + `system_profiler` minorType so the expanded
        /// card picks the right SF Symbol — speaker /
        /// headphones / soundbar / earbuds.
        let symbol: String
    }

    /// Battery state payload — covers the internal Mac
    /// battery plus an enumeration of connected HID
    /// accessories. The expanded card lists everything in one
    /// place so the user can glance at the notch and see
    /// every device they care about (Mac, Magic Mouse,
    /// Trackpad, Keyboard, …) without opening System
    /// Settings.
    struct BatteryInfo: Equatable {
        let macPercent: Int
        let macCharging: Bool
        /// Connected HID accessories (Magic Mouse / Trackpad /
        /// Keyboard, third-party HID with battery, …) read
        /// from IORegistry's `BatteryPercent` key. Empty when
        /// no accessory is connected or reporting.
        let devices: [ConnectedBatteryDevice]
    }

    struct ConnectedBatteryDevice: Equatable, Hashable {
        let name: String
        let percent: Int
        /// SF Symbol the expanded card renders to the left of
        /// the device name. Inferred from the product string
        /// — `magicmouse.fill` for Magic Mouse, etc.; falls
        /// back to a generic `dot.radiowaves.left.and.right`
        /// when we can't classify it.
        let symbol: String
    }

    /// AirPods state payload — Halo decodes from the BLE
    /// proximity-pairing advertisement (see AirPodsPublisher).
    /// Each bud's battery is `nil` when it's in the case or
    /// the firmware reported "unknown" (0xF nibble).
    struct AirPodsInfo: Equatable {
        let left: Int?
        let right: Int?
        let caseBattery: Int?
        /// True if any bud / the case is currently charging.
        let charging: Bool
        /// Human-readable device label drawn from CoreAudio's
        /// `kAudioObjectPropertyName` on the active output —
        /// e.g. "Matt's AirPods Pro" or "Beats Studio Buds".
        /// Empty string if we couldn't resolve a name.
        let deviceName: String
    }

    /// Full Worktree state payload — Halo decodes everything
    /// the standalone Worktree popover renders so the expanded
    /// card can be a complete control surface (Phase 1-3 of the
    /// feature-parity work). All collection-typed fields default
    /// to empty so older Worktree releases that don't populate
    /// the newer JSON keys still decode cleanly.
    struct WorktreeInfo: Equatable {
        let repoPath: String
        let displayName: String?
        let currentBranch: String
        let branches: [String]
        let remoteBranches: [String]
        let isDirty: Bool
        let ahead: Int
        let behind: Int
        let dirtyCount: Int
        let worktrees: [WorktreeEntryInfo]
        let savedProjects: [SavedProjectInfo]
        let isPinned: Bool
        let lastError: String?
    }

    struct WorktreeEntryInfo: Equatable, Hashable {
        let path: String
        let branch: String?
        let isCurrent: Bool
        let isMain: Bool
    }

    struct SavedProjectInfo: Equatable, Hashable {
        let path: String
        let displayName: String
        let lastKnownBranch: String?
    }

    /// Port-list payload Halo decodes from `port.json`. One
    /// entry per row in the expanded card.
    struct PortInfo: Equatable {
        let entries: [PortEntry]
    }

    struct PortEntry: Equatable, Hashable {
        let proto: String
        let port: Int
        let pid: Int32
        let process: String
        let service: String?
    }

    /// Rich Now Playing payload. Position / duration are in
    /// seconds; artwork is the raw track image (album cover).
    /// `source` describes who's playing (Spotify / Music /
    /// MediaRemote) so the expanded view can route control
    /// commands back through the right AppleScript app.
    struct MediaInfo: Equatable {
        let title: String
        let artist: String?
        let album: String?
        let artwork: NSImage?
        let positionSeconds: Double?
        let durationSeconds: Double?
        let isPlaying: Bool
        let source: String

        static func == (l: MediaInfo, r: MediaInfo) -> Bool {
            // Skip artwork pixel comparison (slow + NSImage
            // doesn't conform to Equatable). Title + source +
            // isPlaying covers track changes; positions are
            // refreshed via the expanded view's own timer.
            l.title == r.title &&
            l.artist == r.artist &&
            l.source == r.source &&
            l.isPlaying == r.isPlaying
        }
    }
}
