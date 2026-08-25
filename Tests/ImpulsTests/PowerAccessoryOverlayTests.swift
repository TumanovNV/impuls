import Foundation
import XCTest
@testable import ImpulsCore

/// The `pmset` battery overlay (#108 follow-up).
///
/// Every address below is a documentation-style placeholder and every name is
/// invented: no real Bluetooth address, MAC, serial or accessory UUID appears
/// in these fixtures. The accessory UUID is not modelled at all — the parser
/// never reads it.
final class PowerAccessoryOverlayTests: DeviceIdentityTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let resolver = DeviceIdentityResolver(
        service: "io.tumanov.impuls.tests.device-identity",
        account: "pmset-overlay"
    )

    // MARK: - Fixtures

    /// One `pmset -g accps -xml` document.
    private func accessoryPlist(
        name: String,
        category: String = "Headset",
        current: Int = 80,
        maximum: Int = 100,
        charging: Int? = 0,
        transport: String = "Bluetooth",
        part: String = "Single",
        type: String = "Accessory Source"
    ) -> String {
        let chargingEntry = charging.map { "<key>Is Charging</key><integer>\($0)</integer>" } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Type</key><string>\(type)</string>
        <key>Name</key><string>\(name)</string>
        <key>Accessory Category</key><string>\(category)</string>
        <key>Current Capacity</key><integer>\(current)</integer>
        <key>Max Capacity</key><integer>\(maximum)</integer>
        \(chargingEntry)
        <key>Transport Type</key><string>\(transport)</string>
        <key>Part Identifier</key><string>\(part)</string>
        </dict></plist>
        """
    }

    private let internalBatteryPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
    <key>Type</key><string>InternalBattery</string>
    <key>Name</key><string>InternalBattery-0</string>
    <key>Current Capacity</key><integer>17</integer>
    <key>Max Capacity</key><integer>100</integer>
    <key>Transport Type</key><string>Internal</string>
    </dict></plist>
    """

    private func readings(_ documents: String...) -> [PowerAccessoryReading] {
        PowerAccessoryBatteryParser.readings(fromXML: Data(documents.joined(separator: "\n").utf8))
    }

    private func inventory(_ json: String) throws
        -> (devices: [AppleDeviceSnapshot], batteryless: [SystemProfilerAccessoryParser.BatterylessDevice]) {
        try SystemProfilerAccessoryParser.inventory(fromJSON: Data(json.utf8), now: now, resolver: resolver)
    }

    /// A connected Bluetooth headset with no battery field — the shape the
    /// reported device actually produces.
    private let headsetWithoutBattery = """
    {"SPBluetoothDataType":[{"device_connected":[{"Immersive Headset":{
      "device_address":"00-00-5e-00-53-01",
      "device_minorType":"Headset",
      "device_rssi":-52}}]}]}
    """

    // MARK: - 1. The reported case

    func testAHeadsetWithNoBatteryFieldGetsOneCardFromTheOverlay() throws {
        let inventory = try inventory(headsetWithoutBattery)
        XCTAssertTrue(inventory.devices.isEmpty, "system_profiler alone still yields nothing")
        XCTAssertEqual(inventory.batteryless.count, 1, "but it is a known connected device")

        let overlaid = PowerAccessoryOverlay.apply(
            candidates: inventory.batteryless,
            readings: readings(internalBatteryPlist, accessoryPlist(name: "Immersive Headset")),
            now: now
        )

        XCTAssertEqual(overlaid.count, 1, "exactly one card, never a second one from pmset itself")
        let device = try XCTUnwrap(overlaid.first)
        XCTAssertEqual(device.headlinePercentage, 80)
        XCTAssertEqual(device.displayName, "Immersive Headset")
        XCTAssertEqual(device.kind, .headphones)
        XCTAssertEqual(device.identity, inventory.batteryless.first?.identity,
                       "identity stays the address-derived one; pmset supplies a number, not an identity")
        XCTAssertEqual(device.source, .systemProfilerAccessory)
    }

    // MARK: - 2. Charging

    func testChargingStateComesFromTheSourceRatherThanFromTheLevel() throws {
        let candidates = try inventory(headsetWithoutBattery).batteryless

        let charging = PowerAccessoryOverlay.apply(
            candidates: candidates,
            readings: readings(accessoryPlist(name: "Immersive Headset", charging: 1)),
            now: now
        )
        XCTAssertEqual(charging.first?.externalPower, .connected)

        let discharging = PowerAccessoryOverlay.apply(
            candidates: candidates,
            readings: readings(accessoryPlist(name: "Immersive Headset", charging: 0)),
            now: now
        )
        XCTAssertEqual(discharging.first?.externalPower, .disconnected)

        // No `Is Charging` key, and a full battery: still unknown. A full
        // battery is not a cable.
        let silent = PowerAccessoryOverlay.apply(
            candidates: candidates,
            readings: readings(accessoryPlist(name: "Immersive Headset", current: 100, charging: nil)),
            now: now
        )
        XCTAssertEqual(silent.first?.externalPower, .unknown)
    }

    // MARK: - 3. The overlay never displaces a real source

    func testADeviceThatAlreadyHasABatteryIsNotACandidate() throws {
        let inventory = try inventory("""
        {"SPBluetoothDataType":[{"device_connected":[{"Immersive Headset":{
          "device_address":"00-00-5e-00-53-01",
          "device_minorType":"Headset",
          "device_batteryLevelMain":"42 %"}}]}]}
        """)

        XCTAssertEqual(inventory.devices.first?.headlinePercentage, 42)
        XCTAssertTrue(inventory.batteryless.isEmpty, "nothing for the overlay to attach to")
        XCTAssertTrue(
            PowerAccessoryOverlay.apply(candidates: inventory.batteryless, readings: readings(accessoryPlist(name: "Immersive Headset")), now: now).isEmpty
        )
    }

    // MARK: - 4-5. Fail closed

    func testTwoDevicesWithTheSameNameProduceNoOverlay() throws {
        let inventory = try inventory("""
        {"SPBluetoothDataType":[{"device_connected":[
          {"Immersive Headset":{"device_address":"00-00-5e-00-53-01","device_minorType":"Headset"}}]},
          {"device_connected":[
          {"Immersive Headset":{"device_address":"00-00-5e-00-53-02","device_minorType":"Headset"}}]}]}
        """)

        XCTAssertEqual(inventory.batteryless.count, 2)
        XCTAssertTrue(
            PowerAccessoryOverlay.apply(
                candidates: inventory.batteryless,
                readings: readings(accessoryPlist(name: "Immersive Headset")),
                now: now
            ).isEmpty,
            "no evidence decides which headset the battery belongs to, so neither gets it"
        )
    }

    func testTwoReadingsWithTheSameNameProduceNoOverlay() throws {
        let candidates = try inventory(headsetWithoutBattery).batteryless

        XCTAssertTrue(
            PowerAccessoryOverlay.apply(
                candidates: candidates,
                readings: readings(
                    accessoryPlist(name: "Immersive Headset", current: 80),
                    accessoryPlist(name: "Immersive Headset", current: 30)
                ),
                now: now
            ).isEmpty,
            "ambiguous on the pmset side is just as disqualifying"
        )
    }

    func testAMatchingNameWithAConflictingClassProducesNoOverlay() throws {
        let candidates = try inventory(headsetWithoutBattery).batteryless

        XCTAssertTrue(
            PowerAccessoryOverlay.apply(
                candidates: candidates,
                readings: readings(accessoryPlist(name: "Immersive Headset", category: "Mouse")),
                now: now
            ).isEmpty,
            "a headset is not a mouse, whatever the names say"
        )
    }

    /// Compatible classes are families, not equal values: the same headset is
    /// `Headphones` to one source and `Headset` to the other.
    func testRelatedClassesStillMatch() throws {
        let candidates = try inventory(headsetWithoutBattery).batteryless

        let overlaid = PowerAccessoryOverlay.apply(
            candidates: candidates,
            readings: readings(accessoryPlist(name: "Immersive Headset", category: "Headphones")),
            now: now
        )
        XCTAssertEqual(overlaid.count, 1)
    }

    // MARK: - 6-8. Refusals in the parser

    func testARecordWithoutANameIsIgnored() {
        let parsed = PowerAccessoryBatteryParser.readings(fromXML: Data("""
        <?xml version="1.0"?><plist version="1.0"><dict>
        <key>Type</key><string>Accessory Source</string>
        <key>Accessory Category</key><string>Headset</string>
        <key>Current Capacity</key><integer>80</integer>
        <key>Max Capacity</key><integer>100</integer>
        <key>Transport Type</key><string>Bluetooth</string>
        </dict></plist>
        """.utf8))

        XCTAssertTrue(parsed.isEmpty)
    }

    func testInvalidCapacitiesAreIgnored() {
        for (current, maximum) in [(-1, 100), (101, 100), (80, 0), (80, -5)] {
            XCTAssertTrue(
                readings(accessoryPlist(name: "Odd", current: current, maximum: maximum)).isEmpty,
                "\(current)/\(maximum) is not a battery level"
            )
        }
    }

    func testANonBluetoothOrNonAccessoryRecordIsIgnored() {
        XCTAssertTrue(readings(accessoryPlist(name: "Wired Thing", transport: "USB")).isEmpty)
        XCTAssertTrue(readings(accessoryPlist(name: "Not An Accessory", type: "InternalBattery")).isEmpty)
        XCTAssertTrue(readings(internalBatteryPlist).isEmpty, "the Mac's own battery is not an accessory")
    }

    func testMalformedOutputFailsSafely() {
        XCTAssertTrue(PowerAccessoryBatteryParser.readings(fromXML: Data()).isEmpty)
        XCTAssertTrue(PowerAccessoryBatteryParser.readings(fromXML: Data("not a plist at all".utf8)).isEmpty)
        XCTAssertTrue(PowerAccessoryBatteryParser.readings(fromXML: Data("<?xml version=\"1.0\"?><plist><dict>".utf8)).isEmpty)
        XCTAssertTrue(PowerAccessoryBatteryParser.readings(fromXML: Data([0xFF, 0xFE, 0x00])).isEmpty)
    }

    /// One unparseable document must not cost the readings around it.
    func testAGoodRecordSurvivesABadNeighbour() {
        let parsed = PowerAccessoryBatteryParser.readings(fromXML: Data("""
        <?xml version="1.0"?><plist version="1.0"><dict><key>broken</key></plist>
        \(accessoryPlist(name: "Immersive Headset"))
        """.utf8))

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.name, "Immersive Headset")
    }

    func testTheRecordCountIsBounded() {
        let many = (0..<200).map { accessoryPlist(name: "Device \($0)") }.joined(separator: "\n")
        XCTAssertLessThanOrEqual(
            PowerAccessoryBatteryParser.readings(fromXML: Data(many.utf8)).count,
            PowerAccessoryBatteryParser.maximumRecords
        )
    }

    // MARK: - 9. The tool being unavailable is survivable

    func testAFailingToolYieldsNoReadingsRatherThanAnError() async {
        struct Boom: Error {}
        let failing = await PowerAccessoryBatterySource(runner: { throw Boom() }).readings()
        XCTAssertTrue(failing.isEmpty)

        let garbage = await PowerAccessoryBatterySource(
            runner: { Data("<html>404</html>".utf8) }
        ).readings()
        XCTAssertTrue(garbage.isEmpty)
    }

    func testTheProcessBoundaryIsFixedAndArgumentFree() {
        XCTAssertEqual(PowerAccessoryBatterySource.executablePath, "/usr/bin/pmset")
        XCTAssertEqual(PowerAccessoryBatterySource.arguments, ["-g", "accps", "-xml"])
        let bounded = BoundedProcess.powerAccessories()
        XCTAssertEqual(bounded.executablePath, "/usr/bin/pmset")
        XCTAssertTrue(bounded.timeout > 0)
        XCTAssertTrue(bounded.maximumOutputBytes > 0)
    }

    // MARK: - Name matching

    func testNameMatchingIgnoresCaseAndSpacingAndNothingElse() throws {
        let candidates = try inventory(headsetWithoutBattery).batteryless

        XCTAssertEqual(
            PowerAccessoryOverlay.apply(
                candidates: candidates,
                readings: readings(accessoryPlist(name: "  immersive   headset ")),
                now: now
            ).count,
            1,
            "case and spacing are noise"
        )
        XCTAssertTrue(
            PowerAccessoryOverlay.apply(
                candidates: candidates,
                readings: readings(accessoryPlist(name: "Immersive Headset Pro")),
                now: now
            ).isEmpty,
            "a similar name is not the same name"
        )
    }

    // MARK: - Components

    func testPartIdentifierSelectsTheComponentItNames() throws {
        let candidates = try inventory(headsetWithoutBattery).batteryless
        for (part, expected) in [("Single", DeviceBatteryComponentKind.primary),
                                 ("Left", .left),
                                 ("Right", .right),
                                 ("Case", .chargingCase),
                                 ("Something New", .primary)] {
            let overlaid = PowerAccessoryOverlay.apply(
                candidates: candidates,
                readings: readings(accessoryPlist(name: "Immersive Headset", part: part)),
                now: now
            )
            XCTAssertEqual(overlaid.first?.components.first?.kind, expected, "part \(part)")
        }
    }

    // MARK: - Privacy

    /// The accessory UUID is not modelled, so it cannot leak into state, logs
    /// or a card. This pins that as a property of the type rather than a habit.
    func testTheAccessoryIdentifierIsNeverRead() {
        let withIdentifier = """
        <?xml version="1.0"?><plist version="1.0"><dict>
        <key>Type</key><string>Accessory Source</string>
        <key>Name</key><string>Immersive Headset</string>
        <key>Accessory Category</key><string>Headset</string>
        <key>Accessory Identifier</key><string>PLACEHOLDER-NOT-A-REAL-UUID</string>
        <key>Current Capacity</key><integer>80</integer>
        <key>Max Capacity</key><integer>100</integer>
        <key>Transport Type</key><string>Bluetooth</string>
        </dict></plist>
        """
        let parsed = PowerAccessoryBatteryParser.readings(fromXML: Data(withIdentifier.utf8))

        XCTAssertEqual(parsed.count, 1)
        XCTAssertFalse(
            String(describing: parsed).contains("PLACEHOLDER-NOT-A-REAL-UUID"),
            "the accessory identifier must not survive into the model"
        )
    }
}
