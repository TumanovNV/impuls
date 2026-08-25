import Foundation
import XCTest
@testable import ImpulsCore

/// The accessory sources must not run their subprocess on the main actor.
///
/// `AppleAccessoryBatteryProvider` is `@MainActor`, so a synchronous source
/// method freezes the UI for as long as the tool takes — up to its deadline,
/// twice over when both sources run. That regression shipped in this branch and
/// these tests exist so it cannot come back.
///
/// Each case drives the **production** method from a main-actor context and
/// asks the injected runner where it ended up. Deliberately *not* wrapping the
/// call in a `Task.detached` of the test's own: that would prove the test can
/// leave the main actor, which nobody doubted, and would keep passing after the
/// production boundary was removed again.
@MainActor
final class AccessorySourceIsolationTests: DeviceIdentityTestCase {
    private let resolver = DeviceIdentityResolver(
        service: "io.tumanov.impuls.tests.device-identity",
        account: "accessory-isolation"
    )

    /// Records where the work ran. `pthread_main_np` rather than
    /// `Thread.isMainThread`, which is unavailable from an async context.
    private final class ThreadWitness: @unchecked Sendable {
        private let lock = NSLock()
        private var ranOnMain: Bool?

        func record() {
            lock.lock(); defer { lock.unlock() }
            if ranOnMain == nil { ranOnMain = pthread_main_np() != 0 }
        }

        var observed: Bool? {
            lock.lock(); defer { lock.unlock() }
            return ranOnMain
        }
    }

    private let bluetoothJSON = """
    {"SPBluetoothDataType":[{"device_connected":[{"Studio Headset":{
      "device_address":"00-00-5e-00-53-01",
      "device_minorType":"Headset",
      "device_batteryLevelMain":"73 %"}}]}]}
    """

    private let accessoryPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
    <key>Type</key><string>Accessory Source</string>
    <key>Name</key><string>Studio Headset</string>
    <key>Accessory Category</key><string>Headset</string>
    <key>Current Capacity</key><integer>80</integer>
    <key>Max Capacity</key><integer>100</integer>
    <key>Transport Type</key><string>Bluetooth</string>
    </dict></plist>
    """

    // MARK: - 1. system_profiler

    func testSystemProfilerInventoryRunsItsToolOffTheMainActor() async throws {
        let witness = ThreadWitness()
        let json = bluetoothJSON
        let source = SystemProfilerAccessorySource(resolver: resolver) {
            witness.record()
            return Data(json.utf8)
        }

        MainActor.assertIsolated("the provider calls this from the main actor")
        let inventory = try await source.inventory()

        XCTAssertEqual(witness.observed, false, "the subprocess must not run on the main thread")
        XCTAssertEqual(inventory.devices.count, 1, "and it still returns what it read")
    }

    func testSystemProfilerReadRunsItsToolOffTheMainActor() async throws {
        let witness = ThreadWitness()
        let json = bluetoothJSON
        let source = SystemProfilerAccessorySource(resolver: resolver) {
            witness.record()
            return Data(json.utf8)
        }

        MainActor.assertIsolated()
        let devices = try await source.read()

        XCTAssertEqual(witness.observed, false)
        XCTAssertEqual(devices.count, 1)
    }

    // MARK: - 2. pmset

    func testPowerAccessoryReadingsRunItsToolOffTheMainActor() async {
        let witness = ThreadWitness()
        let plist = accessoryPlist
        let source = PowerAccessoryBatterySource {
            witness.record()
            return Data(plist.utf8)
        }

        MainActor.assertIsolated("the provider calls this from the main actor")
        let readings = await source.readings()

        XCTAssertEqual(witness.observed, false, "the subprocess must not run on the main thread")
        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(readings.first?.percentage, 80)
    }

    /// The failure path leaves the main actor too — a tool that hangs until its
    /// deadline is exactly the case that would freeze the UI.
    func testAFailingToolAlsoFailsOffTheMainActor() async {
        struct Boom: Error {}
        let witness = ThreadWitness()
        let source = PowerAccessoryBatterySource {
            witness.record()
            throw Boom()
        }

        MainActor.assertIsolated()
        let readings = await source.readings()

        XCTAssertEqual(witness.observed, false)
        XCTAssertTrue(readings.isEmpty)
    }
}

// MARK: - 3. Parsing needs no main actor

/// Both parsers are pure and `nonisolated`; this case is not `@MainActor`,
/// so it compiles only while that stays true — the compiler re-checks it on
/// every build rather than a comment claiming it.
final class ParsingIsolationTests: XCTestCase {
    func testBothParsersAreCallableWithoutTheMainActor() throws {
        let readings = PowerAccessoryBatteryParser.readings(fromXML: Data("""
        <?xml version="1.0"?><plist version="1.0"><dict>
        <key>Type</key><string>Accessory Source</string>
        <key>Name</key><string>Studio Headset</string>
        <key>Accessory Category</key><string>Headset</string>
        <key>Current Capacity</key><integer>80</integer>
        <key>Max Capacity</key><integer>100</integer>
        <key>Transport Type</key><string>Bluetooth</string>
        </dict></plist>
        """.utf8))
        XCTAssertEqual(readings.count, 1)

        let resolver = DeviceIdentityResolver(
            service: "io.tumanov.impuls.tests.device-identity",
            account: "accessory-isolation-parse"
        )
        let inventory = try SystemProfilerAccessoryParser.inventory(
            fromJSON: Data("""
            {"SPBluetoothDataType":[{"device_connected":[{"Studio Headset":{
              "device_address":"00-00-5e-00-53-01",
              "device_minorType":"Headset",
              "device_batteryLevelMain":"73 %"}}]}]}
            """.utf8),
            now: Date(timeIntervalSince1970: 1_700_000_000),
            resolver: resolver
        )
        XCTAssertEqual(inventory.devices.count, 1)

        XCTAssertEqual(
            PowerAccessoryOverlay.apply(candidates: [], readings: readings, now: Date()).count,
            0
        )
        TestKeychain.removeStoredKeys()
    }
}
