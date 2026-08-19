import XCTest
@testable import ImpulsCore

final class LowBatteryAlertEngineTests: XCTestCase {
    func testWarningThresholdFiresOnce() {
        let harness = Harness()

        XCTAssertTrue(harness.evaluate(21).isEmpty)
        XCTAssertEqual(harness.evaluate(20).map(\.severity), [.warning])
        XCTAssertTrue(harness.evaluate(19).isEmpty)
    }

    func testCriticalThresholdFiresOnce() {
        let harness = Harness()

        XCTAssertEqual(harness.evaluate(11).map(\.severity), [.warning])
        XCTAssertEqual(harness.evaluate(10).map(\.severity), [.critical])
        XCTAssertTrue(harness.evaluate(9).isEmpty)
    }

    func testFirstObservationBelowWarningFiresWarningOnly() {
        let harness = Harness()

        let alerts = harness.evaluate(17)

        XCTAssertEqual(alerts.map(\.severity), [.warning])
    }

    func testFirstObservationBelowCriticalFiresCriticalOnly() {
        let harness = Harness()

        let alerts = harness.evaluate(8)

        XCTAssertEqual(alerts.map(\.severity), [.critical])
    }

    func testLargeJumpFiresCriticalOnly() {
        let harness = Harness()

        XCTAssertTrue(harness.evaluate(21).isEmpty)
        XCTAssertEqual(harness.evaluate(8).map(\.severity), [.critical])
    }

    func testChargingSuppressesAndUnpluggingAtNineFiresCritical() {
        let harness = Harness()

        XCTAssertTrue(harness.evaluate(9, charging: .charging).isEmpty)
        XCTAssertEqual(harness.evaluate(9, charging: .discharging).map(\.severity), [.critical])
    }

    func testUnknownChargingAllowsCritical() {
        let harness = Harness()

        XCTAssertEqual(harness.evaluate(9, charging: .unknown).map(\.severity), [.critical])
    }

    func testStaleNilAndDisappearedReadingsNeverAlert() {
        let harness = Harness()
        let stale = harness.snapshot(9, updated: Fixtures.noon.addingTimeInterval(-121))
        let missing = harness.snapshot(nil)
        let disappeared = harness.snapshot(9, availability: .recentlyDisconnected)

        XCTAssertTrue(harness.engine.evaluate([stale], now: Fixtures.noon).isEmpty)
        XCTAssertTrue(harness.engine.evaluate([missing], now: Fixtures.noon).isEmpty)
        XCTAssertTrue(harness.engine.evaluate([disappeared], now: Fixtures.noon).isEmpty)
        XCTAssertTrue(harness.engine.evaluate([], now: Fixtures.noon).isEmpty)
    }

    func testWarningRearmsOnlyAboveTwentyFive() {
        let harness = Harness()

        XCTAssertEqual(harness.evaluate(20).count, 1)
        XCTAssertTrue(harness.evaluate(21).isEmpty)
        XCTAssertTrue(harness.evaluate(20).isEmpty, "near-threshold movement must not re-arm")
        XCTAssertTrue(harness.evaluate(26).isEmpty)
        XCTAssertEqual(harness.evaluate(20).map(\.severity), [.warning])
    }

    func testCriticalRearmsOnlyAboveFifteen() {
        let harness = Harness()

        XCTAssertEqual(harness.evaluate(10).map(\.severity), [.critical])
        XCTAssertTrue(harness.evaluate(15).isEmpty)
        XCTAssertTrue(harness.evaluate(10).isEmpty)
        XCTAssertTrue(harness.evaluate(16).isEmpty)
        XCTAssertEqual(harness.evaluate(10).map(\.severity), [.critical])
    }

    func testPersistedStatePreventsDuplicateAfterEngineRestart() {
        let store = MemoryAlertStateStore()
        let first = Harness(store: store)
        XCTAssertEqual(first.evaluate(18).count, 1)

        let second = Harness(store: store)

        XCTAssertTrue(second.evaluate(18).isEmpty)
        let text = store.data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertFalse(text.lowercased().contains("udid"))
        XCTAssertFalse(text.lowercased().contains("serial"))
        XCTAssertFalse(text.contains("Test iPhone"), "display names do not belong in persisted alert state")
    }

    func testPersistedStateIsStrictlyBoundedAndCleanedOnLoad() throws {
        let records: [[String: Any]] = (0..<700).map { index in
            [
                "device": String(format: "%032x", index),
                "component": "primary",
                "warningFired": true,
                "criticalFired": false,
                "lastSeen": Fixtures.noon.timeIntervalSinceReferenceDate,
            ]
        }
        let store = MemoryAlertStateStore()
        store.data = try JSONSerialization.data(withJSONObject: ["records": records])

        _ = LowBatteryAlertEngine(store: store, now: Fixtures.noon)

        let data = try XCTUnwrap(store.data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let decoded = object?["records"] as? [[String: Any]] ?? []
        XCTAssertEqual(decoded.count, LowBatteryAlertEngine.maximumRememberedComponents)
    }

    func testTransportSwitchUsesTheSameOpaqueIdentityState() {
        let harness = Harness()

        XCTAssertEqual(harness.evaluate(18, connection: .wifi).count, 1)
        XCTAssertTrue(harness.evaluate(18, connection: .usb).isEmpty)
    }

    func testTwoPhysicalDevicesAlertIndependently() {
        let engine = LowBatteryAlertEngine(store: MemoryAlertStateStore(), now: Fixtures.noon)
        let first = Harness(identitySeed: "first").snapshot(20)
        let second = Harness(identitySeed: "second").snapshot(20)

        let alerts = engine.evaluate([first, second], now: Fixtures.noon)

        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(Set(alerts.map(\.devicePreferenceKey)).count, 2)
    }

    func testMultipleLowComponentsAggregateIntoOneWarning() {
        let harness = Harness(kind: .airPodsPro, name: "AirPods Pro")
        let snapshot = harness.snapshot(components: [
            .init(kind: .left, percentage: 20, lastUpdated: Fixtures.noon),
            .init(kind: .right, percentage: 19, lastUpdated: Fixtures.noon),
            .init(kind: .chargingCase, percentage: 70, lastUpdated: Fixtures.noon),
        ])

        let alerts = harness.engine.evaluate([snapshot], now: Fixtures.noon)

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.severity, .warning)
        XCTAssertEqual(alerts.first?.components.map(\.kind), [.left, .right])
    }

    func testCriticalComponentTakesPrecedenceOverWarningsInTheSameCycle() {
        let harness = Harness(kind: .airPodsPro, name: "AirPods Pro")
        let snapshot = harness.snapshot(components: [
            .init(kind: .left, percentage: 18, lastUpdated: Fixtures.noon),
            .init(kind: .right, percentage: 9, lastUpdated: Fixtures.noon),
            .init(kind: .chargingCase, percentage: 17, lastUpdated: Fixtures.noon),
        ])

        let alerts = harness.engine.evaluate([snapshot], now: Fixtures.noon)

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.severity, .critical)
        XCTAssertEqual(alerts.first?.components, [.init(kind: .right, percentage: 9)])
        XCTAssertTrue(harness.engine.evaluate([snapshot], now: Fixtures.noon).isEmpty)
    }

    func testAlertCadenceUsesTheExistingSchedulerAndTurnsOffCleanly() async {
        await MainActor.run {
            let scheduler = DeviceRefreshScheduler()
            let provider = AlertFixtureProvider()
            scheduler.setProviders([provider])

            XCTAssertEqual(scheduler.interval(for: .appleAccessory), 600)
            scheduler.setAlertBackgroundInterval(300)
            XCTAssertEqual(scheduler.interval(for: .appleAccessory), 300)
            scheduler.setAlertBackgroundInterval(60)
            XCTAssertEqual(scheduler.interval(for: .appleAccessory), 60)
            scheduler.setActive(true)
            XCTAssertEqual(scheduler.interval(for: .appleAccessory), 10)
            scheduler.setActive(false)
            scheduler.setAlertBackgroundInterval(nil)
            XCTAssertEqual(scheduler.interval(for: .appleAccessory), 600)
        }
    }
}

@MainActor
final class LowBatteryAlertPermissionTests: XCTestCase {
    func testAuthorizedServiceUsesTheInjectedDelivery() async {
        let delivery = AuthorizedAlertDelivery()
        // Reaching the delivery crosses two unstructured tasks: the permission
        // refresh that sets `authorization`, and the send itself. A fixed number
        // of `Task.yield()` calls is a guess at how many suspension points that
        // takes, and under load it was not enough — this case failed about one
        // run in five. Waiting for the event is what makes it deterministic.
        let arrived = expectation(description: "low battery alert delivered")
        delivery.onDelivery = arrived
        let service = LowBatteryAlertService(
            engine: LowBatteryAlertEngine(store: MemoryAlertStateStore(), now: Fixtures.noon),
            delivery: delivery
        )
        service.setEnabled(true, requestAuthorization: false)

        service.evaluate(
            [Fixtures.device(
                kind: .magicMouse,
                name: "Magic Mouse",
                components: [.init(kind: .primary, percentage: 20, lastUpdated: Fixtures.noon)]
            )],
            now: Fixtures.noon,
            staleAfter: DeviceSnapshotMerger.defaultStaleInterval
        )
        await fulfillment(of: [arrived], timeout: 2)

        XCTAssertEqual(delivery.delivered.count, 1)
        XCTAssertEqual(delivery.delivered.first?.devicePreferenceKey.count, 32)
        XCTAssertFalse(delivery.delivered.first?.body.contains("serial") ?? true)
    }

    func testDeniedPermissionDoesNotDisableDevicePowerCenter() async {
        let delivery = DeniedAlertDelivery()
        let service = LowBatteryAlertService(
            engine: LowBatteryAlertEngine(store: MemoryAlertStateStore(), now: Fixtures.noon),
            delivery: delivery
        )
        let external = PermissionFixtureProvider()
        let center = DevicePowerCenter(
            localProvider: PermissionFixtureProvider(identifier: .localMac, behavior: .eventDriven),
            externalProviders: [external],
            clock: FixedAlertClock(),
            lowBatteryAlerts: service
        )

        center.setEnabled(true)
        center.setExternalDevicesEnabled(true)
        center.setLowBatteryAlertsEnabled(true, requestAuthorization: true)
        external.emit(Fixtures.device(
            kind: .magicMouse,
            name: "Magic Mouse",
            components: [.init(kind: .primary, percentage: 9, lastUpdated: Fixtures.noon)]
        ))
        await Task.yield()

        XCTAssertEqual(center.devices.first(where: { !$0.identity.isLocalMac })?.headlinePercentage, 9)
        XCTAssertEqual(service.authorization, .denied)
        XCTAssertTrue(delivery.delivered.isEmpty)
    }

    func testAProviderFailureCannotTurnRetainedLastGoodDataIntoAnAlert() async {
        let delivery = AuthorizedAlertDelivery()
        let service = LowBatteryAlertService(
            engine: LowBatteryAlertEngine(store: MemoryAlertStateStore(), now: Fixtures.noon),
            delivery: delivery
        )
        let external = PermissionFixtureProvider()
        let center = DevicePowerCenter(
            localProvider: PermissionFixtureProvider(identifier: .localMac, behavior: .eventDriven),
            externalProviders: [external],
            clock: FixedAlertClock(),
            lowBatteryAlerts: service
        )
        center.setEnabled(true)
        center.setExternalDevicesEnabled(true)
        external.emit(Fixtures.device(
            kind: .magicMouse,
            name: "Magic Mouse",
            components: [.init(kind: .primary, percentage: 9, lastUpdated: Fixtures.noon)]
        ))
        external.fail()

        center.setLowBatteryAlertsEnabled(true)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(center.devices.first(where: { !$0.identity.isLocalMac })?.headlinePercentage, 9)
        XCTAssertTrue(delivery.delivered.isEmpty, "retained UI data is not current provider output")
    }
}

private final class MemoryAlertStateStore: LowBatteryAlertStateStoring {
    var data: Data?
    func load() -> Data? { data }
    func save(_ data: Data) { self.data = data }
}

private final class Harness {
    let engine: LowBatteryAlertEngine
    private let identity: AppleDeviceIdentity
    private let kind: AppleDeviceKind
    private let name: String

    init(
        store: LowBatteryAlertStateStoring = MemoryAlertStateStore(),
        identitySeed: String = "test-phone",
        kind: AppleDeviceKind = .iPhone,
        name: String = "Test iPhone"
    ) {
        engine = LowBatteryAlertEngine(store: store, now: Fixtures.noon)
        identity = Fixtures.identity(identitySeed)
        self.kind = kind
        self.name = name
    }

    func evaluate(
        _ percentage: Int?,
        charging: DeviceChargingState? = .discharging,
        connection: DeviceConnectionKind = .usb
    ) -> [LowBatteryAlert] {
        engine.evaluate([snapshot(percentage, charging: charging, connection: connection)], now: Fixtures.noon)
    }

    func snapshot(
        _ percentage: Int?,
        charging: DeviceChargingState? = .discharging,
        connection: DeviceConnectionKind = .usb,
        availability: DeviceAvailability = .connected,
        updated: Date = Fixtures.noon
    ) -> AppleDeviceSnapshot {
        snapshot(
            components: [.init(
                kind: .primary,
                percentage: percentage,
                chargingState: charging,
                lastUpdated: updated
            )],
            connection: connection,
            availability: availability,
            updated: updated
        )
    }

    func snapshot(
        components: [DeviceBatteryComponent],
        connection: DeviceConnectionKind = .bluetooth,
        availability: DeviceAvailability = .connected,
        updated: Date = Fixtures.noon
    ) -> AppleDeviceSnapshot {
        Fixtures.device(
            identity: identity,
            kind: kind,
            name: name,
            connection: connection,
            availability: availability,
            components: components,
            lastUpdated: updated
        )
    }
}

@MainActor
private final class AlertFixtureProvider: DeviceBatteryProviding {
    let identifier = DeviceProviderIdentifier.appleAccessory
    let refreshBehavior = DeviceRefreshBehavior.polled(activeInterval: 10, idleInterval: 600)
    let status = DeviceProviderStatus.ready
    func start(onUpdate: @escaping (DeviceProviderUpdate) -> Void) {}
    func stop() {}
    func refresh() {}
}

private final class DeniedAlertDelivery: LowBatteryNotificationDelivering, @unchecked Sendable {
    var onNotificationOpened: (@MainActor @Sendable (String?) -> Void)?
    private(set) var delivered: [LowBatteryNotification] = []
    func authorizationStatus() async -> LowBatteryNotificationAuthorization { .denied }
    func requestAuthorization() async -> LowBatteryNotificationAuthorization { .denied }
    func deliver(_ notification: LowBatteryNotification) async throws { delivered.append(notification) }
}

private final class AuthorizedAlertDelivery: LowBatteryNotificationDelivering, @unchecked Sendable {
    var onNotificationOpened: (@MainActor @Sendable (String?) -> Void)?
    private(set) var delivered: [LowBatteryNotification] = []
    /// Fulfilled once per delivery, so a test asserting that an alert *did*
    /// arrive can wait for the event instead of guessing how many yields the
    /// permission hop and the delivery hop need between them.
    var onDelivery: XCTestExpectation?
    func authorizationStatus() async -> LowBatteryNotificationAuthorization { .authorized }
    func requestAuthorization() async -> LowBatteryNotificationAuthorization { .authorized }
    func deliver(_ notification: LowBatteryNotification) async throws {
        delivered.append(notification)
        onDelivery?.fulfill()
    }
}

private struct FixedAlertClock: DeviceClock {
    var now: Date { Fixtures.noon }
}

@MainActor
private final class PermissionFixtureProvider: DeviceBatteryProviding {
    let identifier: DeviceProviderIdentifier
    let refreshBehavior: DeviceRefreshBehavior
    private(set) var status = DeviceProviderStatus.ready
    private var onUpdate: ((DeviceProviderUpdate) -> Void)?

    init(
        identifier: DeviceProviderIdentifier = .appleAccessory,
        behavior: DeviceRefreshBehavior = .polled(activeInterval: 10, idleInterval: 600)
    ) {
        self.identifier = identifier
        refreshBehavior = behavior
    }

    func start(onUpdate: @escaping (DeviceProviderUpdate) -> Void) {
        self.onUpdate = onUpdate
    }

    func stop() { onUpdate = nil }
    func refresh() {}

    func emit(_ device: AppleDeviceSnapshot) {
        onUpdate?(DeviceProviderUpdate(identifier: identifier, status: .ready, devices: [device]))
    }

    func fail() {
        status = .temporarilyFailed
        onUpdate?(DeviceProviderUpdate(identifier: identifier, status: status, devices: []))
    }
}
