import Foundation
import XCTest
@testable import ImpulsCore

@MainActor
final class MobileDeviceBatteryProviderTests: XCTestCase {
    func testTopologyChangeTriggersOneFreshReadAndStopClosesMonitoring() async {
        let source = CountingMobileDeviceSource()
        let topology = FakeMobileDeviceTopologyMonitor()
        let provider = MobileDeviceBatteryProvider(
            source: source,
            topologyMonitor: topology,
            featureEnabled: { true }
        )
        var updates: [DeviceProviderUpdate] = []
        let initial = expectation(description: "initial read")
        let topologyRead = expectation(description: "topology read")

        provider.start { update in
            updates.append(update)
            if updates.count == 1 { initial.fulfill() }
            if updates.count == 2 { topologyRead.fulfill() }
        }
        await fulfillment(of: [initial], timeout: 2)

        topology.emitChange()
        await fulfillment(of: [topologyRead], timeout: 2)

        XCTAssertEqual(source.readCount, 2)
        XCTAssertEqual(updates.map(\.identifier), [.mobileDevice, .mobileDevice])
        XCTAssertEqual(updates.map(\.status), [.ready, .ready])

        provider.stop()
        XCTAssertTrue(topology.didStop)
        XCTAssertEqual(provider.status, .disabled)
    }

    func testDisabledFlagNeverStartsTopologyOrReadsTheSocketSource() async {
        let source = CountingMobileDeviceSource()
        let topology = FakeMobileDeviceTopologyMonitor()
        let provider = MobileDeviceBatteryProvider(
            source: source,
            topologyMonitor: topology,
            featureEnabled: { false }
        )
        let update = expectation(description: "disabled update")
        var received: DeviceProviderUpdate?

        provider.start {
            received = $0
            update.fulfill()
        }
        await fulfillment(of: [update], timeout: 2)

        XCTAssertEqual(received?.identifier, .mobileDevice)
        XCTAssertEqual(received?.status, .unavailable)
        XCTAssertEqual(source.readCount, 0)
        XCTAssertFalse(topology.didStart)
        provider.stop()
    }

    /// The 1.4.8 regression, pinned.
    ///
    /// Until 1.4.8 the production default for `featureEnabled` was an
    /// environment variable and an undocumented `UserDefaults` key. Neither is
    /// set on any ordinary install, so every shipped Impuls started this
    /// provider and it returned `.unavailable` before opening a socket — the
    /// phone was never looked for, while AirPods, which come from another
    /// provider, kept working. The test process has neither flag set, which is
    /// the point: build the provider the way `DevicePowerCenter` builds it and
    /// it must do real work.
    func testTheProviderWorksWithNoEnvironmentVariableAndNoHiddenDefault() async {
        XCTAssertNil(ProcessInfo.processInfo.environment["IMPULS_MOBILE_DEVICE_BATTERY"])
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "experimentalMobileDeviceBattery"))

        let source = CountingMobileDeviceSource()
        let topology = FakeMobileDeviceTopologyMonitor()
        // No `featureEnabled:` — exactly the production construction.
        let provider = MobileDeviceBatteryProvider(source: source, topologyMonitor: topology)
        let update = expectation(description: "ready update")
        var received: DeviceProviderUpdate?

        provider.start {
            received = $0
            update.fulfill()
        }
        await fulfillment(of: [update], timeout: 2)

        XCTAssertEqual(received?.status, .ready)
        XCTAssertTrue(topology.didStart, "the topology listener must open once the user has opted in")
        XCTAssertEqual(source.readCount, 1)
        provider.stop()
    }

    /// A locked-but-trusted phone is a different sentence from "not trusted at
    /// all", and the last reading it gave us is still worth keeping — this is
    /// what makes `DevicePowerCenter` able to show it as Last Known rather than
    /// dropping the card.
    func testALockedDeviceReportsDistinctlyAndKeepsItsLastReading() async {
        let reading = Fixtures.device(
            kind: .iPhone,
            name: "iPhone",
            connection: .usb,
            components: [DeviceBatteryComponent(kind: .primary, percentage: 74, lastUpdated: Fixtures.noon)],
            source: .mobileUSB
        )
        let source = ScriptedMobileDeviceSource(results: [.success([reading]), .failure(MobileDeviceError.deviceLocked)])
        let topology = FakeMobileDeviceTopologyMonitor()
        let provider = MobileDeviceBatteryProvider(source: source, topologyMonitor: topology, featureEnabled: { true })

        var updates: [DeviceProviderUpdate] = []
        let firstReady = expectation(description: "first read ready")
        provider.start { update in
            updates.append(update)
            if update.status == .ready { firstReady.fulfill() }
        }
        await fulfillment(of: [firstReady], timeout: 2)

        provider.refresh()
        for _ in 0..<200 where updates.last?.status != .deviceLocked {
            await Task.yield()
        }

        XCTAssertEqual(provider.status, .deviceLocked)
        XCTAssertNotEqual(provider.status, .permissionRequired, "locked and not-trusted are different sentences")
        XCTAssertEqual(
            updates.last?.devices.first?.headlinePercentage,
            74,
            "a locked phone's last known reading is not thrown away"
        )
    }

    /// The disconnect-during-read race: a stale in-flight read must not
    /// resurrect a device that has since disappeared, even if it resolves
    /// after a fresh read has already started.
    func testATopologyChangeDuringAnInFlightReadDiscardsTheStaleResult() async {
        let source = GatedMobileDeviceSource()
        let topology = FakeMobileDeviceTopologyMonitor()
        let provider = MobileDeviceBatteryProvider(source: source, topologyMonitor: topology, featureEnabled: { true })

        var updates: [DeviceProviderUpdate] = []
        var onEachUpdate: ((DeviceProviderUpdate) -> Void)?

        // Installed before `start()` so the provider's own first read — fired
        // from a freshly created Task, whose scheduling relative to this
        // actor call is not otherwise guaranteed — cannot race ahead of it.
        let firstReadStarted = expectation(description: "first (soon-to-be-stale) read started")
        await source.setOnReadStarted { firstReadStarted.fulfill() }
        provider.start { update in
            updates.append(update)
            onEachUpdate?(update)
        }
        await fulfillment(of: [firstReadStarted], timeout: 2)
        let readCountAfterFirst = await source.readCount
        XCTAssertEqual(readCountAfterFirst, 1)

        let secondReadStarted = expectation(description: "topology change starts a fresh read")
        await source.setOnReadStarted { secondReadStarted.fulfill() }
        topology.emitChange()
        await fulfillment(of: [secondReadStarted], timeout: 2)
        let readCountAfterSecond = await source.readCount
        XCTAssertEqual(
            readCountAfterSecond,
            2,
            "the stale in-flight read is cancelled and replaced, not queued behind"
        )

        let staleDevice = Fixtures.device(
            kind: .iPhone,
            name: "iPhone",
            connection: .usb,
            components: [DeviceBatteryComponent(kind: .primary, percentage: 11, lastUpdated: Fixtures.noon)],
            source: .mobileUSB
        )
        let freshDevice = Fixtures.device(
            kind: .iPhone,
            name: "iPhone",
            connection: .usb,
            components: [DeviceBatteryComponent(kind: .primary, percentage: 62, lastUpdated: Fixtures.noon)],
            source: .mobileUSB
        )

        // Resolve the stale (first) read now — the cancelled task must not
        // publish it, no matter how long it takes to come back.
        let staleNeverPublishes = expectation(description: "cancelled read never publishes")
        staleNeverPublishes.isInverted = true
        onEachUpdate = { update in
            if update.status == .ready, update.devices.first?.headlinePercentage == 11 {
                staleNeverPublishes.fulfill()
            }
        }
        await source.resumeOldest(with: [staleDevice])
        await fulfillment(of: [staleNeverPublishes], timeout: 0.3)

        // The fresh read, resolved second, is the one that gets to publish.
        let freshPublishes = expectation(description: "fresh read publishes")
        onEachUpdate = { update in
            if update.status == .ready, update.devices.first?.headlinePercentage == 62 {
                freshPublishes.fulfill()
            }
        }
        await source.resumeOldest(with: [freshDevice])
        await fulfillment(of: [freshPublishes], timeout: 2)
    }
}

private final actor GatedMobileDeviceSource: DeviceBatterySource {
    private var pendingContinuations: [CheckedContinuation<[AppleDeviceSnapshot], Never>] = []
    private(set) var readCount = 0
    private var onReadStarted: (@Sendable () -> Void)?

    func setOnReadStarted(_ callback: (@Sendable () -> Void)?) {
        onReadStarted = callback
    }

    func read() async throws -> [AppleDeviceSnapshot] {
        readCount += 1
        onReadStarted?()
        return await withCheckedContinuation { continuation in
            pendingContinuations.append(continuation)
        }
    }

    /// Resumes the oldest still-pending read — the order reads were started
    /// in, which lets a test control exactly which physical request each
    /// answer belongs to.
    func resumeOldest(with result: [AppleDeviceSnapshot]) {
        guard !pendingContinuations.isEmpty else { return }
        let continuation = pendingContinuations.removeFirst()
        continuation.resume(returning: result)
    }
}

private final class ScriptedMobileDeviceSource: DeviceBatterySource, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<[AppleDeviceSnapshot], Error>]

    init(results: [Result<[AppleDeviceSnapshot], Error>]) {
        self.results = results
    }

    func read() async throws -> [AppleDeviceSnapshot] {
        let next: Result<[AppleDeviceSnapshot], Error> = lock.withLock {
            results.isEmpty ? .success([]) : results.removeFirst()
        }
        return try next.get()
    }
}

private final class CountingMobileDeviceSource: DeviceBatterySource, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var readCount: Int { lock.withLock { count } }

    func read() async throws -> [AppleDeviceSnapshot] {
        lock.withLock { count += 1 }
        return []
    }
}

private final class FakeMobileDeviceTopologyMonitor: MobileDeviceTopologyMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    private var started = false
    private var stopped = false

    var didStart: Bool { lock.withLock { started } }
    var didStop: Bool { lock.withLock { stopped } }

    func start(onChange: @escaping @Sendable () -> Void) {
        lock.withLock {
            callback = onChange
            started = true
        }
    }

    func stop() {
        lock.withLock {
            callback = nil
            stopped = true
        }
    }

    func emitChange() {
        let callback = lock.withLock { self.callback }
        callback?()
    }
}
