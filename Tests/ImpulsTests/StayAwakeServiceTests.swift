import XCTest
@testable import ImpulsCore

/// The manual Stay Awake mode: activation, timed expiry, the display option,
/// shutdown and the absence of any restored state.
///
/// Every case runs against `FakePowerAssertionDriver`, an injected monotonic
/// clock and an injected expiry scheduler. Nothing here creates a real IOKit
/// assertion and nothing here waits out a real deadline.
@MainActor
final class StayAwakeServiceTests: XCTestCase {

    // MARK: - Activation

    func testTurningOnTakesExactlyOneSystemLeaseAndLeavesTheDisplayAlone() {
        let harness = Harness()

        harness.service.turnOn(for: .thirtyMinutes)

        XCTAssertTrue(harness.service.isActive)
        XCTAssertFalse(harness.service.keepsDisplayAwake)
        XCTAssertNil(harness.service.failure)
        XCTAssertEqual(harness.driver.createLog, [.systemIdleSleep])
        XCTAssertEqual(harness.registry.heldRequirements, [.systemIdleSleep])
        XCTAssertEqual(harness.registry.leaseCount, 1)
    }

    func testTurningOffReleasesTheLeaseAndTheAssertion() {
        let harness = Harness()

        harness.service.turnOn(for: .oneHour)
        harness.service.turnOff()

        XCTAssertFalse(harness.service.isActive)
        XCTAssertEqual(harness.registry.leaseCount, 0)
        XCTAssertEqual(harness.registry.heldRequirements, [])
        XCTAssertEqual(harness.driver.releaseLog.count, 1)
        XCTAssertEqual(harness.driver.doubleReleases, 0)
    }

    func testTurningOffTwiceIsSafe() {
        let harness = Harness()

        harness.service.turnOn(for: .oneHour)
        harness.service.turnOff()
        harness.service.turnOff()

        XCTAssertEqual(harness.driver.releaseLog.count, 1)
        XCTAssertEqual(harness.driver.doubleReleases, 0)
    }

    func testACreationFailureNeverReportsAnActiveMode() {
        let harness = Harness()
        harness.driver.failingRequirements = [.systemIdleSleep]

        harness.service.turnOn(for: .thirtyMinutes)

        XCTAssertFalse(harness.service.isActive, "the interface must not claim a mode the system refused")
        XCTAssertEqual(harness.service.failure, .couldNotTurnOn)
        XCTAssertEqual(harness.registry.leaseCount, 0)
        XCTAssertEqual(harness.registry.heldRequirements, [])
        XCTAssertNil(harness.scheduler.pendingInterval, "a mode that never started schedules no expiry")
    }

    func testTheNextDeliberateActionClearsAPreviousFailure() {
        let harness = Harness()
        harness.driver.failingRequirements = [.systemIdleSleep]
        harness.service.turnOn(for: .thirtyMinutes)
        XCTAssertEqual(harness.service.failure, .couldNotTurnOn)

        harness.driver.failingRequirements = []
        harness.service.turnOn(for: .thirtyMinutes)

        XCTAssertNil(harness.service.failure)
        XCTAssertTrue(harness.service.isActive)
    }

    // MARK: - Keep Display Awake

    func testTheDisplayOptionAddsAndRemovesOnlyTheDisplayAssertion() {
        let harness = Harness()
        harness.service.turnOn(for: .untilTurnedOff)
        let systemIdentifier = harness.driver.identifier(for: .systemIdleSleep)

        harness.service.setKeepsDisplayAwake(true)

        XCTAssertTrue(harness.service.keepsDisplayAwake)
        XCTAssertEqual(harness.registry.heldRequirements, [.systemIdleSleep, .displayIdleSleep])
        XCTAssertEqual(harness.driver.createLog, [.systemIdleSleep, .displayIdleSleep])
        XCTAssertEqual(harness.driver.identifier(for: .systemIdleSleep), systemIdentifier)

        harness.service.setKeepsDisplayAwake(false)

        XCTAssertFalse(harness.service.keepsDisplayAwake)
        XCTAssertEqual(harness.registry.heldRequirements, [.systemIdleSleep])
        XCTAssertEqual(harness.driver.releaseLog.map(\.requirement), [.displayIdleSleep])
        XCTAssertEqual(harness.driver.identifier(for: .systemIdleSleep), systemIdentifier,
                       "toggling the display must not re-create the system assertion")
    }

    func testADisplayFailureKeepsTheWorkingSystemAssertionAndReportsNothingFalse() {
        let harness = Harness()
        harness.service.turnOn(for: .twoHours)
        let systemIdentifier = harness.driver.identifier(for: .systemIdleSleep)

        harness.driver.failingRequirements = [.displayIdleSleep]
        harness.service.setKeepsDisplayAwake(true)

        XCTAssertFalse(harness.service.keepsDisplayAwake)
        XCTAssertEqual(harness.service.failure, .couldNotKeepDisplayAwake)
        XCTAssertTrue(harness.service.isActive, "the mode itself is unaffected")
        XCTAssertEqual(harness.registry.heldRequirements, [.systemIdleSleep])
        XCTAssertEqual(harness.driver.identifier(for: .systemIdleSleep), systemIdentifier)
        XCTAssertTrue(harness.driver.releaseLog.isEmpty)
    }

    func testTheDisplayOptionDoesNothingWhileTheModeIsOff() {
        let harness = Harness()

        harness.service.setKeepsDisplayAwake(true)

        XCTAssertFalse(harness.service.keepsDisplayAwake)
        XCTAssertEqual(harness.registry.heldRequirements, [])
        XCTAssertTrue(harness.driver.createLog.isEmpty)
    }

    func testEveryActivationStartsWithTheDisplayOptionOff() {
        let harness = Harness()

        harness.service.turnOn(for: .untilTurnedOff)
        harness.service.setKeepsDisplayAwake(true)
        harness.service.turnOff()
        harness.service.turnOn(for: .untilTurnedOff)

        XCTAssertFalse(harness.service.keepsDisplayAwake)
        XCTAssertEqual(harness.registry.heldRequirements, [.systemIdleSleep])
    }

    // MARK: - Timed modes

    func testEachTimedDurationSchedulesItsOwnDeadline() {
        let expected: [StayAwakeDuration: TimeInterval] = [
            .thirtyMinutes: 1_800,
            .oneHour: 3_600,
            .twoHours: 7_200,
        ]
        for (duration, seconds) in expected {
            let harness = Harness()
            harness.service.turnOn(for: duration)
            XCTAssertEqual(harness.scheduler.pendingInterval ?? -1, seconds, accuracy: 0.01, "\(duration)")
            XCTAssertEqual(harness.service.remainingSeconds ?? -1, seconds, accuracy: 0.01, "\(duration)")
        }
    }

    func testUntilTurnedOffSchedulesNothingAtAll() {
        let harness = Harness()

        harness.service.turnOn(for: .untilTurnedOff)

        XCTAssertNil(harness.scheduler.pendingInterval)
        XCTAssertNil(harness.service.remainingSeconds)
        XCTAssertNil(harness.service.remainingMinutes)
        XCTAssertTrue(harness.service.isActive)
    }

    func testExpiryReleasesTheManualLeaseAndOnlyThat() throws {
        let harness = Harness()
        // A second owner, standing in for anything else that might hold a
        // claim. The manual deadline must not touch it.
        let other = try harness.registry.acquire([.systemIdleSleep, .displayIdleSleep])

        harness.service.turnOn(for: .thirtyMinutes)
        harness.clock.advance(by: 1_800)
        harness.scheduler.fire()

        XCTAssertFalse(harness.service.isActive)
        XCTAssertEqual(harness.registry.leaseCount, 1)
        XCTAssertEqual(harness.registry.requirements(for: other), [.systemIdleSleep, .displayIdleSleep])
        XCTAssertEqual(harness.registry.heldRequirements, [.systemIdleSleep, .displayIdleSleep])
    }

    func testChangingDurationReplacesTheDeadlineWithoutDuplicatingTheAssertion() {
        let harness = Harness()

        harness.service.turnOn(for: .thirtyMinutes)
        let identifier = harness.driver.identifier(for: .systemIdleSleep)
        harness.service.turnOn(for: .twoHours)

        XCTAssertEqual(harness.service.duration, .twoHours)
        XCTAssertEqual(harness.driver.createLog, [.systemIdleSleep], "no second physical assertion")
        XCTAssertEqual(harness.driver.identifier(for: .systemIdleSleep), identifier)
        XCTAssertEqual(harness.scheduler.pendingInterval ?? -1, 7_200, accuracy: 0.01)
        XCTAssertEqual(harness.registry.leaseCount, 1)
    }

    func testAStaleExpiryCannotEndTheModeThatReplacedIt() throws {
        let harness = Harness()

        harness.service.turnOn(for: .thirtyMinutes)
        // The callback the thirty-minute mode scheduled, kept the way the main
        // queue keeps one that is already on its way.
        let staleCallback = try XCTUnwrap(harness.scheduler.pendingBody)

        harness.service.turnOn(for: .twoHours)
        harness.clock.advance(by: 1_800)
        staleCallback()

        XCTAssertTrue(harness.service.isActive, "the older deadline must not end the newer mode")
        XCTAssertEqual(harness.service.duration, .twoHours)
        XCTAssertEqual(harness.registry.heldRequirements, [.systemIdleSleep])
    }

    func testAStaleExpiryCannotReviveOrDisturbAModeTurnedOffByHand() throws {
        let harness = Harness()

        harness.service.turnOn(for: .thirtyMinutes)
        let staleCallback = try XCTUnwrap(harness.scheduler.pendingBody)
        harness.service.turnOff()
        harness.driver.reset()

        harness.clock.advance(by: 1_800)
        staleCallback()

        XCTAssertFalse(harness.service.isActive)
        XCTAssertTrue(harness.driver.releaseLog.isEmpty)
        XCTAssertEqual(harness.driver.doubleReleases, 0)
    }

    func testTurningOffCancelsThePendingExpiry() {
        let harness = Harness()

        harness.service.turnOn(for: .thirtyMinutes)
        let scheduledOnce = harness.scheduler.scheduleCount
        harness.service.turnOff()

        XCTAssertNil(harness.scheduler.pendingInterval)
        XCTAssertNil(harness.scheduler.pendingBody)
        XCTAssertEqual(harness.scheduler.scheduleCount, scheduledOnce, "turning off schedules nothing new")
    }

    func testAWakeUpBeforeTheMonotonicDeadlineReArmsInsteadOfEndingTheModeEarly() {
        let harness = Harness()

        harness.service.turnOn(for: .oneHour)
        // The scheduler fires having measured less real time than the clock —
        // what a dispatch deadline does across a lid-close sleep.
        harness.clock.advance(by: 2_400)
        harness.scheduler.fire()

        XCTAssertTrue(harness.service.isActive)
        XCTAssertEqual(harness.scheduler.pendingInterval ?? -1, 1_200, accuracy: 0.01)

        harness.clock.advance(by: 1_200)
        harness.scheduler.fire()

        XCTAssertFalse(harness.service.isActive)
    }

    func testRemainingMinutesRoundUpSoARunningModeNeverReadsAsZero() {
        let harness = Harness()

        harness.service.turnOn(for: .thirtyMinutes)
        XCTAssertEqual(harness.service.remainingMinutes, 30)

        harness.clock.advance(by: 200)
        XCTAssertEqual(harness.service.remainingMinutes, 27)

        harness.clock.advance(by: 1_599)
        XCTAssertEqual(harness.service.remainingMinutes, 1)
    }

    // MARK: - Shutdown and relaunch

    func testShutdownReleasesEverythingCancelsExpiryAndIsIdempotent() {
        let harness = Harness()
        harness.service.turnOn(for: .thirtyMinutes)
        harness.service.setKeepsDisplayAwake(true)
        XCTAssertEqual(harness.registry.heldRequirements, [.systemIdleSleep, .displayIdleSleep])

        harness.service.shutdown()
        harness.service.shutdown()

        XCTAssertFalse(harness.service.isActive)
        XCTAssertFalse(harness.service.keepsDisplayAwake)
        XCTAssertEqual(harness.registry.leaseCount, 0)
        XCTAssertEqual(harness.registry.heldRequirements, [])
        XCTAssertEqual(harness.driver.releaseLog.count, 2)
        XCTAssertEqual(harness.driver.doubleReleases, 0)
        XCTAssertTrue(harness.driver.liveIdentifiers.isEmpty)
        XCTAssertNil(harness.scheduler.pendingInterval)
    }

    func testShutdownEmptiesTheRegistryIncludingClaimsItDoesNotOwn() throws {
        let harness = Harness()
        try harness.registry.acquire([.displayIdleSleep])
        harness.service.turnOn(for: .untilTurnedOff)

        harness.service.shutdown()

        // The process is going away, so nothing it created should outlive it.
        XCTAssertEqual(harness.registry.leaseCount, 0)
        XCTAssertTrue(harness.driver.liveIdentifiers.isEmpty)
    }

    func testAFreshServiceIsOffBecauseNothingIsEverRestored() {
        let harness = Harness()
        harness.service.turnOn(for: .untilTurnedOff)
        harness.service.setKeepsDisplayAwake(true)
        harness.service.shutdown()

        // What a relaunch produces: a new service over a new registry, with no
        // persisted state anywhere for it to read.
        let relaunched = Harness()

        XCTAssertFalse(relaunched.service.isActive)
        XCTAssertFalse(relaunched.service.keepsDisplayAwake)
        XCTAssertEqual(relaunched.service.duration, .thirtyMinutes)
        XCTAssertEqual(relaunched.registry.heldRequirements, [])
        XCTAssertTrue(relaunched.driver.createLog.isEmpty, "launching creates no assertion on its own")
    }

    // MARK: - Architectural seams

    /// The suite must not be able to keep the machine running it awake.
    ///
    /// `WakeLeaseRegistry` has no default driver, so a test cannot reach IOKit
    /// by omission — it would not compile. This covers the remaining case: a
    /// test that names the real driver on purpose. The scan is over this
    /// directory's own sources, which is where such a line would have to be.
    func testNoTestSourceConstructsTheRealIOKitDriver() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(names.isEmpty, "the test sources must be readable for this guard to mean anything")

        // This file is skipped because it is the one that has to spell the
        // forbidden names out in order to look for them.
        let selfName = URL(fileURLWithPath: #filePath).lastPathComponent
        let forbidden = ["IOKitPowerAssertionDriver(", "IOPMAssertionCreate"]
        for name in names where name != selfName {
            let source = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            for needle in forbidden where source.contains(needle) {
                XCTFail("\(name) reaches the real power-assertion backend (\(needle))")
            }
        }
    }

    // MARK: - Application wiring

    /// Power Center is the only surface that can turn the mode off, so
    /// disabling the module has to end it. Without this the person would be
    /// left with a Mac held awake and no control anywhere in the app to stop
    /// it — the hidden lease this feature is not allowed to have.
    func testDisablingThePowerModuleTurnsTheModeOff() throws {
        let harness = Harness()
        let world = try ViewModelWorld(stayAwake: harness.service)
        defer { world.tearDown() }

        harness.service.turnOn(for: .untilTurnedOff)
        harness.service.setKeepsDisplayAwake(true)
        XCTAssertEqual(harness.registry.heldRequirements, [.systemIdleSleep, .displayIdleSleep])

        world.settings.setModule(.power, enabled: false)

        XCTAssertFalse(world.viewModel.stayAwake.isActive)
        XCTAssertEqual(harness.registry.heldRequirements, [])
        XCTAssertEqual(harness.driver.doubleReleases, 0)
    }

    /// `NotchViewModel.stop()` is what `NotchController.teardown()` calls from
    /// `applicationWillTerminate`. Normal termination releases explicitly
    /// rather than leaving it to macOS to reap the assertion.
    func testStoppingTheViewModelReleasesEverythingTheModeHeld() throws {
        let harness = Harness()
        let world = try ViewModelWorld(stayAwake: harness.service)
        defer { world.tearDown() }

        harness.service.turnOn(for: .twoHours)
        harness.service.setKeepsDisplayAwake(true)

        world.viewModel.stop()

        XCTAssertFalse(harness.service.isActive)
        XCTAssertEqual(harness.registry.leaseCount, 0)
        XCTAssertTrue(harness.driver.liveIdentifiers.isEmpty)
        XCTAssertNil(harness.scheduler.pendingInterval, "termination also cancels the pending deadline")
    }

    /// Starting the app never turns the mode on by itself.
    func testStartingTheViewModelActivatesNothing() throws {
        let harness = Harness()
        let world = try ViewModelWorld(stayAwake: harness.service)
        defer { world.tearDown() }

        world.viewModel.start()

        XCTAssertFalse(harness.service.isActive)
        XCTAssertTrue(harness.driver.createLog.isEmpty)

        world.viewModel.stop()
    }

    func testEveryDurationHasATitleAndOnlyTheOpenEndedOneHasNoDeadline() {
        for duration in StayAwakeDuration.allCases {
            XCTAssertFalse(duration.title.isEmpty)
        }
        XCTAssertNil(StayAwakeDuration.untilTurnedOff.seconds)
        XCTAssertEqual(StayAwakeDuration.allCases.compactMap(\.seconds), [1_800, 3_600, 7_200])
    }
}

// MARK: - Harness

@MainActor
private struct Harness {
    let driver: FakePowerAssertionDriver
    let clock: AdvanceableStayAwakeClock
    let scheduler: RecordingExpiryScheduler
    let registry: WakeLeaseRegistry
    let service: StayAwakeService

    init() {
        let driver = FakePowerAssertionDriver()
        let clock = AdvanceableStayAwakeClock()
        let scheduler = RecordingExpiryScheduler()
        let registry = WakeLeaseRegistry(driver: driver)
        self.driver = driver
        self.clock = clock
        self.scheduler = scheduler
        self.registry = registry
        self.service = StayAwakeService(leases: registry, clock: clock, scheduler: scheduler)
    }
}

/// A monotonic clock the test moves itself, so a two-hour deadline is two
/// statements rather than two hours.
private final class AdvanceableStayAwakeClock: StayAwakeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    var now: ContinuousClock.Instant {
        lock.withLock { instant }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { instant = instant.advanced(by: .seconds(seconds)) }
    }
}

/// Holds at most one scheduled item, exactly as the production scheduler does,
/// and lets a test fire it — or keep a superseded one and deliver it late.
@MainActor
private final class RecordingExpiryScheduler: StayAwakeExpiryScheduling {
    private(set) var pendingInterval: TimeInterval?
    private(set) var pendingBody: (@MainActor () -> Void)?
    private(set) var scheduleCount = 0
    private(set) var cancelCount = 0

    func schedule(after interval: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        cancel()
        scheduleCount += 1
        pendingInterval = interval
        pendingBody = body
    }

    func cancel() {
        cancelCount += 1
        pendingInterval = nil
        pendingBody = nil
    }

    func fire() {
        let body = pendingBody
        pendingInterval = nil
        pendingBody = nil
        body?()
    }
}

/// A `NotchViewModel` over an isolated defaults suite and a temporary
/// directory, with the Stay Awake service injected so the wiring can be
/// exercised without a real power assertion.
@MainActor
private struct ViewModelWorld {
    let settings: SettingsStore
    let viewModel: NotchViewModel
    private let folder: URL
    private let suite: String

    init(stayAwake: StayAwakeService) throws {
        suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("impuls-stay-awake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // The real alert service reaches macOS Notification Center, which
        // aborts outside an app bundle — the display harness stubs it for the
        // same reason.
        settings = SettingsStore(
            defaults: defaults,
            lowBatteryAlerts: LowBatteryAlertService(
                engine: LowBatteryAlertEngine(store: MemoryDisplayAlertStore(), now: Date()),
                delivery: SilentDisplayAlertDelivery()
            )
        )
        viewModel = NotchViewModel(
            settings: settings,
            storage: StorageEnvironment(
                notes: folder.appendingPathComponent("notes.json"),
                snippets: folder.appendingPathComponent("snippets.json"),
                makeClipboardHistory: { nil }
            ),
            stayAwake: stayAwake
        )
    }

    func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
}
