import AppKit
import EventKit

/// Next calendar event countdown — the killer iOS Live Activity
/// use case. Pulls events via `EKEventStore` (read-only,
/// requires the user grant Calendar access on first run via
/// `NSCalendarsUsageDescription`).
///
/// Visibility rules:
///   • > 60 min away → silent.
///   • 15–60 min → ambient, low priority.
///   • 0–15 min → focus pull, higher priority — "you have a
///     thing soon."
///   • Active (start ≤ now ≤ end) → top priority, the most
///     important pill on screen.
@MainActor
final class CalendarPublisher: HaloPublisher {
    let id = "halo.calendar"

    private weak var coordinator: LiveActivityCoordinator?
    private let store = EKEventStore()
    private var pollTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var granted = false

    init(coordinator: LiveActivityCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        // Calendar permission is async — when granted we
        // immediately publish + arm the refresh timer.
        store.requestFullAccessToEvents { [weak self] ok, _ in
            Task { @MainActor in
                guard let self else { return }
                self.granted = ok
                if ok { self.armRefresh() }
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        for o in observers {
            NotificationCenter.default.removeObserver(o)
        }
        observers.removeAll()
        coordinator?.clear(id: id)
    }

    private func armRefresh() {
        let obs = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        observers.append(obs)
        // 60s tick handles "an event just started/ended" and
        // gradually moves us through the warning levels.
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: 60, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        guard granted else { return }
        let calendars = store.calendars(for: .event)
        let now = Date()
        // Look 4h out — enough to catch the next scheduled
        // event without dragging in tomorrow's stuff.
        let end = now.addingTimeInterval(4 * 3600)
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-30 * 60),
            end: end,
            calendars: calendars)
        let events = store.events(matching: predicate)
            // Drop all-day events — they're calendar noise for
            // a status pill.
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        // Prefer an event we're currently in.
        if let current = events.first(where: { e in
            e.startDate <= now && e.endDate > now
        }) {
            let minsLeft = max(0,
                Int(current.endDate.timeIntervalSince(now) / 60))
            publish(
                title: current.title ?? "Meeting",
                detail: "ends in \(format(minsLeft))",
                priority: 75)
            return
        }

        guard let next = events.first(where: {
            $0.startDate > now
        }) else {
            coordinator?.clear(id: id)
            return
        }
        let minsUntil = max(0,
            Int(next.startDate.timeIntervalSince(now) / 60))
        if minsUntil > 60 {
            // Too far out — let the system Calendar widget
            // handle the long horizon.
            coordinator?.clear(id: id)
            return
        }
        let priority: Int = minsUntil <= 15 ? 70 : 45
        publish(
            title: next.title ?? "Meeting",
            detail: "in \(format(minsUntil))",
            priority: priority)
    }

    private func publish(
        title: String, detail: String, priority: Int
    ) {
        let truncated = title.count > 22
            ? String(title.prefix(21)) + "…"
            : title
        let payload = LiveActivityCoordinator.Resolved(
            id: id,
            compactLeadingImage:
                LiveActivityCoordinator.symbolImage("calendar"),
            compactTrailingText: "\(truncated) · \(detail)",
            compactTrailingImage: nil,
            tint: .white,
            priority: priority)
        coordinator?.inject(payload)
    }

    private func format(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h\(m)m"
    }
}
