import XCTest
@testable import ImpulsCore

final class AppleDevicePresentationTests: XCTestCase {
    func testGenericAirPodsModelsAreHiddenFromTheDeviceCard() {
        for model in ["Headphones", "Headset", "Audio", "AirPods Pro"] {
            let device = presentationDevice(
                kind: .airPodsPro,
                name: "AirPods Pro (TumanovNV)",
                modelName: model
            )

            XCTAssertNil(AppleDevicePresentation.modelTitle(for: device), model)
        }
    }

    func testUsefulAirPodsModelIsPreserved() {
        let device = presentationDevice(
            kind: .airPodsPro,
            name: "Николай — AirPods",
            modelName: "AirPods Pro 2"
        )

        XCTAssertEqual(AppleDevicePresentation.modelTitle(for: device), "AirPods Pro 2")
    }

    func testGenericMagicAccessoryModelsAreHidden() {
        let devices: [(AppleDeviceKind, String, String)] = [
            (.magicMouse, "Magic Mouse", "Mouse"),
            (.magicKeyboard, "Magic Keyboard", "Keyboard"),
            (.magicTrackpad, "Magic Trackpad", "Trackpad"),
        ]

        for (kind, name, model) in devices {
            XCTAssertNil(
                AppleDevicePresentation.modelTitle(
                    for: presentationDevice(kind: kind, name: name, modelName: model)
                ),
                model
            )
        }
    }

    func testMobileProductTypesBecomeHumanFacingKindTitles() {
        let phone = presentationDevice(
            kind: .iPhone,
            name: "iPhone Николая",
            modelName: "iPhone17,1"
        )
        let tablet = presentationDevice(
            kind: .iPad,
            name: "iPad Николая",
            modelName: "iPad16,3"
        )

        XCTAssertEqual(AppleDevicePresentation.modelTitle(for: phone), localized("iPhone"))
        XCTAssertEqual(AppleDevicePresentation.modelTitle(for: tablet), localized("iPad"))
    }

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

    func testSystemProfilerAgeDescribesAReportInsteadOfPhysicalMeasurement() {
        let title = AppleDevicePresentation.ageTitle(
            since: Fixtures.noon,
            freshness: .fresh,
            source: .systemProfilerAccessory,
            now: Fixtures.noon,
            locale: Locale(identifier: "en_US")
        )

        XCTAssertTrue(title.contains("macOS"))
        XCTAssertTrue(title.contains(localized("Reported by macOS %@", "").trimmingCharacters(in: .whitespaces)))
        XCTAssertFalse(title.contains(localized("Updated %@", "").trimmingCharacters(in: .whitespaces)))
    }

    func testAbbreviatedAgeIsNonnegativeAndClampsFutureClockSkewToZero() {
        let locale = Locale(identifier: "ru_RU")
        let past = AppleDevicePresentation.ageTitle(
            since: Fixtures.noon.addingTimeInterval(-3),
            freshness: .fresh,
            now: Fixtures.noon,
            locale: locale,
            abbreviated: true
        )
        let future = AppleDevicePresentation.ageTitle(
            since: Fixtures.noon.addingTimeInterval(3),
            freshness: .fresh,
            now: Fixtures.noon,
            locale: locale,
            abbreviated: true
        )

        XCTAssertTrue(past.contains("3"))
        XCTAssertFalse(past.contains("-"))
        XCTAssertTrue(future.contains("0"))
        XCTAssertFalse(future.contains("-"))
        XCTAssertFalse(future.contains("+"))
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

    private func presentationDevice(
        kind: AppleDeviceKind,
        name: String,
        modelName: String
    ) -> AppleDeviceSnapshot {
        AppleDeviceSnapshot(
            identity: Fixtures.identity("\(kind.rawValue)-\(modelName)"),
            kind: kind,
            displayName: name,
            modelName: modelName,
            connection: kind == .iPhone || kind == .iPad ? .usb : .bluetooth,
            components: [DeviceBatteryComponent(kind: .primary, percentage: 50)],
            lastSeen: Fixtures.noon,
            lastUpdated: Fixtures.noon,
            source: kind == .iPhone || kind == .iPad ? .mobileUSB : .systemProfilerAccessory
        )
    }
}
