import XCTest
@testable import ImpulsCore

@MainActor
final class VersionTelemetrySchedulerTests: XCTestCase {
    func testTickCallsTheInjectedAttemptExactlyOnce() async {
        let counter = Counter()
        let scheduler = VersionTelemetryScheduler(interval: 3_600) {
            await counter.increment()
        }
        await scheduler.tick()
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testStartIsIdempotentAndStopTearsDownTheTimer() {
        let scheduler = VersionTelemetryScheduler(interval: 3_600) {}
        XCTAssertFalse(scheduler.isRunning)
        scheduler.start()
        XCTAssertTrue(scheduler.isRunning)
        scheduler.start()
        XCTAssertTrue(scheduler.isRunning, "a second start() must not replace or duplicate the timer")
        scheduler.stop()
        XCTAssertFalse(scheduler.isRunning)
        scheduler.stop()
        XCTAssertFalse(scheduler.isRunning, "stop() is safe to call again")
    }

    /// The scheduler proposes attempts; `VersionTelemetryService` is still the
    /// only thing deciding whether a proposal becomes a network request. Firing
    /// several ticks back to back must therefore respect the same one-hour
    /// throttle a real relaunch would.
    func testRepeatedTicksDoNotExceedTheServicesOwnThrottlePolicy() async {
        let clock = TestSchedulerClock(Date(timeIntervalSince1970: 10_000))
        let recorder = SchedulerRequestRecorder()
        let suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let identifier = UUID(uuidString: "3E5DC194-6512-44BB-B24A-1C700DB39D90")!

        let service = VersionTelemetryService(
            defaults: defaults,
            endpoint: URL(string: "https://stats.example/v1/heartbeat"),
            appVersion: "1.4.14",
            installationID: { identifier },
            now: { clock.now() },
            sender: { request in try await recorder.send(request) }
        )
        service.setConsent(.allowed)

        let scheduler = VersionTelemetryScheduler(interval: 3_600) {
            _ = await service.sendHeartbeatIfNeeded()
        }

        await scheduler.tick()
        await scheduler.tick()
        await scheduler.tick()
        let countWithinTheHour = await recorder.count
        XCTAssertEqual(countWithinTheHour, 1, "three ticks inside the same hour must still send once")

        clock.advance(by: VersionTelemetryService.heartbeatInterval)
        await scheduler.tick()
        let countAfterAnHour = await recorder.count
        XCTAssertEqual(countAfterAnHour, 2)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private final class TestSchedulerClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private actor SchedulerRequestRecorder {
    private(set) var count = 0

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        count += 1
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 204,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (Data(), response)
    }
}
