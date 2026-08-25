import Foundation
import XCTest
@testable import ImpulsCore

/// A battery macOS can read is showable whoever made the device (#108).
///
/// Every address below is a documentation-style placeholder, never a real
/// Bluetooth address: identity is derived from it, so a fixture must not carry
/// hardware anyone owns.
final class ThirdPartyBluetoothBatteryTests: DeviceIdentityTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    /// The test keychain entry, never the shipping one.
    private let resolver = DeviceIdentityResolver(
        service: "io.tumanov.impuls.tests.device-identity",
        account: "third-party-bluetooth"
    )

    private func devices(_ json: String) throws -> [AppleDeviceSnapshot] {
        try SystemProfilerAccessoryParser.devices(fromJSON: Data(json.utf8), now: now, resolver: resolver)
    }

    // MARK: - Third-party hardware is shown when the system reports a battery

    func testThirdPartyHeadphonesWithABatteryAreShown() throws {
        let parsed = try devices("""
        {"SPBluetoothDataType":[{"device_connected":[{"Studio Headset":{
          "device_address":"00-00-5e-00-53-01",
          "device_minorType":"Headset",
          "device_batteryLevelMain":"73 %"}}]}]}
        """)

        XCTAssertEqual(parsed.count, 1, "a readable battery is a readable battery, Apple or not")
        let device = try XCTUnwrap(parsed.first)
        XCTAssertEqual(device.kind, .headphones, "classified from device_minorType, not from a brand guess")
        XCTAssertEqual(device.displayName, "Studio Headset", "the real user-visible name survives")
        XCTAssertEqual(device.components.map(\.kind), [.primary])
        XCTAssertEqual(device.components.first?.percentage, 73)
        XCTAssertEqual(device.externalPower, .unknown, "this output never states charging, for any vendor")
    }

    func testThirdPartyKeyboardAndMouseAreClassifiedFromTheSystemsOwnClass() throws {
        let parsed = try devices("""
        {"SPBluetoothDataType":[{"device_connected":[
          {"Desk Keyboard":{"device_address":"00-00-5e-00-53-02",
                            "device_minorType":"Keyboard",
                            "device_batteryLevelMain":"55 %"}},
          {"Desk Mouse":{"device_address":"00-00-5e-00-53-03",
                         "device_minorType":"Mouse",
                         "device_batteryLevelMain":"41 %"}}]}]}
        """)

        XCTAssertEqual(parsed.map(\.kind), [.keyboard, .mouse])
        XCTAssertEqual(parsed.map(\.displayName), ["Desk Keyboard", "Desk Mouse"])
        XCTAssertEqual(parsed.compactMap { $0.components.first?.percentage }, [55, 41])
    }

    /// A battery on a device whose class the source did not state is still a
    /// battery. It gets the neutral card rather than a guessed category.
    func testUnclassifiedThirdPartyAccessoryWithABatteryGetsAGenericCard() throws {
        let parsed = try devices("""
        {"SPBluetoothDataType":[{"device_connected":[{"Field Recorder":{
          "device_address":"00-00-5e-00-53-04",
          "device_batteryLevelMain":"12 %"}}]}]}
        """)

        let device = try XCTUnwrap(parsed.first)
        XCTAssertEqual(device.kind, .accessory)
        XCTAssertEqual(device.displayName, "Field Recorder")
        XCTAssertEqual(device.components.first?.percentage, 12)
    }

    func testThirdPartyComponentBatteriesAreKeptSeparate() throws {
        let parsed = try devices("""
        {"SPBluetoothDataType":[{"device_connected":[{"Sport Buds":{
          "device_address":"00-00-5e-00-53-05",
          "device_minorType":"Headphones",
          "device_batteryLevelLeft":"80 %",
          "device_batteryLevelRight":"78 %",
          "device_batteryLevelCase":"90 %"}}]}]}
        """)

        let device = try XCTUnwrap(parsed.first)
        XCTAssertEqual(device.kind, .headphones)
        XCTAssertEqual(device.components.map(\.kind), [.left, .right, .chargingCase])
        XCTAssertEqual(device.components.compactMap(\.percentage), [80, 78, 90])
    }

    // MARK: - Honesty about what is not there

    /// The device from the reported case: connected, named, classified, and
    /// carrying no battery field at all. It must produce no card rather than a
    /// card reading 0 %.
    func testThirdPartyDeviceWithoutABatteryProducesNoCard() throws {
        let parsed = try devices("""
        {"SPBluetoothDataType":[{"device_connected":[{"Immersive Headset":{
          "device_address":"00-00-5e-00-53-06",
          "device_minorType":"Headset",
          "device_rssi":-52}}]}]}
        """)

        XCTAssertTrue(parsed.isEmpty, "no reading is no device — never a fabricated 0%")
    }

    func testOutOfRangeThirdPartyPercentagesAreRejected() throws {
        for value in ["-5 %", "150 %", "not a number", ""] {
            let parsed = try devices("""
            {"SPBluetoothDataType":[{"device_connected":[{"Odd Device":{
              "device_address":"00-00-5e-00-53-07",
              "device_minorType":"Headset",
              "device_batteryLevelMain":"\(value)"}}]}]}
            """)
            XCTAssertTrue(parsed.isEmpty, "\(value) is not a battery level")
        }
    }

    func testAThirdPartyDeviceNeverClaimsCharging() throws {
        let parsed = try devices("""
        {"SPBluetoothDataType":[{"device_connected":[{"Powered Headset":{
          "device_address":"00-00-5e-00-53-08",
          "device_minorType":"Headset",
          "device_batteryLevelMain":"100 %"}}]}]}
        """)

        XCTAssertEqual(parsed.first?.externalPower, .unknown, "100% is not evidence of charging")
    }

    /// A product name is not brand evidence. A third-party device is free to
    /// call itself anything, so classification must ignore the name entirely.
    func testAThirdPartyNameThatImitatesAppleIsNotClassifiedAsApple() throws {
        let parsed = try devices("""
        {"SPBluetoothDataType":[{"device_connected":[{"AirPods Pro Max Ultra":{
          "device_address":"00-00-5e-00-53-09",
          "device_minorType":"Headset",
          "device_batteryLevelMain":"64 %"}}]}]}
        """)

        let device = try XCTUnwrap(parsed.first)
        XCTAssertEqual(device.kind, .headphones, "no Apple vendor id, so no Apple classification")
        XCTAssertEqual(device.displayName, "AirPods Pro Max Ultra", "its own name is still its name")
    }

    // MARK: - Existing Apple behaviour is untouched

    func testAppleAccessoriesKeepTheirExistingClassification() throws {
        let parsed = try devices("""
        {"SPBluetoothDataType":[{"device_connected":[
          {"AirPods Pro (Owner)":{"device_address":"00-00-5e-00-53-0a",
                                  "device_vendorID":"0x004C",
                                  "device_minorType":"Headphones",
                                  "device_batteryLevelRight":"87 %"}},
          {"Magic Mouse":{"device_address":"00-00-5e-00-53-0b",
                          "device_vendorID":"0x004C",
                          "device_minorType":"Mouse",
                          "device_batteryLevelMain":"64 %"}}]}]}
        """)

        XCTAssertEqual(parsed.map(\.kind), [.airPodsPro, .magicMouse],
                       "Apple vendorship still selects the Apple naming path")
        XCTAssertEqual(parsed.map(\.displayName), ["AirPods Pro (Owner)", "Magic Mouse"])
        XCTAssertEqual(parsed.first?.components.map(\.kind), [.right])
    }

    /// An Apple accessory the naming table does not recognise still reads as an
    /// Apple device, not as an anonymous one.
    func testAnUnrecognisedAppleAccessoryStaysApple() throws {
        let parsed = try devices("""
        {"SPBluetoothDataType":[{"device_connected":[{"Apple Prototype":{
          "device_address":"00-00-5e-00-53-0c",
          "device_vendorID":"0x004C",
          "device_minorType":"Headset",
          "device_batteryLevelMain":"33 %"}}]}]}
        """)

        XCTAssertEqual(parsed.first?.kind, .unknown, "Apple vendor id keeps the Apple fallback")
    }

    // MARK: - Dedup

    func testTheSameThirdPartyDeviceUnderTwoControllersIsOneCard() throws {
        let parsed = try devices("""
        {"SPBluetoothDataType":[
          {"device_connected":[{"Studio Headset":{"device_address":"00-00-5e-00-53-0d",
                                                  "device_minorType":"Headset",
                                                  "device_batteryLevelMain":"73 %"}}]},
          {"device_connected":[{"Studio Headset":{"device_address":"00-00-5e-00-53-0d",
                                                  "device_minorType":"Headset",
                                                  "device_batteryLevelMain":"73 %"}}]}]}
        """)

        XCTAssertEqual(parsed.count, 1, "identity decides, not the controller it was seen under")
    }

    /// Two readings of one device merge on identity, the way the coordinator
    /// merges every other provider pair.
    func testTwoProviderUpdatesForOneThirdPartyDeviceMergeToOneRow() throws {
        let device = try XCTUnwrap(try devices("""
        {"SPBluetoothDataType":[{"device_connected":[{"Studio Headset":{
          "device_address":"00-00-5e-00-53-0e",
          "device_minorType":"Headset",
          "device_batteryLevelMain":"73 %"}}]}]}
        """).first)

        let merged = DeviceSnapshotMerger.merge([[device], [device]], now: now)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.kind, .headphones)
    }

    // MARK: - Presentation

    func testGenericKindsHaveHonestVendorNeutralPresentation() {
        for kind in [AppleDeviceKind.headphones, .keyboard, .mouse, .trackpad, .accessory] {
            let title = AppleDevicePresentation.kindTitle(kind)
            XCTAssertFalse(title.isEmpty)
            XCTAssertFalse(
                title.localizedCaseInsensitiveContains("apple"),
                "\(kind.rawValue) must not claim a vendor Impuls has no evidence for"
            )
            XCTAssertFalse(AppleDevicePresentation.symbol(for: kind).isEmpty)
        }
    }
}
