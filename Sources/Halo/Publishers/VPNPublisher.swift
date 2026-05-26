import AppKit
import NetworkExtension

/// System-wide VPN state via NetworkExtension.
///
/// `NEVPNManager` covers the built-in macOS VPN slot (IKEv2 /
/// L2TP / Cisco IPsec / Wireguard configurations the user has
/// added to System Settings). For third-party clients that
/// install their own network extensions (NordVPN, Mullvad,
/// Tailscale, ProtonVPN), `NETunnelProviderManager
/// .loadAllFromPreferences` returns each provider's profile +
/// status.
///
/// Visibility rule: silent when no VPN is configured. Shows
/// the active provider name + connection state when connected,
/// "Connecting…" while transitioning.
@MainActor
final class VPNPublisher: HaloPublisher {
    let id = "halo.vpn"

    private weak var coordinator: LiveActivityCoordinator?
    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?

    init(coordinator: LiveActivityCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        // VPN status changes post `NEVPNStatusDidChange` — much
        // cheaper than polling, but we keep a 30s safety poll
        // for tunnel providers whose status changes don't
        // always surface as notifications.
        let obs = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        observers.append(obs)
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: 30, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
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

    private func refresh() {
        // Pull tunnel providers (the broader category — covers
        // NordVPN, Mullvad, ProtonVPN, WireGuard, etc).
        NETunnelProviderManager.loadAllFromPreferences {
            [weak self] managers, _ in
            Task { @MainActor in
                guard let self else { return }
                let all = (managers ?? []).map(\.connection.status)
                let names = (managers ?? []).map {
                    $0.localizedDescription ?? "VPN"
                }
                // Plus the built-in NEVPNManager slot.
                let builtinStatus =
                    NEVPNManager.shared().connection.status
                let allStatuses = all + [builtinStatus]
                // Find the most "interesting" status: connected
                // > connecting > disconnecting > anything else.
                if let idx = allStatuses.firstIndex(where: {
                    $0 == .connected
                }) {
                    self.publish(connected: true,
                                 label: idx < names.count
                                     ? names[idx] : "VPN")
                } else if allStatuses.contains(.connecting)
                       || allStatuses.contains(.reasserting) {
                    self.publish(connected: false,
                                 label: "Connecting…")
                } else {
                    self.coordinator?.clear(id: self.id)
                }
            }
        }
    }

    private func publish(connected: Bool, label: String) {
        let payload = LiveActivityCoordinator.Resolved(
            id: id,
            compactLeadingImage:
                LiveActivityCoordinator.symbolImage(
                    connected
                        ? "lock.shield.fill"
                        : "lock.shield"),
            compactTrailingText: label,
            compactTrailingImage: nil,
            tint: .white,
            priority: 35)
        coordinator?.inject(payload)
    }
}
