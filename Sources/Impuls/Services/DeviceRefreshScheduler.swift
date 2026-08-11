import Foundation

/// Decides *when* providers are asked, so no provider has to invent a timetable.
///
/// The rules are the same ones the Power module already follows, generalised:
/// work happens when someone can see it, and a device that is not answering is
/// asked less often rather than more. An event-driven provider is never polled
/// at all — that is the whole reason the behaviour is declared rather than
/// assumed, and it is what keeps `PowerMonitor`'s existing lifecycle intact.
@MainActor
final class DeviceRefreshScheduler {
    /// A device that has stopped answering is not a device to hammer. The
    /// ceiling matters more than the curve: without one, a phone unplugged
    /// overnight is still being asked every thirty seconds in the morning.
    static let maximumBackoffInterval: TimeInterval = 10 * 60

    private struct Entry {
        let provider: DeviceBatteryProviding
        var failures: Int = 0
        var timer: Timer?
    }

    private var entries: [DeviceProviderIdentifier: Entry] = [:]
    private var isRunning = false
    private var isActive = false

    func setProviders(_ providers: [DeviceBatteryProviding]) {
        stop()
        entries = [:]
        for provider in providers {
            guard case .polled = provider.refreshBehavior else { continue }
            entries[provider.identifier] = Entry(provider: provider)
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        rescheduleAll()
    }

    func stop() {
        isRunning = false
        for identifier in entries.keys {
            entries[identifier]?.timer?.invalidate()
            entries[identifier]?.timer = nil
        }
    }

    /// The panel opened or closed. Cadence follows attention.
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        guard isRunning else { return }
        rescheduleAll()
    }

    /// Report whether the last read worked, so the back-off can grow or reset.
    func noteOutcome(for identifier: DeviceProviderIdentifier, succeeded: Bool) {
        guard var entry = entries[identifier] else { return }
        let previousFailures = entry.failures
        entry.failures = succeeded ? 0 : min(entry.failures + 1, 8)
        entries[identifier] = entry
        guard isRunning, entry.failures != previousFailures else { return }
        schedule(identifier)
    }

    /// The interval a provider is currently on, or `nil` when it is never
    /// polled. Exposed so the cadence can be asserted in tests without waiting
    /// for a timer to fire.
    func interval(for identifier: DeviceProviderIdentifier) -> TimeInterval? {
        guard let entry = entries[identifier],
              case .polled(let activeInterval, let idleInterval) = entry.provider.refreshBehavior else {
            return nil
        }
        let base = isActive ? activeInterval : idleInterval
        guard entry.failures > 0 else { return base }
        let backoff = base * pow(2, Double(entry.failures))
        return min(backoff, Self.maximumBackoffInterval)
    }

    private func rescheduleAll() {
        for identifier in entries.keys { schedule(identifier) }
    }

    private func schedule(_ identifier: DeviceProviderIdentifier) {
        guard var entry = entries[identifier], let interval = interval(for: identifier) else { return }
        entry.timer?.invalidate()
        guard isRunning else {
            entry.timer = nil
            entries[identifier] = entry
            return
        }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.entries[identifier]?.provider.refresh()
            }
        }
        // Generous, on purpose: these reads are never urgent, and letting the
        // system coalesce them is most of the difference between a background
        // utility and one that shows up in Activity Monitor.
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        entry.timer = timer
        entries[identifier] = entry
    }
}
