import XCTest
@testable import ImpulsCore

/// Fixtures rather than hardware.
///
/// These property dictionaries are sanitised copies of the shape the registry
/// publishes: no real Bluetooth address, no real serial number. What they test
/// is mostly the parser's willingness to give up — on a missing key, on a value
/// of the wrong type, on a node that is not an Apple accessory at all.
final class IORegistryAccessoryTests: DeviceIdentityTestCase {
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

    // MARK: - Real Mac mini hardware (sanitised)
    //
    // The exact property shape `AppleDeviceManagementHIDEventService`
    // published for a Magic Keyboard, Magic Mouse and Magic Trackpad on a real
    // Mac mini (macOS Tahoe 26, 2026-08): `VendorID = 76` (Bluetooth SIG,
    // `0x004C`, not the USB-IF `0x05AC` this mapper used to require), `Product`
    // present but an empty string, and a stable `ProductID`. No address,
    // serial number or other identifier from that machine appears below.

    func testMagicKeyboardFromRealMacMiniHardwareIsRecognisedByProductID() {
        let device = map(.realMacMiniAccessory(productID: 0x0267, percent: 24))

        XCTAssertEqual(device?.kind, .magicKeyboard)
        XCTAssertEqual(device?.displayName, "Magic Keyboard", "an empty Product string still earns a real name")
        XCTAssertEqual(device?.headlinePercentage, 24)
        XCTAssertEqual(device?.connection, .bluetooth)
        XCTAssertEqual(device?.source, .ioRegistryAccessory)
    }

    func testMagicMouseFromRealMacMiniHardwareIsRecognisedByProductID() {
        let device = map(.realMacMiniAccessory(productID: 0x0269, percent: 85))

        XCTAssertEqual(device?.kind, .magicMouse)
        XCTAssertEqual(device?.displayName, "Magic Mouse")
        XCTAssertEqual(device?.headlinePercentage, 85)
    }

    func testMagicTrackpadFromRealMacMiniHardwareIsRecognisedByProductID() {
        let device = map(.realMacMiniAccessory(productID: 0x0265, percent: 63))

        XCTAssertEqual(device?.kind, .magicTrackpad)
        XCTAssertEqual(device?.displayName, "Magic Trackpad")
        XCTAssertEqual(device?.headlinePercentage, 63)
    }

    func testAnEmptyProductStringIsTreatedTheSameAsAMissingOne() {
        var properties = Fixture.realMacMiniAccessory(productID: 0x0269, percent: 61).properties
        properties[IORegistryAccessoryMapper.Key.product] = ""

        let device = IORegistryAccessoryMapper.device(from: properties, now: now, resolver: resolver)

        XCTAssertEqual(device?.kind, .magicMouse)
        XCTAssertNil(device?.modelName)
    }

    func testABluetoothProductIDOutsideTheKnownTableStaysUnknownRatherThanGuessed() {
        var properties = Fixture.realMacMiniAccessory(productID: 0x0269, percent: 61).properties
        properties[IORegistryAccessoryMapper.Key.productID] = NSNumber(value: 0x9999)

        let device = IORegistryAccessoryMapper.device(from: properties, now: now, resolver: resolver)

        XCTAssertEqual(device?.kind, .unknown, "an unmeasured product ID is not evidence of anything")
        XCTAssertEqual(device?.displayName, "Apple device")
    }

    func testTheBluetoothProductIDFallbackNeverAppliesInTheUSBVendorNamespace() {
        var properties = Fixture.realMacMiniAccessory(productID: 0x0269, percent: 61).properties
        properties[IORegistryAccessoryMapper.Key.vendorID] = NSNumber(value: IORegistryAccessoryMapper.appleUSBVendorID)

        let device = IORegistryAccessoryMapper.device(from: properties, now: now, resolver: resolver)

        XCTAssertEqual(
            device?.kind,
            .unknown,
            "the same numeric product ID means something else in the USB namespace"
        )
    }

    // MARK: - Vendor identifier namespaces

    func testTheAppleBluetoothVendorIdentifierIsAccepted() {
        XCTAssertTrue(
            IORegistryAccessoryMapper.isAppleAccessory(Fixture.magicMouse(percent: 61).properties)
        )
        XCTAssertEqual(IORegistryAccessoryMapper.appleBluetoothVendorID, 0x004C)
    }

    func testTheExistingAppleUSBVendorIdentifierStillWorks() {
        var properties = Fixture.accessory(product: "Magic Keyboard", percent: 88).properties
        properties[IORegistryAccessoryMapper.Key.vendorID] = NSNumber(value: IORegistryAccessoryMapper.appleUSBVendorID)

        let device = IORegistryAccessoryMapper.device(from: properties, now: now, resolver: resolver)

        XCTAssertEqual(device?.kind, .magicKeyboard, "a wired accessory in the USB vendor namespace must keep working")
        XCTAssertEqual(device?.headlinePercentage, 88)
    }

    func testANonAppleBluetoothHIDDeviceIsIgnored() {
        var properties = Fixture.realMacMiniAccessory(productID: 0x0269, percent: 61).properties
        properties[IORegistryAccessoryMapper.Key.vendorID] = NSNumber(value: 0x046D) // Logitech
        properties[IORegistryAccessoryMapper.Key.manufacturer] = "Logitech"

        XCTAssertNil(IORegistryAccessoryMapper.device(from: properties, now: now, resolver: resolver))
    }

    // MARK: - The explicit Built-In flag

    func testAnExplicitBuiltInFlagRejectsTheAccessoryEvenOverBluetoothTransport() {
        var properties = Fixture.realMacMiniAccessory(productID: 0x0269, percent: 61).properties
        properties[IORegistryAccessoryMapper.Key.builtIn] = NSNumber(value: true)

        XCTAssertNil(
            IORegistryAccessoryMapper.device(from: properties, now: now, resolver: resolver),
            "Apple's own Built-In flag is a stronger signal than the transport string"
        )
    }

    func testAnExplicitBuiltInFalseFlagDoesNotRejectAnOtherwiseValidAccessory() {
        var properties = Fixture.realMacMiniAccessory(productID: 0x0269, percent: 61).properties
        properties[IORegistryAccessoryMapper.Key.builtIn] = NSNumber(value: false)

        XCTAssertNotNil(IORegistryAccessoryMapper.device(from: properties, now: now, resolver: resolver))
    }

    func testAnIntegerBoxedValueUnderBuiltInDoesNotFalselyReadAsTrue() {
        var properties = Fixture.realMacMiniAccessory(productID: 0x0269, percent: 61).properties
        // Not a real shape this key takes, but the coercion must stay total:
        // an Int8-boxed NSNumber(1) bridges to `true` through a naive `as?
        // Bool` and must not be mistaken for the real CFBoolean this key uses.
        properties[IORegistryAccessoryMapper.Key.builtIn] = NSNumber(value: Int8(1))

        XCTAssertNotNil(
            IORegistryAccessoryMapper.device(from: properties, now: now, resolver: resolver),
            "a non-boolean value under Built-In must fall back to the transport check, not be read as true"
        )
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

    /// The coercion every system-dictionary reader shares.
    ///
    /// `Int(someDouble)` is a trap rather than an overflow outside `Int`'s
    /// range, so a driver publishing an unexpected magnitude under a key we read
    /// would abort the process. Each class below has to read as absent instead.
    func testRegistryNumberIsTotalForEveryValueASystemDictionaryCanPublish() {
        XCTAssertNil(RegistryNumber.integer(Double.nan))
        XCTAssertNil(RegistryNumber.integer(Double.infinity))
        XCTAssertNil(RegistryNumber.integer(-Double.infinity))
        // A flag read as a number would be a wrong value, not a missing one.
        XCTAssertNil(RegistryNumber.integer(NSNumber(value: true)))
        XCTAssertNil(RegistryNumber.integer(NSNumber(value: false)))
        // Beyond `Int`, in both directions: the trap this guard exists for.
        XCTAssertNil(RegistryNumber.integer(1e30))
        XCTAssertNil(RegistryNumber.integer(-1e30))
        XCTAssertNil(RegistryNumber.integer(Double.greatestFiniteMagnitude))
        XCTAssertNil(RegistryNumber.integer(-Double.greatestFiniteMagnitude))
        XCTAssertNil(RegistryNumber.integer(nil))
        XCTAssertNil(RegistryNumber.integer("61"))

        // Ordinary battery readings still convert, including the fractional
        // ones a driver may publish.
        XCTAssertEqual(RegistryNumber.integer(NSNumber(value: 61)), 61)
        XCTAssertEqual(RegistryNumber.integer(NSNumber(value: 0)), 0)
        XCTAssertEqual(RegistryNumber.integer(NSNumber(value: 100)), 100)
        XCTAssertEqual(RegistryNumber.integer(NSNumber(value: 4_311)), 4_311)
        XCTAssertEqual(RegistryNumber.integer(NSNumber(value: 12_486)), 12_486)
        XCTAssertEqual(RegistryNumber.integer(NSNumber(value: 342)), 342)
        XCTAssertEqual(RegistryNumber.integer(NSNumber(value: 60.6)), 61)
        XCTAssertEqual(RegistryNumber.integer(NSNumber(value: -20)), -20)

        // `double` shares the rejections but keeps the fraction.
        XCTAssertNil(RegistryNumber.double(Double.nan))
        XCTAssertNil(RegistryNumber.double(NSNumber(value: true)))
        XCTAssertEqual(RegistryNumber.double(NSNumber(value: 3_041.5)), 3_041.5)
    }

    /// The generic helper carries no range of its own, so the domain owner has
    /// to keep rejecting values that are numerically fine but not battery levels.
    func testWideningTheCoercionDidNotWidenWhatCountsAsAPercentage() {
        XCTAssertEqual(RegistryNumber.integer(NSNumber(value: 5_000)), 5_000)
        XCTAssertNil(AppleDeviceNormalizer.percentage(fromPercent: 5_000))
        XCTAssertNil(AppleDeviceNormalizer.percentage(fromPercent: -1))
        XCTAssertEqual(AppleDeviceNormalizer.percentage(fromPercent: 61), 61)
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
                IORegistryAccessoryMapper.Key.vendorID: NSNumber(value: IORegistryAccessoryMapper.appleBluetoothVendorID),
                IORegistryAccessoryMapper.Key.transport: "Bluetooth",
                IORegistryAccessoryMapper.Key.deviceAddress: address,
            ]
            if let percent { properties[IORegistryAccessoryMapper.Key.batteryPercent] = NSNumber(value: percent) }
            return Fixture(properties: properties)
        }

        static func magicMouse(percent: Int) -> Fixture {
            accessory(product: "Magic Mouse", percent: percent)
        }

        /// The exact shape a real Mac mini's registry publishes for a Magic
        /// Keyboard, Magic Mouse or Magic Trackpad: `VendorID` in the
        /// Bluetooth SIG namespace, `Product` present but empty, and the
        /// kind carried only by `ProductID`. No address from real hardware.
        static func realMacMiniAccessory(
            productID: Int,
            percent: Int,
            address: String = "AA:BB:CC:00:11:22"
        ) -> Fixture {
            Fixture(properties: [
                IORegistryAccessoryMapper.Key.product: "",
                IORegistryAccessoryMapper.Key.productID: NSNumber(value: productID),
                IORegistryAccessoryMapper.Key.vendorID: NSNumber(value: IORegistryAccessoryMapper.appleBluetoothVendorID),
                IORegistryAccessoryMapper.Key.manufacturer: "Apple Inc.",
                IORegistryAccessoryMapper.Key.transport: "Bluetooth",
                IORegistryAccessoryMapper.Key.deviceAddress: address,
                IORegistryAccessoryMapper.Key.builtIn: NSNumber(value: false),
                IORegistryAccessoryMapper.Key.batteryPercent: NSNumber(value: percent),
            ])
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
final class AppleAccessoryBatteryProviderTests: DeviceIdentityTestCase {
    private var resolver: DeviceIdentityResolver {
        DeviceIdentityResolver(service: "io.tumanov.impuls.tests.device-identity", account: "unit-test")
    }

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

    func testManualRefreshRerunsSystemProfilerAndReplacesAirPodsTopology() async {
        let runner = MutableSystemProfilerRunner(data: profilerJSON(left: 87))
        let profiler = SystemProfilerAccessorySource(
            resolver: resolver,
            runner: { try runner.run() }
        )
        let provider = AppleAccessoryBatteryProvider(
            registrySource: FakeAccessorySource(devices: []),
            profilerSource: profiler
        )
        let collector = UpdateCollector()

        provider.start { collector.append($0) }
        await collector.wait(forUpdateCount: 1, in: self)
        XCTAssertEqual(collector.updates.last?.devices.first?.components.map(\.kind), [.left])

        runner.data = profilerJSON(left: 87, right: 91)
        provider.refresh()
        await collector.wait(forUpdateCount: 2, in: self)
        XCTAssertEqual(collector.updates.last?.devices.first?.components.map(\.kind), [.left, .right])

        runner.data = profilerJSON(left: 87)
        provider.refresh()
        await collector.wait(forUpdateCount: 3, in: self)
        XCTAssertEqual(collector.updates.last?.devices.first?.components.map(\.kind), [.left])
        XCTAssertEqual(runner.readCount, 3, "every explicit refresh must execute system_profiler")
        provider.stop()
    }

    func testSystemProfilerFailureKeepsTheLastSuccessfulAirPodsTopology() async {
        let runner = MutableSystemProfilerRunner(data: profilerJSON(left: 87, right: 91))
        let profiler = SystemProfilerAccessorySource(
            resolver: resolver,
            runner: { try runner.run() }
        )
        let provider = AppleAccessoryBatteryProvider(
            registrySource: FakeAccessorySource(devices: []),
            profilerSource: profiler
        )
        let collector = UpdateCollector()

        provider.start { collector.append($0) }
        await collector.wait(forUpdateCount: 1, in: self)
        runner.shouldThrow = true
        provider.refresh()
        await collector.wait(forUpdateCount: 2, in: self)

        XCTAssertEqual(collector.updates.last?.status, .temporarilyFailed)
        XCTAssertEqual(collector.updates.last?.devices.first?.components.map(\.kind), [.left, .right])
        XCTAssertEqual(runner.readCount, 2)
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
        // The test resolver, not the shared one: the default writes the shipping
        // app's own device-identity key into the login keychain, which a test
        // run has no business creating on a machine that has never run Impuls.
        let devices = try await IORegistryAccessorySource(resolver: resolver).read()

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
        let devices = try await IORegistryAccessorySource(resolver: resolver).read()

        print("PROBE \(IORegistryAccessoryMapper.serviceClass) nodes: \(matching)")
        print("PROBE nodes publishing a battery: \(devices.count)")
        for device in devices {
            let components = device.components
                .map { "\($0.kind.rawValue)=\($0.percentage.map(String.init) ?? "nil")" }
                .joined(separator: " ")
            print("PROBE   \(device.kind.rawValue) \"\(device.displayName)\" — \(components)")
        }
    }

    // MARK: - The notification callback's context outlives the provider

    /// The residual risk behind the teardown change: IOKit keeps the callback
    /// context pointer for the life of the registration and cannot be told the
    /// provider has gone. It used to be `Unmanaged.passUnretained(self)`, so a
    /// notification delivered while the provider was being released resolved a
    /// dead object.
    ///
    /// A full IOKit test would need a real accessory to connect and disconnect
    /// on cue, which is hardware QA, not a unit test. What is deterministic —
    /// and what the safety actually rests on — is the box: it must never hand
    /// back a provider that has been released or torn down.
    @MainActor
    func testTheNotificationContextNeverHandsBackAReleasedProvider() {
        var provider: AppleAccessoryBatteryProvider? = AppleAccessoryBatteryProvider(
            registrySource: FakeAccessorySource(devices: []),
            profilerSource: nil
        )
        let context = AccessoryNotificationContext(provider: provider!)
        XCTAssertNotNil(context.provider, "while the provider is alive the callback has to reach it")

        provider = nil

        XCTAssertNil(
            context.provider,
            "the box holds the provider weakly, so a late callback reads nil instead of a released object"
        )
    }

    /// Teardown severs the box before anything else is released, so a callback
    /// already queued behind it is inert even though the provider still exists.
    @MainActor
    func testInvalidatingTheContextSilencesCallbacksBeforeTheProviderGoesAway() {
        let provider = AppleAccessoryBatteryProvider(
            registrySource: FakeAccessorySource(devices: []),
            profilerSource: nil
        )
        let context = AccessoryNotificationContext(provider: provider)

        context.invalidate()
        XCTAssertNil(context.provider, "teardown has begun, so delivery stops reaching the provider")

        // Idempotent: `stop()` and `deinit` both run the teardown.
        context.invalidate()
        XCTAssertNil(context.provider)

        // And it is a one-way transition — nothing puts the provider back.
        withExtendedLifetime(provider) {
            XCTAssertNil(context.provider, "an invalidated box never points at a provider again")
        }
    }

    /// `stop()` and `deinit` both tear down, and the coordinator calls `stop()`
    /// on every disable. Running the whole cycle twice must not trap on a
    /// double release of the port, the iterators or the context.
    @MainActor
    func testStartingAndStoppingRepeatedlyIsSafe() {
        let provider = AppleAccessoryBatteryProvider(
            registrySource: FakeAccessorySource(devices: []),
            profilerSource: nil
        )

        for _ in 0..<3 {
            provider.start { _ in }
            provider.stop()
            // Second stop with nothing left to release.
            provider.stop()
        }

        XCTAssertEqual(provider.status, .disabled)
    }

    func testTheProviderPollsQuicklyOnlyWhileItsPanelIsActive() {
        let provider = AppleAccessoryBatteryProvider(registrySource: FakeAccessorySource(devices: []), profilerSource: nil)

        guard case .polled(let active, let idle) = provider.refreshBehavior else {
            return XCTFail("the registry does not notify on level changes, so this has to be polled")
        }
        XCTAssertEqual(active, 10, "AirPods topology can arrive late while the user is watching")
        XCTAssertEqual(idle, 600, "a closed panel is not worth repeated process spawns")
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

    private func profilerJSON(left: Int? = nil, right: Int? = nil) -> Data {
        var batteries: [String] = []
        if let left { batteries.append("\"device_batteryLevelLeft\":\"\(left) %\"") }
        if let right { batteries.append("\"device_batteryLevelRight\":\"\(right) %\"") }
        let fields = ([
            "\"device_address\":\"aa-bb-cc-dd-ee-ff\"",
            "\"device_vendorID\":\"0x004C\"",
        ] + batteries).joined(separator: ",")
        return Data("{\"SPBluetoothDataType\":[{\"device_connected\":[{\"AirPods Pro\":{\(fields)}}]}]}".utf8)
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

private final class MutableSystemProfilerRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var storedData: Data
    private var storedShouldThrow = false
    private var storedReadCount = 0

    init(data: Data) {
        storedData = data
    }

    var data: Data {
        get { lock.withLock { storedData } }
        set { lock.withLock { storedData = newValue } }
    }

    var shouldThrow: Bool {
        get { lock.withLock { storedShouldThrow } }
        set { lock.withLock { storedShouldThrow = newValue } }
    }

    var readCount: Int {
        lock.withLock { storedReadCount }
    }

    struct ReadFailure: Error {}

    func run() throws -> Data {
        try lock.withLock {
            storedReadCount += 1
            if storedShouldThrow { throw ReadFailure() }
            return storedData
        }
    }
}

/// The `system_profiler` path, on fixtures and on this Mac.
final class SystemProfilerAccessoryTests: DeviceIdentityTestCase {
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

    /// The vendor identifier decides how a device is *named*, not whether it
    /// is shown.
    ///
    /// This used to assert the opposite: both devices below were dropped for
    /// not being Apple, despite the system reporting a real battery for each.
    /// That was the defect in #108 — a third-party headset macOS reads the
    /// battery of was filtered out before the battery was ever looked at. What
    /// still holds is that a non-Apple device gets no Apple classification: it
    /// is presented by the class the system stated, under its own name.
    func testANonAppleAccessoryWithABatteryIsShownWithGenericClassification() throws {
        let parsed = try devices("""
        {"SPBluetoothDataType":[{"device_connected":[{"Third-Party Buds":{
          "device_address":"11-22-33-44-55-66",
          "device_minorType":"Headphones",
          "device_batteryLevelMain":"55 %",
          "device_vendorID":"0x046D"}}]},{"device_connected":[{"No Vendor At All":{
          "device_address":"22-33-44-55-66-77",
          "device_batteryLevelMain":"55 %"}}]}]}
        """)

        XCTAssertEqual(parsed.count, 2, "a readable battery is showable whoever made the device")
        XCTAssertEqual(parsed.map(\.kind), [.headphones, .accessory])
        XCTAssertEqual(parsed.map(\.displayName), ["Third-Party Buds", "No Vendor At All"])
        XCTAssertEqual(parsed.compactMap { $0.components.first?.percentage }, [55, 55])
        XCTAssertEqual(parsed.map(\.externalPower), [.unknown, .unknown])
    }

    /// The other half of the same rule: no battery, no card — for any vendor.
    func testANonAppleAccessoryWithoutABatteryIsStillNotShown() throws {
        let parsed = try devices("""
        {"SPBluetoothDataType":[{"device_connected":[{"Third-Party Buds":{
          "device_address":"11-22-33-44-55-66",
          "device_minorType":"Headphones",
          "device_vendorID":"0x046D"}}]}]}
        """)

        XCTAssertTrue(parsed.isEmpty, "dropping it for having no reading is correct; dropping it for its vendor was not")
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

    // MARK: - The process boundary

    /// These run real child processes, because that is the boundary being
    /// tested. A closure that throws `.timedOut` on cue proves nothing about
    /// whether a child that never exits, or one that floods its pipe, can hang
    /// the caller — and both of those were live defects in the first version.

    func testAWellBehavedToolReturnsItsOutput() throws {
        let runner = BoundedProcess(
            executablePath: "/bin/echo",
            arguments: ["impuls"],
            timeout: 5,
            maximumOutputBytes: 1024,
            maximumErrorBytes: 1024
        )

        let output = try runner.run()

        XCTAssertEqual(String(data: output, encoding: .utf8), "impuls\n")
    }

    func testAToolThatFailsIsAFailureAndNotAnEmptyAnswer() {
        let runner = BoundedProcess(
            executablePath: "/usr/bin/false",
            arguments: [],
            timeout: 5,
            maximumOutputBytes: 1024,
            maximumErrorBytes: 1024
        )

        XCTAssertThrowsError(try runner.run()) { error in
            XCTAssertEqual(error as? MobileDeviceError, .transportUnavailable)
        }
    }

    func testAToolThatDoesNotFinishIsKilledWithinItsDeadline() {
        let runner = BoundedProcess(
            executablePath: "/bin/sleep",
            arguments: ["30"],
            timeout: 0.3,
            maximumOutputBytes: 1024,
            maximumErrorBytes: 1024
        )

        let started = Date()
        XCTAssertThrowsError(try runner.run()) { error in
            XCTAssertEqual(error as? MobileDeviceError, .timedOut)
        }
        // The deadline is on the child's life, not on end-of-file arriving:
        // `sleep` holds its stdout open and says nothing, which is exactly the
        // shape that used to wait forever.
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the deadline did not apply to the process")
    }

    func testAToolThatFloodsItsPipeIsStoppedInsteadOfBlockingForever() {
        let runner = BoundedProcess(
            executablePath: "/usr/bin/yes",
            arguments: ["impuls"],
            timeout: 10,
            maximumOutputBytes: 64 * 1024,
            maximumErrorBytes: 1024
        )

        let started = Date()
        XCTAssertThrowsError(try runner.run()) { error in
            guard case .payloadTooLarge = error as? MobileDeviceError else {
                return XCTFail("endless output must be refused as oversized")
            }
        }
        // Well inside the 10 s deadline: passing the limit terminates the child
        // immediately, and the reader keeps draining so the child can never
        // block on a full pipe on its way out.
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "oversized output was not stopped promptly")
    }

    func testAMissingToolIsUnavailableRatherThanACrash() {
        let runner = BoundedProcess(
            executablePath: "/usr/sbin/definitely-not-a-tool-on-this-mac",
            arguments: [],
            timeout: 1,
            maximumOutputBytes: 1024,
            maximumErrorBytes: 1024
        )

        XCTAssertThrowsError(try runner.run()) { error in
            XCTAssertEqual(error as? MobileDeviceError, .transportUnavailable)
        }
    }

    func testTheShippingConfigurationIsTheOneThatWasMeasured() {
        let runner = BoundedProcess.systemProfiler()

        XCTAssertEqual(runner.executablePath, "/usr/sbin/system_profiler")
        XCTAssertEqual(runner.arguments, ["-json", "SPBluetoothDataType"])
        XCTAssertFalse(runner.executablePath.contains("sh"), "no shell is involved at any point")
        XCTAssertGreaterThan(runner.timeout, 0)
    }
}
