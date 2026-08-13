import XCTest
@testable import ImpulsCore

/// The model's job is to refuse to invent anything. These tests are mostly
/// about what it declines to produce.
final class AppleDevicePowerModelTests: DeviceIdentityTestCase {

    // MARK: - Level normalization

    func testEveryValidPercentageSurvivesAndEveryImpossibleOneDoesNot() {
        XCTAssertEqual(AppleDeviceNormalizer.percentage(fromPercent: 0), 0)
        XCTAssertEqual(AppleDeviceNormalizer.percentage(fromPercent: 1), 1)
        XCTAssertEqual(AppleDeviceNormalizer.percentage(fromPercent: 100), 100)

        XCTAssertNil(AppleDeviceNormalizer.percentage(fromPercent: nil))
        XCTAssertNil(AppleDeviceNormalizer.percentage(fromPercent: -1))
        XCTAssertNil(AppleDeviceNormalizer.percentage(fromPercent: 101))
        // The value firmware uses for "I do not know", which must never become
        // 25500% or 255%.
        XCTAssertNil(AppleDeviceNormalizer.percentage(fromPercent: 255))
        XCTAssertNil(AppleDeviceNormalizer.percentage(fromPercent: Int.min))
    }

    func testFractionsBecomePercentagesAndNonNumbersBecomeNothing() {
        XCTAssertEqual(AppleDeviceNormalizer.percentage(fromFraction: 0), 0)
        XCTAssertEqual(AppleDeviceNormalizer.percentage(fromFraction: 0.74), 74)
        XCTAssertEqual(AppleDeviceNormalizer.percentage(fromFraction: 1), 100)

        XCTAssertNil(AppleDeviceNormalizer.percentage(fromFraction: -0.1))
        XCTAssertNil(AppleDeviceNormalizer.percentage(fromFraction: 1.01))
        XCTAssertNil(AppleDeviceNormalizer.percentage(fromFraction: Double.nan))
        XCTAssertNil(AppleDeviceNormalizer.percentage(fromFraction: Double.infinity))
        XCTAssertNil(AppleDeviceNormalizer.percentage(fromFraction: -Double.infinity))
    }

    func testInvalidPercentageBecomesNoComponentRatherThanAZeroOne() {
        XCTAssertNil(AppleDeviceNormalizer.component(kind: .left, percentage: -1))
        XCTAssertNil(AppleDeviceNormalizer.component(kind: .left, percentage: nil))
        // No percentage, but a real charging state is still information.
        XCTAssertNotNil(AppleDeviceNormalizer.component(kind: .left, percentage: nil, chargingState: .charging))
        // "Unknown" is not information.
        XCTAssertNil(AppleDeviceNormalizer.component(kind: .left, percentage: nil, chargingState: .unknown))
        XCTAssertEqual(AppleDeviceNormalizer.component(kind: .primary, percentage: 0)?.percentage, 0)
    }

    // MARK: - Components

    func testAirPodsCarryThreeSeparateBatteriesInDisplayOrder() {
        let device = Fixtures.airPods(left: 81, right: 76, chargingCase: 54)

        XCTAssertEqual(device.components.map(\.kind), [.left, .right, .chargingCase])
        XCTAssertEqual(device.components.map(\.percentage), [81, 76, 54])
        XCTAssertTrue(device.capabilities.contains(.multipleComponents))
        // The summary is the ear that dies first, not an average of the three.
        XCTAssertEqual(device.headlinePercentage, 54)
    }

    func testOneBudInTheCaseLeavesTheOtherComponentsAloneInsteadOfShowingZero() {
        let device = Fixtures.airPods(left: 81, right: nil, chargingCase: nil)

        XCTAssertEqual(device.components.map(\.kind), [.left])
        XCTAssertEqual(device.components.first?.percentage, 81)
        XCTAssertFalse(device.capabilities.contains(.multipleComponents))
    }

    func testAirPodsMaxIsASingleBatteryDeviceAndSaysSo() {
        let device = Fixtures.device(
            kind: .airPodsMax,
            components: [DeviceBatteryComponent(kind: .primary, percentage: 63, lastUpdated: Fixtures.noon)]
        )

        XCTAssertEqual(device.components.count, 1)
        XCTAssertEqual(device.headlinePercentage, 63)
        XCTAssertFalse(device.capabilities.contains(.multipleComponents))
    }

    func testAStaleCaseValueKeepsItsOwnTimestampSoTheInterfaceCanAgeIt() {
        let staleCase = Fixtures.noon.addingTimeInterval(-18 * 60)
        let device = Fixtures.device(
            kind: .airPodsPro,
            components: [
                DeviceBatteryComponent(kind: .left, percentage: 81, lastUpdated: Fixtures.noon),
                DeviceBatteryComponent(kind: .chargingCase, percentage: 54, lastUpdated: staleCase),
            ]
        )

        XCTAssertEqual(device.components.last?.lastUpdated, staleCase)
        XCTAssertNotEqual(device.components.first?.lastUpdated, device.components.last?.lastUpdated)
    }

    // MARK: - Categorical status

    func testCategoricalBatteryStatusIsRepresentableWithoutInventingAPercentage() {
        let tag = Fixtures.device(
            kind: .airTag,
            components: [DeviceBatteryComponent(kind: .primary, status: .low, lastUpdated: Fixtures.noon)]
        )

        XCTAssertNil(tag.headlinePercentage)
        XCTAssertEqual(tag.components.first?.status, .low)
        XCTAssertTrue(tag.capabilities.contains(.categoricalStatus))
        XCTAssertFalse(tag.capabilities.contains(.percentage))
    }

    // MARK: - Capabilities

    func testCapabilitiesDescribeTheReadingsThatActuallyExist() {
        let none = AppleDeviceNormalizer.capabilities(for: [])
        XCTAssertTrue(none.isEmpty)

        let charging = AppleDeviceNormalizer.capabilities(for: [
            DeviceBatteryComponent(kind: .primary, percentage: 40, chargingState: .charging)
        ])
        XCTAssertEqual(charging, [.percentage, .chargingState])

        let unknownCharging = AppleDeviceNormalizer.capabilities(for: [
            DeviceBatteryComponent(kind: .primary, percentage: 40, chargingState: .unknown)
        ])
        XCTAssertEqual(unknownCharging, [.percentage])
    }

    // MARK: - Names

    func testDeviceNamesAreBoundedButKeepCyrillicAndEmoji() {
        XCTAssertEqual(AppleDeviceNormalizer.displayName("iPhone Николая", fallback: "iPhone"), "iPhone Николая")
        XCTAssertEqual(AppleDeviceNormalizer.displayName("🎧 AirPods", fallback: "AirPods"), "🎧 AirPods")
        XCTAssertEqual(AppleDeviceNormalizer.displayName("   ", fallback: "iPad"), "iPad")
        XCTAssertEqual(AppleDeviceNormalizer.displayName(nil, fallback: "Mac"), "Mac")

        let long = String(repeating: "и", count: 400)
        XCTAssertEqual(
            AppleDeviceNormalizer.displayName(long, fallback: "iPhone").count,
            AppleDeviceNormalizer.maximumDisplayNameCharacters
        )
    }

    // MARK: - Identity

    func testTheLocalMacHasItsOwnIdentityAndNeedsNoSerialNumber() {
        XCTAssertTrue(AppleDeviceIdentity.localMac.isLocalMac)
        XCTAssertEqual(AppleDeviceIdentity.localMac.localPreferenceKey, "localMac")
    }

    func testAnIdentityNeverPrintsTheValueItWasDerivedFrom() {
        let resolver = DeviceIdentityResolver(
            service: "io.tumanov.impuls.tests.device-identity",
            account: "unit-test"
        )
        let udid = "00008120-000A1B2C3D4E5F60"
        guard let identity = resolver.identity(forRawIdentifier: udid, kind: .iPhone) else {
            return XCTFail("a non-empty identifier must resolve")
        }

        XCTAssertEqual("\(identity)", "AppleDeviceIdentity(redacted)")
        XCTAssertFalse(identity.debugDescription.contains(udid))
        XCTAssertFalse(identity.localPreferenceKey.contains(udid))
        XCTAssertFalse(identity.isLocalMac)
    }

    func testIdentityIsStableForOneDeviceAndDistinctAcrossDevicesAndKinds() {
        let resolver = DeviceIdentityResolver(
            service: "io.tumanov.impuls.tests.device-identity",
            account: "unit-test"
        )

        let phone = resolver.identity(forRawIdentifier: "AA:BB:CC:DD:EE:FF", kind: .iPhone)
        let sameAgain = resolver.identity(forRawIdentifier: "aa:bb:cc:dd:ee:ff", kind: .iPhone)
        let otherDevice = resolver.identity(forRawIdentifier: "AA:BB:CC:DD:EE:00", kind: .iPhone)
        let sameValueOtherKind = resolver.identity(forRawIdentifier: "AA:BB:CC:DD:EE:FF", kind: .magicMouse)

        XCTAssertEqual(phone, sameAgain, "the same device seen twice is one device")
        XCTAssertNotEqual(phone, otherDevice)
        XCTAssertNotEqual(phone, sameValueOtherKind)
        XCTAssertNil(resolver.identity(forRawIdentifier: "   ", kind: .iPhone))
    }
}

// MARK: - Fixtures

enum Fixtures {
    static let noon = Date(timeIntervalSince1970: 1_770_000_000)

    static func identity(_ seed: String) -> AppleDeviceIdentity {
        DeviceIdentityResolver(
            service: "io.tumanov.impuls.tests.device-identity",
            account: "unit-test"
        )
        .identity(forRawIdentifier: seed, kind: .unknown)!
    }

    static func device(
        identity: AppleDeviceIdentity? = nil,
        kind: AppleDeviceKind,
        name: String = "Device",
        connection: DeviceConnectionKind = .bluetooth,
        availability: DeviceAvailability = .connected,
        externalPower: DeviceExternalPowerState = .unknown,
        components: [DeviceBatteryComponent],
        lastUpdated: Date? = noon,
        source: DeviceDataSource = .ioRegistryAccessory
    ) -> AppleDeviceSnapshot {
        AppleDeviceSnapshot(
            identity: identity ?? self.identity(name),
            kind: kind,
            displayName: name,
            connection: connection,
            availability: availability,
            externalPower: externalPower,
            components: components,
            lastSeen: lastUpdated,
            lastUpdated: lastUpdated,
            source: source,
            capabilities: AppleDeviceNormalizer.capabilities(for: components)
        )
    }

    static func airPods(left: Int?, right: Int?, chargingCase: Int?) -> AppleDeviceSnapshot {
        let components = [
            AppleDeviceNormalizer.component(kind: .left, percentage: left, lastUpdated: noon),
            AppleDeviceNormalizer.component(kind: .right, percentage: right, lastUpdated: noon),
            AppleDeviceNormalizer.component(kind: .chargingCase, percentage: chargingCase, lastUpdated: noon),
        ].compactMap { $0 }
        return device(kind: .airPodsPro, name: "AirPods Pro", components: components)
    }
}
