import Foundation
import XCTest
@testable import ImpulsCore

/// Classifying an Apple accessory whose owner renamed it (IMP-10 / B1).
///
/// The product IDs used here are the three this project has confirmed on real
/// hardware (Mac mini, macOS Tahoe 26, 2026-08) and that
/// `AppleAccessoryNaming.bluetoothProductIDs` already contains. Nothing is
/// added, and no id is invented.
///
/// Addresses are RFC 7042 documentation values, never real hardware.
final class AppleAccessoryClassificationTests: DeviceIdentityTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let resolver = DeviceIdentityResolver(
        service: "io.tumanov.impuls.tests.device-identity",
        account: "apple-classification"
    )

    private func devices(_ json: String) throws -> [AppleDeviceSnapshot] {
        try SystemProfilerAccessoryParser.devices(fromJSON: Data(json.utf8), now: now, resolver: resolver)
    }

    private func entry(
        name: String,
        address: String,
        vendor: String? = "0x004C",
        product: String? = nil,
        minorType: String? = nil,
        battery: String? = "61 %"
    ) -> String {
        var fields = ["\"device_address\":\"\(address)\""]
        if let vendor { fields.append("\"device_vendorID\":\"\(vendor)\"") }
        if let product { fields.append("\"device_productID\":\"\(product)\"") }
        if let minorType { fields.append("\"device_minorType\":\"\(minorType)\"") }
        if let battery { fields.append("\"device_batteryLevelMain\":\"\(battery)\"") }
        return "{\"\(name)\":{\(fields.joined(separator: ","))}}"
    }

    private func output(_ entries: String...) -> String {
        "{\"SPBluetoothDataType\":[{\"device_connected\":[\(entries.joined(separator: ","))]}]}"
    }

    // MARK: - The defect: a renamed Apple accessory

    func testARenamedMagicMouseIsRecognisedByItsProductID() throws {
        let parsed = try devices(output(
            entry(name: "Desk Mouse", address: "00-00-5e-00-53-01", product: "0x0269")
        ))

        XCTAssertEqual(parsed.first?.kind, .magicMouse, "the name told us nothing; the product id did")
        XCTAssertEqual(parsed.first?.displayName, "Desk Mouse", "the owner's name for it is untouched")
    }

    func testARenamedMagicKeyboardIsRecognisedByItsProductID() throws {
        let parsed = try devices(output(
            entry(name: "Работа", address: "00-00-5e-00-53-02", product: "0x0267")
        ))

        XCTAssertEqual(parsed.first?.kind, .magicKeyboard)
        XCTAssertEqual(parsed.first?.displayName, "Работа")
    }

    func testARenamedMagicTrackpadIsRecognisedByItsProductID() throws {
        let parsed = try devices(output(
            entry(name: "Pad", address: "00-00-5e-00-53-03", product: "0x0265")
        ))

        XCTAssertEqual(parsed.first?.kind, .magicTrackpad)
        XCTAssertEqual(parsed.first?.displayName, "Pad")
    }

    // MARK: - The fallback refuses to guess

    /// An Apple accessory whose id is not in the confirmed table stays
    /// unrecognised. AirPods Pro publish `0x200E`, which this project has never
    /// cross-checked for the registry table, so it is deliberately absent.
    func testAnUnconfirmedAppleProductIDStaysUnknown() throws {
        let parsed = try devices(output(
            entry(name: "Renamed Buds", address: "00-00-5e-00-53-04", product: "0x200E")
        ))

        XCTAssertEqual(parsed.first?.kind, .unknown, "no confirmed mapping means no classification")
        XCTAssertEqual(parsed.first?.displayName, "Renamed Buds")
    }

    func testAnAppleAccessoryWithNoProductIDStaysUnknown() throws {
        let parsed = try devices(output(
            entry(name: "Mystery Device", address: "00-00-5e-00-53-05")
        ))

        XCTAssertEqual(parsed.first?.kind, .unknown)
    }

    func testAMalformedProductIDIsIgnoredRatherThanParsedLoosely() throws {
        for malformed in ["617", "0x", "", "0xZZZZ", "Magic Mouse"] {
            let parsed = try devices(output(
                entry(name: "Odd", address: "00-00-5e-00-53-06", product: malformed)
            ))
            XCTAssertEqual(parsed.first?.kind, .unknown, "\(malformed) is not a usable product id")
        }
    }

    // MARK: - The fallback is Apple-only

    /// The decisive case. A third-party device publishing the same numeric id
    /// must not borrow an Apple classification from it — the id only means
    /// "Magic Mouse" inside Apple's Bluetooth vendor namespace.
    func testAThirdPartyDeviceWithAnAppleProductIDIsNotClassifiedAsApple() throws {
        let parsed = try devices(output(
            entry(
                name: "Generic Mouse",
                address: "00-00-5e-00-53-07",
                vendor: "0x046D",
                product: "0x0269",
                minorType: "Mouse"
            )
        ))

        XCTAssertEqual(parsed.first?.kind, .mouse, "classified from the system's class, not Apple's table")
        XCTAssertNotEqual(parsed.first?.kind, .magicMouse)
    }

    func testADeviceWithNoVendorAndAnAppleProductIDIsNotClassifiedAsApple() throws {
        let parsed = try devices(output(
            entry(
                name: "No Vendor",
                address: "00-00-5e-00-53-08",
                vendor: nil,
                product: "0x0267",
                minorType: "Keyboard"
            )
        ))

        XCTAssertEqual(parsed.first?.kind, .keyboard)
    }

    // MARK: - Nothing that already worked changes

    func testNameBasedRecognitionStillWinsAndIsUnchanged() throws {
        let parsed = try devices(output(
            entry(name: "Magic Mouse", address: "00-00-5e-00-53-09"),
            entry(name: "Magic Keyboard", address: "00-00-5e-00-53-0a"),
            entry(name: "Magic Trackpad", address: "00-00-5e-00-53-0b"),
            entry(name: "AirPods Pro (Owner)", address: "00-00-5e-00-53-0c", product: "0x200E")
        ))

        XCTAssertEqual(parsed.map(\.kind), [.magicMouse, .magicKeyboard, .magicTrackpad, .airPodsPro],
                       "the name remains the primary signal, with no product id needed")
    }

    /// The name wins even when the id would say something else — the fallback
    /// is consulted only where the name resolved nothing.
    func testTheProductIDNeverOverridesANameThatWasRecognised() throws {
        let parsed = try devices(output(
            entry(name: "Magic Keyboard", address: "00-00-5e-00-53-0d", product: "0x0269")
        ))

        XCTAssertEqual(parsed.first?.kind, .magicKeyboard, "the name said keyboard; the id does not get a vote")
    }

    // MARK: - Identity consistency

    /// Kind is part of `AppleDeviceIdentity`, so a device must classify the same
    /// way whether or not it publishes a battery. Otherwise one accessory would
    /// hold two identities depending on which entry point saw it.
    func testABatterylessRenamedAccessoryClassifiesTheSameWay() throws {
        let withBattery = try SystemProfilerAccessoryParser.inventory(
            fromJSON: Data(output(entry(name: "Desk Mouse", address: "00-00-5e-00-53-0e", product: "0x0269")).utf8),
            now: now,
            resolver: resolver
        )
        let withoutBattery = try SystemProfilerAccessoryParser.inventory(
            fromJSON: Data(output(entry(name: "Desk Mouse", address: "00-00-5e-00-53-0e", product: "0x0269", battery: nil)).utf8),
            now: now,
            resolver: resolver
        )

        XCTAssertEqual(withBattery.devices.first?.kind, .magicMouse)
        XCTAssertEqual(withoutBattery.batteryless.first?.kind, .magicMouse)
        XCTAssertEqual(
            withBattery.devices.first?.identity,
            withoutBattery.batteryless.first?.identity,
            "same physical device, same identity, battery or not"
        )
    }
}
