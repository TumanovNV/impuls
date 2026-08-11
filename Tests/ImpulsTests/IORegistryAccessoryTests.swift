import XCTest
@testable import ImpulsCore

/// Fixtures rather than hardware.
///
/// These property dictionaries are sanitised copies of the shape the registry
/// publishes: no real Bluetooth address, no real serial number. What they test
/// is mostly the parser's willingness to give up — on a missing key, on a value
/// of the wrong type, on a node that is not an Apple accessory at all.
final class IORegistryAccessoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    // MARK: - Ordinary accessories

    func testAMagicMouseBecomesOneDeviceWithOneBattery() {
        let device = map(.magicMouse(percent: 61))

        XCTAssertEqual(device?.kind, .magicMouse)
        XCTAssertEqual(device?.displayName, "Magic Mouse")
        XCTAssertEqual(device?.headlinePercentage, 61)
        XCTAssertEqual(device?.connection, .bluetooth)
        XCTAssertEqual(device?.source, .ioRegistryAccessory)
        XCTAssertEqual(device?.components.count, 1)
    }

    func testAnAccessoryNeverClaimsToBeChargingBecauseNothingSaysItIs() {
        let device = map(.magicMouse(percent: 61))

        XCTAssertEqual(device?.externalPower, .unknown)
        XCTAssertNil(device?.components.first?.chargingState)
        XCTAssertFalse(device?.capabilities.contains(.chargingState) ?? true)
    }

    func testZeroPercentIsARealReadingAndSurvives() {
        XCTAssertEqual(map(.magicMouse(percent: 0))?.headlinePercentage, 0)
    }

    func testTheKeyboardAndTrackpadAreRecognisedByTheirOwnProductNames() {
        XCTAssertEqual(map(.accessory(product: "Magic Keyboard with Touch ID", percent: 88))?.kind, .magicKeyboard)
        XCTAssertEqual(map(.accessory(product: "Magic Trackpad", percent: 12))?.kind, .magicTrackpad)
    }

    func testAnUnrecognisedAppleAccessoryIsShownAsItselfRatherThanGuessedAt() {
        let device = map(.accessory(product: "Apple Studio Pointing Thing", percent: 44))

        XCTAssertEqual(device?.kind, .unknown, "a name we do not know is not a reason to invent a category")
        XCTAssertEqual(device?.displayName, "Apple Studio Pointing Thing")
        XCTAssertEqual(device?.headlinePercentage, 44)
    }

    // MARK: - AirPods components

    func testAirPodsWithSeparateComponentsKeepThemSeparate() {
        let device = map(.airPods(left: 81, right: 76, chargingCase: 54, overall: 76))

        XCTAssertEqual(device?.kind, .airPodsPro)
        XCTAssertEqual(device?.components.map(\.kind), [.left, .right, .chargingCase])
        XCTAssertEqual(device?.components.map(\.percentage), [81, 76, 54])
        // The overall value is a summary of the three, not a fourth battery.
        XCTAssertEqual(device?.components.count, 3)
        XCTAssertTrue(device?.capabilities.contains(.multipleComponents) ?? false)
    }

    func testOnlyOneBudPresentMeansOneComponentAndNoZeroesForTheRest() {
        let device = map(.airPods(left: 81, right: nil, chargingCase: nil, overall: nil))

        XCTAssertEqual(device?.components.map(\.kind), [.left])
        XCTAssertEqual(device?.components.first?.percentage, 81)
    }

    func testAirPodsThatOnlyPublishAnOverallValueGetOneBattery() {
        let device = map(.airPods(left: nil, right: nil, chargingCase: nil, overall: 63))

        XCTAssertEqual(device?.components.map(\.kind), [.primary])
        XCTAssertEqual(device?.headlinePercentage, 63)
        XCTAssertFalse(device?.capabilities.contains(.multipleComponents) ?? true)
    }

    func testAirPodsMaxIsASingleBattery() {
        let device = map(.accessory(product: "AirPods Max", percent: 47))

        XCTAssertEqual(device?.kind, .airPodsMax)
        XCTAssertEqual(device?.components.count, 1)
    }

    // MARK: - Nodes that must not become devices

    func testANodeWithNoBatteryValueIsNotADevice() {
        var properties = Fixture.magicMouse(percent: 61).properties
        properties.removeValue(forKey: IORegistryAccessoryMapper.Key.batteryPercent)

        XCTAssertNil(IORegistryAccessoryMapper.device(from: properties, now: now, resolver: resolver))
    }

    func testANodeWithNoStableIdentifierIsNotADevice() {
        var properties = Fixture.magicMouse(percent: 61).properties
        properties.removeValue(forKey: IORegistryAccessoryMapper.Key.deviceAddress)
        properties.removeValue(forKey: IORegistryAccessoryMapper.Key.serialNumber)

        XCTAssertNil(
            IORegistryAccessoryMapper.device(from: properties, now: now, resolver: resolver),
            "a registry entry ID changes on every reconnect and cannot identify a device"
        )
    }

    func testANonAppleAccessoryIsIgnoredByVendorIdentifierAndNotByName() {
        var properties = Fixture.magicMouse(percent: 61).properties
        properties[IORegistryAccessoryMapper.Key.vendorID] = NSNumber(value: 0x046D)
        properties[IORegistryAccessoryMapper.Key.product] = "Apple Magic Mouse Compatible"

        XCTAssertNil(
            IORegistryAccessoryMapper.device(from: properties, now: now, resolver: resolver),
            "the word Apple in a product string is not evidence of anything"
        )
    }

    func testAManufacturerStringIsUsedOnlyWhenThereIsNoVendorIdentifier() {
        var properties = Fixture.magicMouse(percent: 61).properties
        properties.removeValue(forKey: IORegistryAccessoryMapper.Key.vendorID)
        properties[IORegistryAccessoryMapper.Key.manufacturer] = "Apple Inc."
        XCTAssertNotNil(IORegistryAccessoryMapper.device(from: properties, now: now, resolver: resolver))

        properties[IORegistryAccessoryMapper.Key.manufacturer] = "Some Other Company"
        XCTAssertNil(IORegistryAccessoryMapper.device(from: properties, now: now, resolver: resolver))

        properties.removeValue(forKey: IORegistryAccessoryMapper.Key.manufacturer)
        XCTAssertNil(IORegistryAccessoryMapper.device(from: properties, now: now, resolver: resolver))
    }

    func testTheBuiltInKeyboardAndTrackpadAreNotAccessories() {
        var properties = Fixture.magicMouse(percent: 61).properties
        properties[IORegistryAccessoryMapper.Key.transport] = "SPI"

        XCTAssertNil(IORegistryAccessoryMapper.device(from: properties, now: now, resolver: resolver))
    }

    func testAnEmptyRegistryNodeProducesNothingRatherThanAnEmptyDevice() {
        XCTAssertNil(IORegistryAccessoryMapper.device(from: [:], now: now, resolver: resolver))
    }

    // MARK: - Value shapes

    func testBatteryValuesAreAcceptedInWhateverNumericWidthTheDriverChose() {
        for value in [NSNumber(value: Int8(61)), NSNumber(value: Int32(61)), NSNumber(value: Int64(61)), NSNumber(value: UInt8(61)), NSNumber(value: 61.0)] {
            var properties = Fixture.magicMouse(percent: 61).properties
            properties[IORegistryAccessoryMapper.Key.batteryPercent] = value
            XCTAssertEqual(
                IORegistryAccessoryMapper.device(from: properties, now: now, resolver: resolver)?.headlinePercentage,
                61,
                "width \(value) should read the same"
            )
        }
    }

    func testUnexpectedValueTypesReadAsAbsentAndNotAsNumbers() {
        XCTAssertNil(IORegistryAccessoryMapper.integer("61"))
        XCTAssertNil(IORegistryAccessoryMapper.integer(["percent": 61]))
        XCTAssertNil(IORegistryAccessoryMapper.integer(Data([61])))
        XCTAssertNil(IORegistryAccessoryMapper.integer(nil))
        XCTAssertNil(IORegistryAccessoryMapper.integer(Double.nan))
        XCTAssertNil(IORegistryAccessoryMapper.integer(Double.infinity))
        // A flag read as a percentage would be a wrong number, not a missing one.
        XCTAssertNil(IORegistryAccessoryMapper.integer(NSNumber(value: true)))
        XCTAssertNil(IORegistryAccessoryMapper.integer(NSNumber(value: false)))
    }

    func testImpossiblePercentagesAreDroppedRatherThanClamped() {
        for impossible in [-1, 101, 255, Int.max] {
            var properties = Fixture.magicMouse(percent: 61).properties
            properties[IORegistryAccessoryMapper.Key.batteryPercent] = NSNumber(value: impossible)
            XCTAssertNil(
                IORegistryAccessoryMapper.device(from: properties, now: now, resolver: resolver),
                "\(impossible) is not a battery level and must not become one"
            )
        }
    }

    func testFutureAndUnknownKeysAreIgnoredWithoutDisturbingTheKnownOnes() {
        var properties = Fixture.magicMouse(percent: 61).properties
        properties["BatteryHealthPercentSomething"] = NSNumber(value: 87)
        properties["ThermalPressureLevel"] = "nominal"
        properties["FutureDictionary"] = ["a": 1, "b": [2, 3]]

        let device = IORegistryAccessoryMapper.device(from: properties, now: now, resolver: resolver)

        XCTAssertEqual(device?.headlinePercentage, 61)
        XCTAssertEqual(device?.components.count, 1)
    }

    func testStringValuesArriveAsStringsOrAsDataAndAreTrimmed() {
        XCTAssertEqual(IORegistryAccessoryMapper.string("  Magic Mouse  "), "Magic Mouse")
        XCTAssertEqual(IORegistryAccessoryMapper.string(Data("Magic Mouse".utf8)), "Magic Mouse")
        XCTAssertNil(IORegistryAccessoryMapper.string("   "))
        XCTAssertNil(IORegistryAccessoryMapper.string(NSNumber(value: 5)))
    }

    // MARK: - Identity

    func testTwoAccessoriesOfTheSameModelStayTwoDevices() {
        let mine = map(.accessory(product: "Magic Keyboard", percent: 88, address: "11:11:11:11:11:11"))
        let desk = map(.accessory(product: "Magic Keyboard", percent: 42, address: "22:22:22:22:22:22"))

        XCTAssertNotNil(mine)
        XCTAssertNotEqual(mine?.identity, desk?.identity, "identical names are not identical devices")
    }

    func testTheSameAccessorySeenTwiceIsTheSameDevice() {
        let first = map(.magicMouse(percent: 61))
        let second = map(.magicMouse(percent: 60))

        XCTAssertEqual(first?.identity, second?.identity)
    }

    func testTheHardwareAddressIsNotCarriedAnywhereInTheDevice() {
        let address = "AA:BB:CC:DD:EE:FF"
        let device = map(.accessory(product: "Magic Mouse", percent: 61, address: address))

        XCTAssertNotNil(device)
        XCTAssertFalse(device?.displayName.contains(address) ?? true)
        XCTAssertFalse(device?.modelName?.contains(address) ?? false)
        XCTAssertFalse("\(device!.identity)".contains(address))
        XCTAssertFalse(device!.identity.localPreferenceKey.contains(address))
    }

    // MARK: - Helpers

    private var resolver: DeviceIdentityResolver {
        DeviceIdentityResolver(service: "io.tumanov.impuls.tests.device-identity", account: "unit-test")
    }

    private func map(_ fixture: Fixture) -> AppleDeviceSnapshot? {
        IORegistryAccessoryMapper.device(from: fixture.properties, now: now, resolver: resolver)
    }

    /// Sanitised property dictionaries in the shape the registry publishes.
    struct Fixture {
        var properties: [String: Any]

        static func accessory(
            product: String,
            percent: Int?,
            address: String = "AA:BB:CC:00:11:22"
        ) -> Fixture {
            var properties: [String: Any] = [
                IORegistryAccessoryMapper.Key.product: product,
                IORegistryAccessoryMapper.Key.vendorID: NSNumber(value: IORegistryAccessoryMapper.appleVendorID),
                IORegistryAccessoryMapper.Key.transport: "Bluetooth",
                IORegistryAccessoryMapper.Key.deviceAddress: address,
            ]
            if let percent { properties[IORegistryAccessoryMapper.Key.batteryPercent] = NSNumber(value: percent) }
            return Fixture(properties: properties)
        }

        static func magicMouse(percent: Int) -> Fixture {
            accessory(product: "Magic Mouse", percent: percent)
        }

        static func airPods(left: Int?, right: Int?, chargingCase: Int?, overall: Int?) -> Fixture {
            var fixture = accessory(product: "AirPods Pro", percent: overall)
            if let left {
                fixture.properties[IORegistryAccessoryMapper.Key.batteryPercentLeft] = NSNumber(value: left)
            }
            if let right {
                fixture.properties[IORegistryAccessoryMapper.Key.batteryPercentRight] = NSNumber(value: right)
            }
            if let chargingCase {
                fixture.properties[IORegistryAccessoryMapper.Key.batteryPercentCase] = NSNumber(value: chargingCase)
            }
            return fixture
        }
    }
}

/// Lifecycle, without touching the registry.
///
/// The provider is handed a source it controls, so "the accessory went away",
/// "the read failed" and "there is nothing paired to this Mac" are all things a
/// test can actually cause.
@MainActor
final class AppleAccessoryBatteryProviderTests: XCTestCase {
    func testAnEmptyMacIsAReadyProviderWithNoDevicesAndNoError() async {
        let source = FakeAccessorySource(devices: [])
        let provider = AppleAccessoryBatteryProvider(registrySource: source, profilerSource: nil)

        let update = await firstUpdate(from: provider)

        XCTAssertEqual(update.status, .ready)
        XCTAssertTrue(update.devices.isEmpty, "no accessories is an ordinary state, not a failure")
        provider.stop()
    }

    func testAnAccessoryThatGoesAwayLeavesNoGhostBehind() async {
        let source = FakeAccessorySource(devices: [Self.mouse])
        let provider = AppleAccessoryBatteryProvider(registrySource: source, profilerSource: nil)
        let collector = UpdateCollector()

        provider.start { collector.append($0) }
        await collector.wait(forUpdateCount: 1, in: self)
        XCTAssertEqual(collector.updates.last?.devices.count, 1)

        // Unplugged, switched off, or carried out of range.
        source.devices = []
        provider.refresh()
        await collector.wait(forUpdateCount: 2, in: self)

        XCTAssertTrue(collector.updates.last?.devices.isEmpty ?? false)
        XCTAssertEqual(collector.updates.last?.status, .ready)
        provider.stop()
    }

    func testAnAccessoryThatComesBackIsTheSameDeviceAgain() async {
        let source = FakeAccessorySource(devices: [Self.mouse])
        let provider = AppleAccessoryBatteryProvider(registrySource: source, profilerSource: nil)
        let collector = UpdateCollector()

        provider.start { collector.append($0) }
        await collector.wait(forUpdateCount: 1, in: self)

        source.devices = []
        provider.refresh()
        await collector.wait(forUpdateCount: 2, in: self)

        source.devices = [Self.mouse]
        provider.refresh()
        await collector.wait(forUpdateCount: 3, in: self)

        XCTAssertEqual(
            collector.updates.last?.devices.first?.identity,
            collector.updates.first?.devices.first?.identity,
            "a reconnect is the same mouse, not a new one"
        )
        provider.stop()
    }

    func testAFailedReadKeepsTheLastGoodListAndSaysItIsTemporary() async {
        let source = FakeAccessorySource(devices: [Self.mouse])
        let provider = AppleAccessoryBatteryProvider(registrySource: source, profilerSource: nil)
        let collector = UpdateCollector()

        provider.start { collector.append($0) }
        await collector.wait(forUpdateCount: 1, in: self)

        source.shouldThrow = true
        provider.refresh()
        await collector.wait(forUpdateCount: 2, in: self)

        XCTAssertEqual(collector.updates.last?.status, .temporarilyFailed)
        XCTAssertEqual(provider.status, .temporarilyFailed)
        XCTAssertEqual(
            collector.updates.last?.devices.count,
            1,
            "one failed registry walk is not a reason to forget the mouse"
        )

        // And it recovers on its own once the read works again.
        source.shouldThrow = false
        provider.refresh()
        await collector.wait(forUpdateCount: 3, in: self)
        XCTAssertEqual(collector.updates.last?.status, .ready)
        provider.stop()
    }

    func testAStoppedProviderPublishesNothingFurther() async {
        let source = FakeAccessorySource(devices: [Self.mouse])
        let provider = AppleAccessoryBatteryProvider(registrySource: source, profilerSource: nil)

        var updates = 0
        let arrived = expectation(description: "first read")
        provider.start { _ in
            updates += 1
            if updates == 1 { arrived.fulfill() }
        }
        await fulfillment(of: [arrived], timeout: 2)

        provider.stop()
        provider.refresh()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(updates, 1, "a stopped provider is stopped")
        XCTAssertEqual(provider.status, .disabled)
    }

    /// The one test that touches the real registry.
    ///
    /// It cannot assert what is connected — a CI runner has nothing paired, and
    /// a developer's Mac has whatever it has — so it asserts the two things
    /// that must hold on every machine: the walk completes without throwing,
    /// and anything it does return is a device with a real reading rather than
    /// a placeholder. On a Mac with no accessories the correct answer is an
    /// empty list.
    func testReadingTheRealRegistryNeverThrowsAndNeverInventsADevice() async throws {
        let devices = try await IORegistryAccessorySource().read()

        for device in devices {
            XCTAssertTrue(device.hasBatteryReading, "a device without a reading should not have been created")
            XCTAssertEqual(device.source, .ioRegistryAccessory)
            XCTAssertFalse(device.displayName.isEmpty)
            for component in device.components {
                if let percentage = component.percentage {
                    XCTAssertTrue((0...100).contains(percentage))
                }
            }
        }
    }

    /// The accessory hardware probe.
    ///
    /// Prints what this Mac's registry actually offers, so a QA run records
    /// evidence rather than an impression. It asserts nothing about how many
    /// accessories exist — that depends on what is paired — only that whatever
    /// is returned is well formed. Names are printed because they are names;
    /// no identifier is.
    func testHardwareProbeOfTheAccessoryRegistry() async throws {
        let matching = IORegistryAccessorySource.matchingServiceCount()
        let devices = try await IORegistryAccessorySource().read()

        print("PROBE \(IORegistryAccessoryMapper.serviceClass) nodes: \(matching)")
        print("PROBE nodes publishing a battery: \(devices.count)")
        for device in devices {
            let components = device.components
                .map { "\($0.kind.rawValue)=\($0.percentage.map(String.init) ?? "nil")" }
                .joined(separator: " ")
            print("PROBE   \(device.kind.rawValue) \"\(device.displayName)\" — \(components)")
        }
    }

    func testTheProviderIsPolledSlowlyAndSaysSo() {
        let provider = AppleAccessoryBatteryProvider(registrySource: FakeAccessorySource(devices: []), profilerSource: nil)

        guard case .polled(let active, let idle) = provider.refreshBehavior else {
            return XCTFail("the registry does not notify on level changes, so this has to be polled")
        }
        XCTAssertGreaterThanOrEqual(active, 30)
        XCTAssertGreaterThanOrEqual(idle, active * 2, "a closed panel is not worth the same attention")
    }

    // MARK: - Helpers

    private static var mouse: AppleDeviceSnapshot {
        Fixtures.device(
            kind: .magicMouse,
            name: "Magic Mouse",
            components: [DeviceBatteryComponent(kind: .primary, percentage: 61, lastUpdated: Fixtures.noon)]
        )
    }

    private func firstUpdate(
        from provider: AppleAccessoryBatteryProvider,
        keepRunning: Bool = false
    ) async -> DeviceProviderUpdate {
        var received: DeviceProviderUpdate?
        let arrived = expectation(description: "update")
        provider.start { update in
            guard received == nil else { return }
            received = update
            arrived.fulfill()
        }
        await fulfillment(of: [arrived], timeout: 2)
        if !keepRunning { provider.stop() }
        return received!
    }
}

/// Collects provider updates and waits for the n-th one.
///
/// The provider reads asynchronously, so every assertion about what it
/// published has to wait for the read to land. Polling the collector is enough
/// here and keeps the tests readable — no expectation plumbing at each step.
@MainActor
private final class UpdateCollector {
    private(set) var updates: [DeviceProviderUpdate] = []

    func append(_ update: DeviceProviderUpdate) {
        updates.append(update)
    }

    func wait(forUpdateCount count: Int, in testCase: XCTestCase, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while updates.count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertGreaterThanOrEqual(updates.count, count, "provider did not publish update \(count) in time")
    }
}

private final class FakeAccessorySource: DeviceBatterySource, @unchecked Sendable {
    private let lock = NSLock()
    private var storedDevices: [AppleDeviceSnapshot]
    private var storedShouldThrow = false

    init(devices: [AppleDeviceSnapshot]) {
        storedDevices = devices
    }

    var devices: [AppleDeviceSnapshot] {
        get { lock.withLock { storedDevices } }
        set { lock.withLock { storedDevices = newValue } }
    }

    var shouldThrow: Bool {
        get { lock.withLock { storedShouldThrow } }
        set { lock.withLock { storedShouldThrow = newValue } }
    }

    struct ReadFailure: Error {}

    func read() async throws -> [AppleDeviceSnapshot] {
        if shouldThrow { throw ReadFailure() }
        return devices
    }
}

/// The `system_profiler` path, on fixtures and on this Mac.
final class SystemProfilerAccessoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_770_000_000)
    private var resolver: DeviceIdentityResolver {
        DeviceIdentityResolver(service: "io.tumanov.impuls.tests.device-identity", account: "unit-test")
    }

    /// The accessory hardware probe for this source.
    ///
    /// Prints what the tool actually reports on this Mac, so a QA run leaves
    /// evidence. Names are printed because they are names; addresses are not.
    func testHardwareProbeOfSystemProfiler() async throws {
        let started = Date()
        let devices = try await SystemProfilerAccessorySource(resolver: resolver).read()
        let elapsed = Date().timeIntervalSince(started)

        print(String(format: "PROBE system_profiler runtime: %.3f s", elapsed))
        print("PROBE connected Apple accessories with a battery: \(devices.count)")
        for device in devices {
            let components = device.components
                .map { "\($0.kind.rawValue)=\($0.percentage.map(String.init) ?? "nil")" }
                .joined(separator: " ")
            print("PROBE   \(device.kind.rawValue) \"\(device.displayName)\" model=\(device.modelName ?? "nil") — \(components)")
        }
    }

    // MARK: - Parser fixtures

    private func devices(_ json: String) throws -> [AppleDeviceSnapshot] {
        try SystemProfilerAccessoryParser.devices(fromJSON: Data(json.utf8), now: now, resolver: resolver)
    }

    /// The exact shape this Mac produced with AirPods Pro connected: one
    /// component, because only one bud was out of the case.
    func testTheShapeThisMacActuallyProduces() throws {
        let parsed = try devices("""
        {"SPBluetoothDataType":[{"device_connected":[{"AirPods Pro (Nikolai)":{
          "device_address":"aa-bb-cc-dd-ee-ff",
          "device_batteryLevelRight":"87 %",
          "device_minorType":"Headphones",
          "device_productID":"0x200E",
          "device_vendorID":"0x004C"}}]}]}
        """)

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.kind, .airPodsPro)
        XCTAssertEqual(parsed.first?.displayName, "AirPods Pro (Nikolai)")
        XCTAssertEqual(parsed.first?.components.map(\.kind), [.right])
        XCTAssertEqual(parsed.first?.components.first?.percentage, 87)
        XCTAssertEqual(parsed.first?.source, .systemProfilerAccessory)
        // One bud out of the case is not a reason to invent the other two.
        XCTAssertFalse(parsed.first?.capabilities.contains(.multipleComponents) ?? true)
    }

    func testAllThreeComponentsWhenTheToolReportsThem() throws {
        let parsed = try devices("""
        {"SPBluetoothDataType":[{"device_connected":[{"AirPods Pro":{
          "device_address":"aa-bb-cc-dd-ee-ff",
          "device_batteryLevelLeft":"81 %",
          "device_batteryLevelRight":"76 %",
          "device_batteryLevelCase":"54 %",
          "device_vendorID":"0x004C"}}]}]}
        """)

        XCTAssertEqual(parsed.first?.components.map(\.kind), [.left, .right, .chargingCase])
        XCTAssertEqual(parsed.first?.components.map(\.percentage), [81, 76, 54])
    }

    func testASingleBatteryAccessoryUsesTheMainValue() throws {
        let parsed = try devices("""
        {"SPBluetoothDataType":[{"device_connected":[{"Magic Mouse":{
          "device_address":"11-22-33-44-55-66",
          "device_batteryLevelMain":"61 %",
          "device_vendorID":"0x004C"}}]}]}
        """)

        XCTAssertEqual(parsed.first?.kind, .magicMouse)
        XCTAssertEqual(parsed.first?.components.map(\.kind), [.primary])
        XCTAssertEqual(parsed.first?.components.first?.percentage, 61)
    }

    func testADeviceWithNoBatteryIsNotListed() throws {
        let parsed = try devices("""
        {"SPBluetoothDataType":[{"device_connected":[{"Magic Keyboard":{
          "device_address":"11-22-33-44-55-66","device_vendorID":"0x004C"}}]}]}
        """)

        XCTAssertTrue(parsed.isEmpty, "a connected accessory with no charge is not a card")
    }

    func testDisconnectedDevicesAreNotListedAtAll() throws {
        let parsed = try devices("""
        {"SPBluetoothDataType":[{"device_not_connected":[{"AirPods Pro":{
          "device_address":"aa-bb-cc-dd-ee-ff",
          "device_batteryLevelRight":"87 %",
          "device_vendorID":"0x004C"}}]}]}
        """)

        XCTAssertTrue(parsed.isEmpty)
    }

    func testANonAppleAccessoryIsFilteredByVendorIdentifier() throws {
        let parsed = try devices("""
        {"SPBluetoothDataType":[{"device_connected":[{"Apple-Compatible Buds":{
          "device_address":"11-22-33-44-55-66",
          "device_batteryLevelMain":"55 %",
          "device_vendorID":"0x046D"}}]},{"device_connected":[{"No Vendor At All":{
          "device_address":"22-33-44-55-66-77",
          "device_batteryLevelMain":"55 %"}}]}]}
        """)

        XCTAssertTrue(parsed.isEmpty)
    }

    func testSeveralDevicesAreAllParsedAndKeptDistinct() throws {
        let parsed = try devices("""
        {"SPBluetoothDataType":[{"device_connected":[
          {"AirPods Pro":{"device_address":"aa-11","device_batteryLevelRight":"87 %","device_vendorID":"0x004C"}},
          {"Magic Mouse":{"device_address":"bb-22","device_batteryLevelMain":"61 %","device_vendorID":"0x004C"}},
          {"Magic Keyboard":{"device_address":"cc-33","device_batteryLevelMain":"98 %","device_vendorID":"0x004C"}}]}]}
        """)

        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(Set(parsed.map(\.identity)).count, 3)
    }

    func testTwoAccessoriesWithOneNameStayTwoDevicesAndOneAddressStaysOne() throws {
        let sameName = try devices("""
        {"SPBluetoothDataType":[{"device_connected":[
          {"Magic Keyboard":{"device_address":"aa-11","device_batteryLevelMain":"88 %","device_vendorID":"0x004C"}},
          {"Magic Keyboard":{"device_address":"bb-22","device_batteryLevelMain":"42 %","device_vendorID":"0x004C"}}]}]}
        """)
        XCTAssertEqual(sameName.count, 2, "identity is the address, never the name")

        let duplicated = try devices("""
        {"SPBluetoothDataType":[
          {"device_connected":[{"AirPods Pro":{"device_address":"aa-11","device_batteryLevelRight":"87 %","device_vendorID":"0x004C"}}]},
          {"device_connected":[{"AirPods Pro":{"device_address":"aa-11","device_batteryLevelRight":"87 %","device_vendorID":"0x004C"}}]}]}
        """)
        XCTAssertEqual(duplicated.count, 1, "the same accessory under two controllers is one device")
    }

    func testImpossiblePercentagesAndOddValuesAreDropped() throws {
        for value in ["101 %", "-5 %", "255 %", "", "Unknown", "  ", "%"] {
            let parsed = try devices("""
            {"SPBluetoothDataType":[{"device_connected":[{"Magic Mouse":{
              "device_address":"11-22","device_batteryLevelMain":"\(value)","device_vendorID":"0x004C"}}]}]}
            """)
            XCTAssertTrue(parsed.isEmpty, "\"\(value)\" is not a battery level")
        }
    }

    func testPercentagesAreReadWithOrWithoutTheirUnit() {
        XCTAssertEqual(SystemProfilerAccessoryParser.percentage("87 %"), 87)
        XCTAssertEqual(SystemProfilerAccessoryParser.percentage("87%"), 87)
        XCTAssertEqual(SystemProfilerAccessoryParser.percentage("0 %"), 0)
        XCTAssertEqual(SystemProfilerAccessoryParser.percentage("100 %"), 100)
        XCTAssertNil(SystemProfilerAccessoryParser.percentage(87))
        XCTAssertNil(SystemProfilerAccessoryParser.percentage(nil))
    }

    func testUnknownFutureFieldsAreIgnoredWithoutDisturbingTheKnownOnes() throws {
        let parsed = try devices("""
        {"SPBluetoothDataType":[{"device_connected":[{"AirPods Pro":{
          "device_address":"aa-11",
          "device_batteryLevelRight":"87 %",
          "device_vendorID":"0x004C",
          "device_somethingNewIn2027":{"nested":[1,2,3]},
          "device_spatialAudioMode":"headTracked"}}]}],"SPSomeNewSection":[]}
        """)

        XCTAssertEqual(parsed.first?.headlinePercentage, 87)
    }

    func testMalformedOutputIsAFailureAndNotAnEmptyList() {
        XCTAssertThrowsError(try devices("not json at all"))
        XCTAssertThrowsError(try devices("{}"))
        XCTAssertThrowsError(try devices("[]"))
        XCTAssertThrowsError(try devices("{\"SPBluetoothDataType\":\"unexpected\"}"))
    }

    func testAMalformedDeviceObjectIsSkippedWhileTheOthersSurvive() throws {
        let parsed = try devices("""
        {"SPBluetoothDataType":[{"device_connected":[
          {"Broken":"not a dictionary"},
          {"Magic Mouse":{"device_address":"bb-22","device_batteryLevelMain":"61 %","device_vendorID":"0x004C"}}]}]}
        """)

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.kind, .magicMouse)
    }

    func testTheAddressIsNowhereInTheResultingDevice() throws {
        let address = "aa-bb-cc-dd-ee-ff"
        let parsed = try devices("""
        {"SPBluetoothDataType":[{"device_connected":[{"AirPods Pro":{
          "device_address":"\(address)","device_batteryLevelRight":"87 %","device_vendorID":"0x004C"}}]}]}
        """)

        let device = try XCTUnwrap(parsed.first)
        XCTAssertFalse("\(device.identity)".contains(address))
        XCTAssertFalse(device.identity.localPreferenceKey.contains(address))
        XCTAssertFalse(device.displayName.contains(address))
    }

    func testTheProcessRunnerFailsCleanlyWhenTheToolMisbehaves() async {
        let oversized = SystemProfilerAccessorySource(resolver: resolver) {
            throw MobileDeviceError.payloadTooLarge(1 << 21)
        }
        do {
            _ = try await oversized.read()
            XCTFail("oversized output must not be parsed")
        } catch {
            XCTAssertEqual(error as? MobileDeviceError, .payloadTooLarge(1 << 21))
        }

        let slow = SystemProfilerAccessorySource(resolver: resolver) { throw MobileDeviceError.timedOut }
        do {
            _ = try await slow.read()
            XCTFail("a timeout must surface as a failure")
        } catch {
            XCTAssertEqual(error as? MobileDeviceError, .timedOut)
        }
    }
}
