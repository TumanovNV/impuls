import XCTest
@testable import ImpulsCore

/// Aggregation, ownership and rollback for the physical power assertions.
///
/// Every case here runs against `FakePowerAssertionDriver`. No test in this
/// file — or anywhere in this suite — creates a real IOKit assertion, so
/// running the suite cannot keep a developer's Mac or a CI runner awake.
/// `StayAwakeServiceTests.testNoTestSourceConstructsTheRealIOKitDriver` is the
/// guard that keeps it that way.
@MainActor
final class WakeLeaseRegistryTests: XCTestCase {

    // MARK: - Aggregation

    func testFirstSystemLeaseCreatesExactlyOneSystemAssertion() throws {
        let driver = FakePowerAssertionDriver()
        let registry = WakeLeaseRegistry(driver: driver)

        try registry.acquire([.systemIdleSleep])

        XCTAssertEqual(driver.createLog, [.systemIdleSleep])
        XCTAssertEqual(driver.liveCount(for: .systemIdleSleep), 1)
        XCTAssertTrue(registry.holdsAssertion(for: .systemIdleSleep))
        XCTAssertFalse(registry.holdsAssertion(for: .displayIdleSleep))
    }

    func testSecondSystemLeaseCreatesNoSecondPhysicalAssertion() throws {
        let driver = FakePowerAssertionDriver()
        let registry = WakeLeaseRegistry(driver: driver)

        try registry.acquire([.systemIdleSleep])
        try registry.acquire([.systemIdleSleep])

        XCTAssertEqual(registry.leaseCount, 2)
        XCTAssertEqual(driver.createLog, [.systemIdleSleep])
        XCTAssertEqual(driver.liveCount(for: .systemIdleSleep), 1)
    }

    func testReleasingOneOfTwoSystemLeasesKeepsTheAssertion() throws {
        let driver = FakePowerAssertionDriver()
        let registry = WakeLeaseRegistry(driver: driver)

        let first = try registry.acquire([.systemIdleSleep])
        try registry.acquire([.systemIdleSleep])

        registry.release(first)

        XCTAssertEqual(registry.leaseCount, 1)
        XCTAssertTrue(registry.holdsAssertion(for: .systemIdleSleep))
        XCTAssertTrue(driver.releaseLog.isEmpty)
    }

    func testReleasingTheLastLeaseReleasesTheAssertionExactlyOnce() throws {
        let driver = FakePowerAssertionDriver()
        let registry = WakeLeaseRegistry(driver: driver)

        let first = try registry.acquire([.systemIdleSleep])
        let second = try registry.acquire([.systemIdleSleep])

        registry.release(first)
        registry.release(second)

        XCTAssertEqual(driver.releaseLog.count, 1)
        XCTAssertEqual(driver.releaseLog.first?.requirement, .systemIdleSleep)
        XCTAssertFalse(registry.holdsAssertion(for: .systemIdleSleep))
        XCTAssertTrue(driver.liveIdentifiers.isEmpty)
        XCTAssertEqual(driver.doubleReleases, 0)
    }

    func testDisplayLeaseCreatesAnIndependentDisplayAssertion() throws {
        let driver = FakePowerAssertionDriver()
        let registry = WakeLeaseRegistry(driver: driver)

        try registry.acquire([.displayIdleSleep])

        XCTAssertEqual(driver.createLog, [.displayIdleSleep])
        XCTAssertTrue(registry.holdsAssertion(for: .displayIdleSleep))
        XCTAssertFalse(registry.holdsAssertion(for: .systemIdleSleep))
    }

    func testSystemAndDisplayAggregateIndependently() throws {
        let driver = FakePowerAssertionDriver()
        let registry = WakeLeaseRegistry(driver: driver)

        let system = try registry.acquire([.systemIdleSleep])
        let both = try registry.acquire([.systemIdleSleep, .displayIdleSleep])

        XCTAssertEqual(driver.createLog, [.systemIdleSleep, .displayIdleSleep])
        XCTAssertEqual(driver.liveCount(for: .systemIdleSleep), 1)
        XCTAssertEqual(driver.liveCount(for: .displayIdleSleep), 1)

        // Dropping the lease that wanted the display drops the display
        // assertion and nothing else.
        registry.release(both)
        XCTAssertTrue(registry.holdsAssertion(for: .systemIdleSleep))
        XCTAssertFalse(registry.holdsAssertion(for: .displayIdleSleep))
        XCTAssertEqual(driver.releaseLog.map(\.requirement), [.displayIdleSleep])

        registry.release(system)
        XCTAssertEqual(registry.heldRequirements, [])
    }

    func testDroppingTheDisplayRequirementLeavesTheSystemAssertionUntouched() throws {
        let driver = FakePowerAssertionDriver()
        let registry = WakeLeaseRegistry(driver: driver)

        let token = try registry.acquire([.systemIdleSleep, .displayIdleSleep])
        let systemIdentifier = driver.identifier(for: .systemIdleSleep)

        try registry.update(token, to: [.systemIdleSleep])

        XCTAssertEqual(driver.releaseLog.map(\.requirement), [.displayIdleSleep])
        XCTAssertTrue(registry.holdsAssertion(for: .systemIdleSleep))
        // Same physical assertion, not a re-created one: the person must not
        // get an instant in which the Mac is allowed to sleep again.
        XCTAssertEqual(driver.identifier(for: .systemIdleSleep), systemIdentifier)
        XCTAssertEqual(driver.createLog, [.systemIdleSleep, .displayIdleSleep])
    }

    // MARK: - Tokens

    func testTokensAreUniqueAcrossAcquisitionsAndReleases() throws {
        let driver = FakePowerAssertionDriver()
        let registry = WakeLeaseRegistry(driver: driver)

        let first = try registry.acquire([.systemIdleSleep])
        let second = try registry.acquire([.systemIdleSleep])
        registry.release(first)
        let third = try registry.acquire([.systemIdleSleep])

        XCTAssertEqual(Set([first, second, third]).count, 3)
    }

    func testOneOwnerCannotReleaseAnotherOwnersClaim() throws {
        let driver = FakePowerAssertionDriver()
        let registry = WakeLeaseRegistry(driver: driver)

        let mine = try registry.acquire([.systemIdleSleep])
        let theirs = try registry.acquire([.systemIdleSleep, .displayIdleSleep])

        registry.release(mine)

        // Their claim, and both of the assertions it needs, are untouched.
        XCTAssertEqual(registry.requirements(for: theirs), [.systemIdleSleep, .displayIdleSleep])
        XCTAssertEqual(registry.heldRequirements, [.systemIdleSleep, .displayIdleSleep])
        XCTAssertTrue(driver.releaseLog.isEmpty)
    }

    func testReleasingAnAlreadyReleasedOrUnknownTokenIsSafe() throws {
        let driver = FakePowerAssertionDriver()
        let registry = WakeLeaseRegistry(driver: driver)
        let other = WakeLeaseRegistry(driver: FakePowerAssertionDriver())

        let token = try registry.acquire([.systemIdleSleep])
        let foreign = try other.acquire([.systemIdleSleep])

        registry.release(token)
        registry.release(token)
        registry.release(token)
        // A token minted by a different registry is simply not one of ours.
        registry.release(foreign)

        XCTAssertEqual(driver.releaseLog.count, 1)
        XCTAssertEqual(driver.doubleReleases, 0)
        XCTAssertEqual(registry.leaseCount, 0)
    }

    func testUpdatingAnUnknownTokenChangesNothing() throws {
        let driver = FakePowerAssertionDriver()
        let registry = WakeLeaseRegistry(driver: driver)

        let token = try registry.acquire([.systemIdleSleep])
        registry.release(token)
        driver.reset()

        try registry.update(token, to: [.systemIdleSleep, .displayIdleSleep])

        XCTAssertTrue(driver.createLog.isEmpty)
        XCTAssertEqual(registry.heldRequirements, [])
    }

    // MARK: - Failures and rollback

    func testSystemCreationFailureLeavesNoLeaseAndNoAssertion() {
        let driver = FakePowerAssertionDriver()
        driver.failingRequirements = [.systemIdleSleep]
        let registry = WakeLeaseRegistry(driver: driver)

        XCTAssertThrowsError(try registry.acquire([.systemIdleSleep]))

        XCTAssertEqual(registry.leaseCount, 0)
        XCTAssertEqual(registry.heldRequirements, [])
        XCTAssertTrue(driver.liveIdentifiers.isEmpty)
    }

    func testPartialCreationIsRolledBackAndLeavesNoOrphanAssertion() {
        let driver = FakePowerAssertionDriver()
        // The system assertion succeeds, the display one does not — the exact
        // shape a partially completed acquisition takes.
        driver.failingRequirements = [.displayIdleSleep]
        let registry = WakeLeaseRegistry(driver: driver)

        XCTAssertThrowsError(try registry.acquire([.systemIdleSleep, .displayIdleSleep]))

        XCTAssertEqual(driver.createLog, [.systemIdleSleep, .displayIdleSleep])
        XCTAssertEqual(driver.releaseLog.map(\.requirement), [.systemIdleSleep])
        XCTAssertTrue(driver.liveIdentifiers.isEmpty, "a rolled-back acquisition must leave no live assertion")
        XCTAssertEqual(registry.leaseCount, 0)
        XCTAssertEqual(registry.heldRequirements, [])
    }

    func testAnExistingAssertionSurvivesAnUnrelatedCreationFailure() throws {
        let driver = FakePowerAssertionDriver()
        let registry = WakeLeaseRegistry(driver: driver)

        let token = try registry.acquire([.systemIdleSleep])
        let systemIdentifier = driver.identifier(for: .systemIdleSleep)

        driver.failingRequirements = [.displayIdleSleep]
        XCTAssertThrowsError(try registry.update(token, to: [.systemIdleSleep, .displayIdleSleep]))

        // The working system assertion is the same one, still live, and the
        // lease still says exactly what it said before.
        XCTAssertEqual(driver.identifier(for: .systemIdleSleep), systemIdentifier)
        XCTAssertEqual(registry.heldRequirements, [.systemIdleSleep])
        XCTAssertEqual(registry.requirements(for: token), [.systemIdleSleep])
        XCTAssertTrue(driver.releaseLog.isEmpty)
    }

    func testReleaseAllDropsEveryLeaseAndAssertionAndIsIdempotent() throws {
        let driver = FakePowerAssertionDriver()
        let registry = WakeLeaseRegistry(driver: driver)

        try registry.acquire([.systemIdleSleep])
        try registry.acquire([.systemIdleSleep, .displayIdleSleep])

        registry.releaseAll()
        registry.releaseAll()

        XCTAssertEqual(registry.leaseCount, 0)
        XCTAssertEqual(registry.heldRequirements, [])
        XCTAssertEqual(driver.releaseLog.count, 2)
        XCTAssertEqual(driver.doubleReleases, 0)
        XCTAssertTrue(driver.liveIdentifiers.isEmpty)
    }

    // MARK: - Assertion naming

    func testAssertionsCarryTheDiagnosticNameAndNothingElse() throws {
        let driver = FakePowerAssertionDriver()
        let registry = WakeLeaseRegistry(driver: driver)

        try registry.acquire([.systemIdleSleep, .displayIdleSleep])

        XCTAssertEqual(driver.names, [PowerAssertionName.stayAwake])
        XCTAssertEqual(PowerAssertionName.stayAwake, "Impuls — Stay Awake")
    }

    func testRequirementsMapToThePublicIOKitAssertionTypes() {
        XCTAssertEqual(
            WakeRequirement.systemIdleSleep.ioKitAssertionType,
            "PreventUserIdleSystemSleep"
        )
        XCTAssertEqual(
            WakeRequirement.displayIdleSleep.ioKitAssertionType,
            "PreventUserIdleDisplaySleep"
        )
    }
}

/// Records what the registry asked macOS for, without asking macOS for it.
///
/// It tracks live identifiers rather than a boolean per requirement, so a
/// regression that created two assertions of the same kind, released one twice
/// or left one behind is visible as a count rather than having to be inferred.
@MainActor
final class FakePowerAssertionDriver: PowerAssertionDriving {
    private(set) var createLog: [WakeRequirement] = []
    private(set) var releaseLog: [PowerAssertionHandle] = []
    private(set) var liveIdentifiers: Set<UInt32> = []
    private(set) var names: Set<String> = []
    private(set) var doubleReleases = 0

    /// Requirements whose creation should fail, as macOS would if `powerd`
    /// refused the assertion.
    var failingRequirements: Set<WakeRequirement> = []

    /// Every live assertion of a kind, not just the latest. A registry bug that
    /// created a second system assertion would show up here as a count of two
    /// rather than silently overwriting the first.
    private var live: [WakeRequirement: [UInt32]] = [:]
    private var nextIdentifier: UInt32 = 1_000

    func createAssertion(for requirement: WakeRequirement, name: String) throws -> PowerAssertionHandle {
        createLog.append(requirement)
        guard !failingRequirements.contains(requirement) else {
            throw PowerAssertionFailure.creationFailed(requirement, status: -536_870_206)
        }
        names.insert(name)
        nextIdentifier += 1
        let handle = PowerAssertionHandle(requirement: requirement, rawIdentifier: nextIdentifier)
        liveIdentifiers.insert(nextIdentifier)
        live[requirement, default: []].append(nextIdentifier)
        return handle
    }

    func releaseAssertion(_ handle: PowerAssertionHandle) throws {
        releaseLog.append(handle)
        guard liveIdentifiers.remove(handle.rawIdentifier) != nil else {
            doubleReleases += 1
            throw PowerAssertionFailure.releaseFailed(handle, status: -536_870_206)
        }
        live[handle.requirement]?.removeAll { $0 == handle.rawIdentifier }
    }

    /// The one live identifier of this kind, or `nil` when there is none. Fails
    /// the calling test outright if there is more than one, because that is the
    /// aggregation rule being broken rather than a value to return.
    func identifier(for requirement: WakeRequirement) -> UInt32? {
        let identifiers = live[requirement] ?? []
        XCTAssertLessThanOrEqual(identifiers.count, 1, "more than one live \(requirement) assertion")
        return identifiers.first
    }

    func liveCount(for requirement: WakeRequirement) -> Int {
        live[requirement]?.count ?? 0
    }

    /// Clears the call history without touching what is live, so a test can
    /// assert about a single later step.
    func reset() {
        createLog = []
        releaseLog = []
    }
}
