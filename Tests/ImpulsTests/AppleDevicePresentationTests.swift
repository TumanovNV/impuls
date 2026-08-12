import XCTest
@testable import ImpulsCore

final class AppleDevicePresentationTests: XCTestCase {
    func testAirPodsPresentationIncludesOnlyComponentsThatActuallyArrived() {
        let device = Fixtures.airPods(left: nil, right: 87, chargingCase: nil)

        let value = AppleDevicePresentation.accessibilityValue(for: device, now: Fixtures.noon)

        XCTAssertTrue(value.contains(localized("Right")))
        XCTAssertTrue(value.contains("87%"))
        XCTAssertFalse(value.contains(localized("Left")))
        XCTAssertFalse(value.contains(localized("Case")))
        XCTAssertFalse(value.contains(device.identity.localPreferenceKey))
    }

    func testMobileDevicesAreBetaAndMissingDataNeverBecomesZero() {
        let missing = DeviceBatteryComponent(kind: .primary)

        XCTAssertTrue(AppleDevicePresentation.isBeta(.iPhone))
        XCTAssertTrue(AppleDevicePresentation.isBeta(.iPad))
        XCTAssertFalse(AppleDevicePresentation.isBeta(.airPodsPro))
        XCTAssertEqual(AppleDevicePresentation.readingTitle(missing), localized("No Current Reading"))
        XCTAssertNotEqual(AppleDevicePresentation.readingTitle(missing), "0%")
    }

    func testComponentFreshnessUsesItsOwnTimestampInsteadOfTheDeviceSummary() {
        let now = Fixtures.noon
        let staleCase = DeviceBatteryComponent(
            kind: .chargingCase,
            percentage: 60,
            lastUpdated: now.addingTimeInterval(-600)
        )

        XCTAssertEqual(
            AppleDevicePresentation.freshness(
                for: staleCase,
                availability: .connected,
                fallbackDate: now,
                now: now
            ),
            .stale
        )
        let age = AppleDevicePresentation.ageTitle(
            since: staleCase.lastUpdated,
            freshness: .stale,
            now: now,
            locale: Locale(identifier: "en_US"),
            abbreviated: true
        )
        XCTAssertTrue(age.contains(localized("Stale · %@", "").trimmingCharacters(in: .whitespaces)))
    }

    func testAccessibilityValueNamesChargeStateFreshnessAndConnectionButNoIdentity() {
        let component = DeviceBatteryComponent(
            kind: .primary,
            percentage: 69,
            chargingState: .charging,
            lastUpdated: Fixtures.noon
        )
        let phone = Fixtures.device(
            kind: .iPhone,
            name: "iPhone Николая",
            connection: .usb,
            components: [component],
            lastUpdated: Fixtures.noon,
            source: .mobileUSB
        )

        let value = AppleDevicePresentation.accessibilityValue(for: phone, now: Fixtures.noon)

        XCTAssertTrue(value.contains(localized("Beta")))
        XCTAssertTrue(value.contains("69%"))
        XCTAssertTrue(value.contains(localized("Charging")))
        XCTAssertTrue(value.contains(localized("USB")))
        XCTAssertFalse(value.contains(phone.identity.localPreferenceKey))
    }
}
