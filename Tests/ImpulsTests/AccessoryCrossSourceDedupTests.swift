import Combine
import Foundation
import XCTest
@testable import ImpulsCore

/// One physical accessory seen by two sources must be one card (IMP-10 / B3).
///
/// This drives the **production** pipeline — `AppleAccessoryBatteryProvider`'s
/// own `combined`, reached through `start(onUpdate:)` — rather than calling a
/// dedup helper directly. The previous tests proved each parser in isolation
/// and proved the merger dedups when identities already match; what none of
/// them proved is that the two sources *produce* matching identities for the
/// same device. That is the seam this covers.
///
/// Both fixtures describe one Magic Mouse the way production does: the registry
/// publishes `DeviceAddress`, `system_profiler` publishes `device_address`, and
/// both derive identity through the real `DeviceIdentityResolver`.
///
/// Addresses are RFC 7042 documentation values.
@MainActor
final class AccessoryCrossSourceDedupTests: DeviceIdentityTestCase {
    private let resolver = DeviceIdentityResolver(
        service: "io.tumanov.impuls.tests.device-identity",
        account: "cross-source-dedup"
    )
    /// The same physical accessory, in the format each source uses.
    private let sharedAddress = "00-00-5e-00-53-01"

    /// A registry source that replays what the **real mapper** produced.
    ///
    /// The mapping runs eagerly at construction, so identity is derived exactly
    /// as production derives it while the value crossing the concurrency
    /// boundary stays a `Sendable` snapshot rather than an `[String: Any]`.
    private struct RegistryStub: DeviceBatterySource {
        let devices: [AppleDeviceSnapshot]

        init(properties: [String: Any]?, resolver: DeviceIdentityResolver, now: Date) {
            guard let properties,
                  let device = IORegistryAccessoryMapper.device(
                      from: properties,
                      now: now,
                      resolver: resolver
                  ) else {
                devices = []
                return
            }
            devices = [device]
        }

        func read() async throws -> [AppleDeviceSnapshot] { devices }
    }

    private func registryProperties(percent: Int, product: String = "Magic Mouse") -> [String: Any] {
        [
            "DeviceAddress": sharedAddress,
            "Product": product,
            "VendorID": IORegistryAccessoryMapper.appleBluetoothVendorID,
            "BatteryPercent": percent,
            "Built-In": false,
        ]
    }

    private func profilerJSON(name: String = "Magic Mouse", battery: String? = "61 %") -> String {
        var fields = [
            "\"device_address\":\"\(sharedAddress)\"",
            "\"device_vendorID\":\"0x004C\"",
            "\"device_productID\":\"0x0269\"",
            "\"device_minorType\":\"Mouse\"",
        ]
        if let battery { fields.append("\"device_batteryLevelMain\":\"\(battery)\"") }
        return "{\"SPBluetoothDataType\":[{\"device_connected\":[{\"\(name)\":{\(fields.joined(separator: ","))}}]}]}"
    }

    /// Runs the provider and returns the devices it publishes.
    private func devices(
        registry: [String: Any]?,
        profilerJSON json: String,
        pmsetXML: String = "",
        pmsetCalls: PmsetWitness? = nil
    ) async -> [AppleDeviceSnapshot] {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let provider = AppleAccessoryBatteryProvider(
            registrySource: RegistryStub(properties: registry, resolver: resolver, now: now),
            profilerSource: SystemProfilerAccessorySource(
                clock: FixedDeviceClock(now: now),
                resolver: resolver,
                runner: { Data(json.utf8) }
            ),
            accessorySource: PowerAccessoryBatterySource(runner: {
                pmsetCalls?.record()
                return Data(pmsetXML.utf8)
            })
        )

        let published = expectation(description: "provider published")
        var result: [AppleDeviceSnapshot] = []
        provider.start { update in
            guard update.status == .ready else { return }
            result = update.devices
            published.fulfill()
        }
        await fulfillment(of: [published], timeout: 10)
        provider.stop()
        return result
    }

    final class PmsetWitness: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func record() { lock.lock(); count += 1; lock.unlock() }
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    // MARK: - One device, two sources

    func testOneAccessorySeenByBothSourcesProducesOneCard() async {
        let witness = PmsetWitness()
        let devices = await devices(
            registry: registryProperties(percent: 61),
            profilerJSON: profilerJSON(),
            pmsetCalls: witness
        )

        XCTAssertEqual(devices.count, 1, "one physical accessory is one card")
        XCTAssertEqual(devices.first?.kind, .magicMouse)
        XCTAssertEqual(devices.first?.headlinePercentage, 61)
        XCTAssertEqual(devices.first?.source, .ioRegistryAccessory,
                       "the registry answered first, so its reading is the one kept")
        XCTAssertEqual(witness.callCount, 0,
                       "nothing was missing a battery, so pmset was never spawned")
    }

    /// The identities must match across the two sources — the actual seam.
    func testBothSourcesDeriveTheSameIdentityForOneAccessory() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fromRegistry = try XCTUnwrap(IORegistryAccessoryMapper.device(
            from: registryProperties(percent: 61),
            now: now,
            resolver: resolver
        ))
        let fromProfiler = try XCTUnwrap(SystemProfilerAccessoryParser.devices(
            fromJSON: Data(profilerJSON().utf8),
            now: now,
            resolver: resolver
        ).first)

        XCTAssertEqual(fromRegistry.identity, fromProfiler.identity,
                       "same address and same kind must yield the same identity")
        XCTAssertEqual(fromRegistry.kind, fromProfiler.kind)
    }

    /// A rename on the `system_profiler` side must not split the device in two.
    /// This is why B1 matters here: without the product-id fallback the renamed
    /// entry classifies as `.unknown`, which changes the identity and yields a
    /// second card.
    func testARenameOnOneSourceDoesNotCreateASecondCard() async {
        let devices = await devices(
            registry: registryProperties(percent: 61),
            profilerJSON: profilerJSON(name: "Desk Mouse")
        )

        XCTAssertEqual(devices.count, 1, "the owner's name is not part of the device's identity")
        XCTAssertEqual(devices.first?.kind, .magicMouse)
    }

    // MARK: - Where the registry is silent

    /// With no registry reading, `system_profiler` supplies the device — still
    /// one card, and still no pmset run because a battery was found.
    func testTheProfilerAloneStillProducesOneCardAndNoOverlayRun() async {
        let witness = PmsetWitness()
        let devices = await devices(
            registry: nil,
            profilerJSON: profilerJSON(),
            pmsetCalls: witness
        )

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.source, .systemProfilerAccessory)
        XCTAssertEqual(devices.first?.headlinePercentage, 61)
        XCTAssertEqual(witness.callCount, 0, "a battery was already found")
    }

    /// Only when nothing has a reading does the third source run — and it still
    /// yields one card, not a third one.
    func testTheOverlayRunsOnlyWhenABatteryIsMissingAndStillYieldsOneCard() async {
        let witness = PmsetWitness()
        let pmset = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>Type</key><string>Accessory Source</string>
        <key>Name</key><string>Magic Mouse</string>
        <key>Accessory Category</key><string>Mouse</string>
        <key>Current Capacity</key><integer>47</integer>
        <key>Max Capacity</key><integer>100</integer>
        <key>Transport Type</key><string>Bluetooth</string>
        </dict></plist>
        """
        let devices = await devices(
            registry: nil,
            profilerJSON: profilerJSON(battery: nil),
            pmsetXML: pmset,
            pmsetCalls: witness
        )

        XCTAssertEqual(witness.callCount, 1, "this time something was missing a battery")
        XCTAssertEqual(devices.count, 1, "the overlay decorates the device, it does not add one")
        XCTAssertEqual(devices.first?.kind, .magicMouse)
        XCTAssertEqual(devices.first?.headlinePercentage, 47)
    }
}

/// A clock that does not move, so a fixture's timestamps are reproducible.
private struct FixedDeviceClock: DeviceClock {
    let now: Date
}
