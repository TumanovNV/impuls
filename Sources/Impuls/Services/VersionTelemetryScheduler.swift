import Foundation

/// Proposes a version-heartbeat attempt roughly once an hour while Impuls runs.
///
/// `AppDelegate` used to call `VersionTelemetryService.sendHeartbeatIfNeeded()`
/// exactly once, ~2 seconds after launch. A Mac that stays awake for days then
/// only ever reports the version it had at that first attempt: an update that
/// lands mid-session (or a throttled first attempt right after an update) never
/// gets a second chance until the next full relaunch. This scheduler exists only
/// to keep proposing attempts on a bounded cadence; `VersionTelemetryService`
/// remains the sole owner of consent, endpoint and throttle policy, so a
/// proposal that is not due yet is simply a no-op there.
@MainActor
final class VersionTelemetryScheduler {
    private let interval: TimeInterval
    private let attempt: @MainActor () async -> Void
    private var timer: Timer?

    init(
        interval: TimeInterval = VersionTelemetryService.heartbeatInterval,
        attempt: @escaping @MainActor () async -> Void
    ) {
        self.interval = interval
        self.attempt = attempt
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.tick() }
        }
        // Same reasoning as the other background-utility timers in this app:
        // this attempt is never urgent, so macOS is free to coalesce the wake.
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The timer callback's body, exposed so tests can simulate a fired tick
    /// without waiting on a real `Timer`/`RunLoop`.
    func tick() async {
        await attempt()
    }
}
