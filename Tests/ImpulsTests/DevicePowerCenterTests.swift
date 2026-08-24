import XCTest
@testable import ImpulsCore

@MainActor
final class DevicePowerCenterTests: XCTestCase {

    // MARK: - Deduplication

    func testOneiPhoneSeenOverUSBAndWiFiIsOneRow() {
        let identity = Fixtures.identity("iphone")
        let usb = Fixtures.device(
            identity: identity,
            kind: .iPhone,
            name: "iPhone",
            connection: .usb,
            components: [DeviceBatteryComponent(kind: .primary, percentage: 73, lastUpdated: Fixtures.noon)],
            source: .mobileUSB
        )
        let wifi = Fixtures.device(
            identity: identity,
            kind: .iPhone,
            name: "iPhone",
            connection: .wifi,
            components: [DeviceBatteryComponent(kind: .primary, percentage: 69, lastUpdated: Fixtures.noon)],
            source: .mobileWiFi
        )

        let merged = DeviceSnapshotMerger.merge([[usb], [wifi]], now: Fixtures.noon)

        XCTAssertEqual(merged.count, 1)
        // Both are fresh, so the more reliable transport decides.
        XCTAssertEqual(merged.first?.headlinePercentage, 73)
        XCTAssertEqual(merged.first?.connection, .usb)
    }

    func testAFreshLowerPriorityReadingBeatsAStaleHigherPriorityOne() {
        let identity = Fixtures.identity("iphone")
        let staleUSB = Fixtures.device(
            identity: identity,
            kind: .iPhone,
            name: "iPhone",
            connection: .usb,
            components: [DeviceBatteryComponent(kind: .primary, percentage: 73, lastUpdated: Fixtures.noon)],
            lastUpdated: Fixtures.noon,
            source: .mobileUSB
        )
        let now = Fixtures.noon.addingTimeInterval(20 * 60)
        let freshWiFi = Fixtures.device(
            identity: identity,
            kind: .iPhone,
            name: "iPhone",
            connection: .wifi,
            components: [DeviceBatteryComponent(kind: .primary, percentage: 51, lastUpdated: now)],
            lastUpdated: now,
            source: .mobileWiFi
        )

        let merged = DeviceSnapshotMerger.merge([[staleUSB], [freshWiFi]], now: now)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.headlinePercentage, 51, "an hour-old cable reading is not the current charge")
        XCTAssertEqual(merged.first?.connection, .wifi)
    }

    func testTwoDevicesWithTheSameNameAreNotMergedIntoOne() {
        let mine = Fixtures.device(
            identity: Fixtures.identity("mine"),
            kind: .iPhone,
            name: "iPhone",
            components: [DeviceBatteryComponent(kind: .primary, percentage: 40, lastUpdated: Fixtures.noon)]
        )
        let theirs = Fixtures.device(
            identity: Fixtures.identity("theirs"),
            kind: .iPhone,
            name: "iPhone",
            components: [DeviceBatteryComponent(kind: .primary, percentage: 90, lastUpdated: Fixtures.noon)]
        )

        let merged = DeviceSnapshotMerger.merge([[mine], [theirs]], now: Fixtures.noon)

        XCTAssertEqual(merged.count, 2, "a shared name is not evidence that two devices are one")
    }

    func testMergingKeepsComponentsOnlyOneSourceKnowsAbout() {
        let identity = Fixtures.identity("airpods")
        let buds = Fixtures.device(
            identity: identity,
            kind: .airPodsPro,
            name: "AirPods Pro",
            components: [
                DeviceBatteryComponent(kind: .left, percentage: 81, lastUpdated: Fixtures.noon),
                DeviceBatteryComponent(kind: .right, percentage: 76, lastUpdated: Fixtures.noon),
            ]
        )
        let withCase = Fixtures.device(
            identity: identity,
            kind: .airPodsPro,
            name: "AirPods Pro",
            components: [DeviceBatteryComponent(kind: .chargingCase, percentage: 54, lastUpdated: Fixtures.noon)],
            source: .mobileWiFi
        )

        let merged = DeviceSnapshotMerger.merge([[buds], [withCase]], now: Fixtures.noon)

        XCTAssertEqual(merged.first?.components.map(\.kind), [.left, .right, .chargingCase])
    }

    func testAvailabilityPrefersTheProviderThatCanStillSeeTheDevice() {
        let identity = Fixtures.identity("mouse")
        let present = Fixtures.device(
            identity: identity,
            kind: .magicMouse,
            name: "Magic Mouse",
            availability: .connected,
            components: [DeviceBatteryComponent(kind: .primary, percentage: 61, lastUpdated: Fixtures.noon)]
        )
        let lost = Fixtures.device(
            identity: identity,
            kind: .magicMouse,
            name: "Magic Mouse",
            availability: .recentlyDisconnected,
            components: [],
            source: .mobileWiFi
        )

        let merged = DeviceSnapshotMerger.merge([[lost], [present]], now: Fixtures.noon)

        XCTAssertEqual(merged.first?.availability, .connected)
    }

    // MARK: - Freshness

    func testFreshnessFollowsTheClockAndNotTheProvider() {
        let device = Fixtures.device(
            kind: .iPhone,
            name: "iPhone",
            components: [DeviceBatteryComponent(kind: .primary, percentage: 63, lastUpdated: Fixtures.noon)]
        )

        XCTAssertEqual(
            DeviceSnapshotMerger.freshness(for: device, now: Fixtures.noon.addingTimeInterval(30)),
            .fresh
        )
        XCTAssertEqual(
            DeviceSnapshotMerger.freshness(for: device, now: Fixtures.noon.addingTimeInterval(12 * 60)),
            .stale
        )

        let neverRead = Fixtures.device(kind: .iPhone, name: "iPhone", components: [], lastUpdated: nil)
        XCTAssertEqual(DeviceSnapshotMerger.freshness(for: neverRead, now: Fixtures.noon), .unavailable)
    }

    // MARK: - Order

    func testThisMacComesFirstAndTheOrderIsTheNameRatherThanTheCharge() {
        let mac = Fixtures.device(
            identity: .localMac,
            kind: .mac,
            name: "MacBook Pro",
            connection: .builtIn,
            components: [DeviceBatteryComponent(kind: .primary, percentage: 12, lastUpdated: Fixtures.noon)],
            source: .localIOKit
        )
        let keyboard = Fixtures.device(
            kind: .magicKeyboard,
            name: "Magic Keyboard",
            components: [DeviceBatteryComponent(kind: .primary, percentage: 98, lastUpdated: Fixtures.noon)]
        )
        let offline = Fixtures.device(
            kind: .airPodsPro,
            name: "AirPods Pro",
            availability: .recentlyDisconnected,
            components: [DeviceBatteryComponent(kind: .primary, percentage: 99, lastUpdated: Fixtures.noon)]
        )

        let ordered = DeviceSnapshotMerger.merge([[offline, keyboard, mac]], now: Fixtures.noon)

        XCTAssertEqual(ordered.map(\.displayName), ["MacBook Pro", "Magic Keyboard", "AirPods Pro"])
    }

    // MARK: - Local Mac adapter

    func testAPortableMacBecomesADeviceWithOneBattery() {
        let snapshot = PowerNormalizer.snapshot(from: PowerSourceReading(
            providingPowerSource: .ac,
            hasInternalBattery: true,
            batteryPowerSourceState: .ac,
            currentCapacity: 73,
            maxCapacity: 100,
            designCapacity: nil,
            isCharging: true,
            isCharged: false,
            isFinishingCharge: false,
            timeToEmptyMinutes: nil,
            timeToFullChargeMinutes: 49,
            voltageMillivolts: nil,
            currentMilliamps: nil,
            temperatureCelsius: nil,
            systemBatteryCondition: nil,
            cycleCount: nil,
            adapterRatedPowerWatts: nil,
            connectionType: .externalPower
        ))

        let device = LocalMacDeviceProvider.device(from: snapshot, name: "MacBook Pro", now: Fixtures.noon)

        XCTAssertTrue(device.identity.isLocalMac)
        XCTAssertEqual(device.kind, .mac)
        XCTAssertEqual(device.connection, .builtIn)
        XCTAssertEqual(device.headlinePercentage, 73)
        XCTAssertEqual(device.components.first?.chargingState, .charging)
        XCTAssertEqual(device.externalPower, .connected)
    }

    func testADesktopMacIsStillADeviceEvenWithNoBatteryAtAll() {
        var reading = PowerSourceReading.unavailableDesktop
        reading.providingPowerSource = .ac
        let snapshot = PowerNormalizer.snapshot(from: reading)

        let device = LocalMacDeviceProvider.device(from: snapshot, name: "Mac mini", now: Fixtures.noon)

        XCTAssertEqual(device.kind, .mac)
        XCTAssertTrue(device.components.isEmpty)
        XCTAssertFalse(device.hasBatteryReading)
        XCTAssertEqual(device.externalPower, .connected, "a desktop Mac on the wall is not an unknown state")
        XCTAssertEqual(device.availability, .connected)
    }

    func testTheDesktopMacSurvivesTheCoordinatorsVisibilityFilter() {
        let monitor = PowerMonitor(provider: FixturePowerProvider(snapshot: PowerNormalizer.snapshot(from: .unavailableDesktop)))
        let center = DevicePowerCenter(monitor: monitor)

        monitor.setEnabled(true)
        center.setEnabled(true)

        XCTAssertEqual(center.devices.count, 1)
        XCTAssertEqual(center.visibleDevices.count, 1, "the Power module on a desktop Mac must not vanish")
        XCTAssertTrue(center.visibleDevices.first?.identity.isLocalMac ?? false)
    }

    // MARK: - Lifecycle

    func testNothingExternalStartsUntilTheUserAsksForIt() {
        let external = FakeDeviceProvider(identifier: .appleAccessory)
        let center = makeCenter(external: [external])

        center.setEnabled(true)
        XCTAssertEqual(external.startCount, 0, "enabling the module is not consent to look at other devices")

        center.setExternalDevicesEnabled(true)
        XCTAssertEqual(external.startCount, 1)

        center.setExternalDevicesEnabled(false)
        XCTAssertEqual(external.stopCount, 1)
    }

    /// The privacy boundary, stated in terms of the socket rather than a flag.
    ///
    /// The mobile provider is real here — its topology monitor and source are
    /// counted doubles — so this fails if anything ever reaches usbmuxd before
    /// the user has turned discovery on. Since 1.4.8 that switch is the only
    /// thing standing between an install and a phone, so it is the one that has
    /// to be provably tight.
    func testExternalDiscoveryOffMeansNoMobileTopologyAndNoRead() async {
        let source = SilentCountingSource()
        let topology = CountingTopologyMonitor()
        let mobile = MobileDeviceBatteryProvider(source: source, topologyMonitor: topology)
        let accessory = FakeDeviceProvider(identifier: .appleAccessory)
        let center = makeCenter(external: [accessory, mobile])

        center.setEnabled(true)
        // The module alone is not consent.
        XCTAssertFalse(topology.didStart)
        XCTAssertEqual(source.readCount, 0)
        center.refreshExternalDevices()
        XCTAssertFalse(topology.didStart, "an explicit refresh must not open a socket either")
        XCTAssertEqual(source.readCount, 0)

        center.setExternalDevicesEnabled(true)
        XCTAssertTrue(topology.didStart, "opting in starts the phone lookup with no hidden flag set")
        // The read is a task, so it lands a moment after the opt-in.
        for _ in 0..<50 where source.readCount == 0 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(source.readCount, 1)

        center.setExternalDevicesEnabled(false)
        XCTAssertTrue(topology.didStop, "switching discovery off closes the topology socket")
    }

    /// A phone that cannot be read must not take the AirPods down with it.
    func testAFailingMobileProviderLeavesTheAccessoriesAlone() {
        let mobile = FakeDeviceProvider(identifier: .mobileDevice)
        let accessory = FakeDeviceProvider(identifier: .appleAccessory)
        let center = makeCenter(external: [accessory, mobile])

        center.setEnabled(true)
        center.setExternalDevicesEnabled(true)

        let airPods = Fixtures.device(
            identity: Fixtures.identity("airpods"),
            kind: .airPods,
            name: "AirPods",
            connection: .bluetooth,
            components: [DeviceBatteryComponent(kind: .left, percentage: 80, lastUpdated: Fixtures.noon)],
            source: .ioRegistryAccessory
        )
        mobile.emit([], status: .temporarilyFailed)
        accessory.emit([airPods])

        XCTAssertTrue(center.devices.contains { $0.kind == .airPods })
        XCTAssertEqual(
            center.diagnostics.first { $0.provider == .appleAccessory }?.status,
            .ready
        )

        mobile.emit([], status: .permissionRequired)
        XCTAssertTrue(
            center.devices.contains { $0.kind == .airPods },
            "a phone waiting to be trusted is not a reason to drop the earphones"
        )
    }

    func testDisablingTheModuleStopsEveryProviderAndClearsTheList() {
        let external = FakeDeviceProvider(identifier: .appleAccessory)
        let center = makeCenter(external: [external])

        center.setEnabled(true)
        center.setExternalDevicesEnabled(true)
        external.emit([Fixtures.device(
            kind: .magicMouse,
            name: "Magic Mouse",
            components: [DeviceBatteryComponent(kind: .primary, percentage: 61, lastUpdated: Fixtures.noon)]
        )])
        XCTAssertEqual(center.devices.count, 2, "this Mac plus the mouse")

        center.setEnabled(false)

        XCTAssertEqual(external.stopCount, 1)
        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertTrue(center.diagnostics.isEmpty)
    }

    func testAStoppedProviderCannotReviveItselfWithALateUpdate() {
        let external = FakeDeviceProvider(identifier: .appleAccessory)
        let center = makeCenter(external: [external])

        center.setEnabled(true)
        center.setExternalDevicesEnabled(true)
        center.setEnabled(false)

        external.emit([Fixtures.device(
            kind: .magicMouse,
            name: "Magic Mouse",
            components: [DeviceBatteryComponent(kind: .primary, percentage: 61, lastUpdated: Fixtures.noon)]
        )])

        XCTAssertTrue(center.devices.isEmpty, "an in-flight read landing after stop must not restart the module")
    }

    func testOpeningThePanelAsksExternalProvidersOnceAndLeavesTheMacAlone() {
        let external = FakeDeviceProvider(identifier: .appleAccessory)
        let center = makeCenter(external: [external])

        center.setEnabled(true)
        center.setExternalDevicesEnabled(true)
        XCTAssertEqual(external.refreshCount, 0)

        center.setActive(true)
        XCTAssertEqual(external.refreshCount, 1)

        center.setActive(false)
        XCTAssertEqual(external.refreshCount, 1, "closing the panel is not a reason to read anything")
    }

    func testExplicitRefreshDoesNothingWhileExternalDevicesAreOff() {
        let external = FakeDeviceProvider(identifier: .appleAccessory)
        let center = makeCenter(external: [external])

        center.setEnabled(true)
        center.refreshExternalDevices()

        XCTAssertEqual(external.refreshCount, 0)
    }

    // MARK: - Failure isolation

    func testATransientProviderFailureKeepsTheLastGoodReadingAndTheMac() {
        let external = FakeDeviceProvider(identifier: .appleAccessory)
        let center = makeCenter(external: [external])

        center.setEnabled(true)
        center.setExternalDevicesEnabled(true)
        external.emit([Fixtures.device(
            kind: .magicMouse,
            name: "Magic Mouse",
            components: [DeviceBatteryComponent(kind: .primary, percentage: 61, lastUpdated: Fixtures.noon)]
        )])
        XCTAssertEqual(center.devices.count, 2)

        external.emit([], status: .temporarilyFailed)

        XCTAssertEqual(center.devices.count, 2, "one failed read does not delete what we already knew")
        XCTAssertEqual(center.devices.first(where: { !$0.identity.isLocalMac })?.headlinePercentage, 61)
        XCTAssertTrue(center.devices.contains { $0.identity.isLocalMac })
    }

    func testAProviderThatLosesPermissionDropsItsDevicesButNotTheOthers() {
        let external = FakeDeviceProvider(identifier: .appleAccessory)
        let center = makeCenter(external: [external])

        center.setEnabled(true)
        center.setExternalDevicesEnabled(true)
        external.emit([Fixtures.device(
            kind: .magicMouse,
            name: "Magic Mouse",
            components: [DeviceBatteryComponent(kind: .primary, percentage: 61, lastUpdated: Fixtures.noon)]
        )])

        external.emit([], status: .permissionRequired)

        XCTAssertEqual(center.devices.count, 1)
        XCTAssertTrue(center.devices.first?.identity.isLocalMac ?? false)
        XCTAssertEqual(
            center.diagnostics.first(where: { $0.provider == .appleAccessory })?.status,
            .permissionRequired
        )
    }

    /// The distinct case a locked-but-trusted phone reports: unlike losing
    /// permission, this is not a reason to forget what the phone last said.
    func testALockedDeviceKeepsItsLastKnownReadingUnlikePermissionLoss() {
        let mobile = FakeDeviceProvider(identifier: .mobileDevice)
        let center = makeCenter(external: [mobile])

        center.setEnabled(true)
        center.setExternalDevicesEnabled(true)
        let iPhone = Fixtures.device(
            kind: .iPhone,
            name: "iPhone",
            connection: .usb,
            components: [DeviceBatteryComponent(kind: .primary, percentage: 74, lastUpdated: Fixtures.noon)],
            source: .mobileUSB
        )
        mobile.emit([iPhone])
        XCTAssertEqual(center.devices.first(where: { !$0.identity.isLocalMac })?.headlinePercentage, 74)

        mobile.emit([], status: .deviceLocked)

        XCTAssertEqual(
            center.devices.first(where: { !$0.identity.isLocalMac })?.headlinePercentage,
            74,
            "a locked phone is still the same phone whose charge we knew a moment ago"
        )
        XCTAssertEqual(
            center.diagnostics.first(where: { $0.provider == .mobileDevice })?.status,
            .deviceLocked,
            "distinct from permissionRequired, which means this Mac is not trusted at all"
        )
    }

    // MARK: - Scheduling

    func testAnEventDrivenProviderIsNeverPolled() {
        let scheduler = DeviceRefreshScheduler()
        let eventDriven = FakeDeviceProvider(identifier: .localMac, behavior: .eventDriven)
        scheduler.setProviders([eventDriven])

        XCTAssertNil(scheduler.interval(for: .localMac), "PowerMonitor already knows when to look")
    }

    func testCadenceFollowsThePanelAndBacksOffWhenADeviceStopsAnswering() {
        let scheduler = DeviceRefreshScheduler()
        let polled = FakeDeviceProvider(
            identifier: .mobileDevice,
            behavior: .polled(activeInterval: 30, idleInterval: 300)
        )
        scheduler.setProviders([polled])

        XCTAssertEqual(scheduler.interval(for: .mobileDevice), 300)
        scheduler.setActive(true)
        XCTAssertEqual(scheduler.interval(for: .mobileDevice), 30)

        scheduler.noteOutcome(for: .mobileDevice, succeeded: false)
        XCTAssertEqual(scheduler.interval(for: .mobileDevice), 60)
        scheduler.noteOutcome(for: .mobileDevice, succeeded: false)
        XCTAssertEqual(scheduler.interval(for: .mobileDevice), 120)

        for _ in 0..<10 { scheduler.noteOutcome(for: .mobileDevice, succeeded: false) }
        XCTAssertEqual(scheduler.interval(for: .mobileDevice), DeviceRefreshScheduler.maximumBackoffInterval)

        scheduler.noteOutcome(for: .mobileDevice, succeeded: true)
        XCTAssertEqual(scheduler.interval(for: .mobileDevice), 30, "one good read ends the back-off")
    }

    // MARK: - Actor boundary

    /// The architectural guard for phase 04.
    ///
    /// `DeviceBatterySource` is the reading half of a provider and must stay
    /// off the main actor: a USB exchange with a sleeping phone takes seconds,
    /// and seconds on the main actor is a frozen panel. This calls `read()`
    /// from a detached task, so marking the protocol `@MainActor` — or an
    /// implementation quietly requiring it — stops compiling here rather than
    /// stuttering in front of a user.
    func testDeviceReadsHappenOffTheMainActor() async throws {
        let source = FixtureBatterySource()
        let devices = try await Task.detached { try await source.read() }.value

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.headlinePercentage, 73)
    }

    // MARK: - Helpers

    private func makeCenter(external: [DeviceBatteryProviding]) -> DevicePowerCenter {
        let monitor = PowerMonitor(provider: FixturePowerProvider(
            snapshot: PowerNormalizer.snapshot(from: PowerSourceReading(
                providingPowerSource: .battery,
                hasInternalBattery: true,
                batteryPowerSourceState: .battery,
                currentCapacity: 64,
                maxCapacity: 100,
                designCapacity: nil,
                isCharging: false,
                isCharged: false,
                isFinishingCharge: false,
                timeToEmptyMinutes: nil,
                timeToFullChargeMinutes: nil,
                voltageMillivolts: nil,
                currentMilliamps: nil,
                temperatureCelsius: nil,
                systemBatteryCondition: nil,
                cycleCount: nil,
                adapterRatedPowerWatts: nil,
                connectionType: .unplugged
            ))
        ))
        monitor.setEnabled(true)
        return DevicePowerCenter(
            localProvider: LocalMacDeviceProvider(monitor: monitor, deviceName: "MacBook Pro"),
            externalProviders: external
        )
    }
}

// MARK: - Fixtures

/// Counts reads without touching a socket.
private final class SilentCountingSource: DeviceBatterySource, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var readCount: Int { lock.withLock { count } }

    func read() async throws -> [AppleDeviceSnapshot] {
        lock.withLock { count += 1 }
        return []
    }
}

/// Records whether the usbmuxd listener would have been opened.
private final class CountingTopologyMonitor: MobileDeviceTopologyMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var stopped = false
    var didStart: Bool { lock.withLock { started } }
    var didStop: Bool { lock.withLock { stopped } }

    func start(onChange: @escaping @Sendable () -> Void) { lock.withLock { started = true } }
    func stop() { lock.withLock { stopped = true } }
}

@MainActor
private final class FakeDeviceProvider: DeviceBatteryProviding {
    let identifier: DeviceProviderIdentifier
    let refreshBehavior: DeviceRefreshBehavior
    private(set) var status: DeviceProviderStatus = .disabled
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var refreshCount = 0
    private var onUpdate: ((DeviceProviderUpdate) -> Void)?

    init(
        identifier: DeviceProviderIdentifier,
        behavior: DeviceRefreshBehavior = .polled(activeInterval: 30, idleInterval: 300)
    ) {
        self.identifier = identifier
        self.refreshBehavior = behavior
    }

    func start(onUpdate: @escaping (DeviceProviderUpdate) -> Void) {
        startCount += 1
        status = .ready
        self.onUpdate = onUpdate
    }

    func stop() {
        stopCount += 1
        status = .disabled
        onUpdate = nil
    }

    func refresh() {
        refreshCount += 1
    }

    /// Emits even after `stop()`, on purpose: that is how a late in-flight read
    /// behaves, and the coordinator has to survive it.
    func emit(_ devices: [AppleDeviceSnapshot], status: DeviceProviderStatus = .ready) {
        onUpdate?(DeviceProviderUpdate(identifier: identifier, status: status, devices: devices))
    }
}

@MainActor
private final class FixturePowerProvider: PowerSourceProviding {
    private let stored: PowerSnapshot

    init(snapshot: PowerSnapshot) {
        stored = snapshot
    }

    func snapshot() -> PowerSnapshot { stored }
}

private struct FixtureBatterySource: DeviceBatterySource {
    func read() async throws -> [AppleDeviceSnapshot] {
        [Fixtures.device(
            kind: .iPhone,
            name: "iPhone",
            components: [DeviceBatteryComponent(kind: .primary, percentage: 73, lastUpdated: Fixtures.noon)]
        )]
    }
}
