import Foundation
import XCTest
@testable import ImpulsCore

@MainActor
final class MobileDeviceBatteryProviderTests: XCTestCase {
    func testTopologyChangeTriggersOneFreshReadAndStopClosesMonitoring() async {
        let source = CountingMobileDeviceSource()
        let topology = FakeMobileDeviceTopologyMonitor()
        let provider = MobileDeviceBatteryProvider(
            source: source,
            topologyMonitor: topology,
            featureEnabled: { true }
        )
        var updates: [DeviceProviderUpdate] = []
        let initial = expectation(description: "initial read")
        let topologyRead = expectation(description: "topology read")

        provider.start { update in
            updates.append(update)
            if updates.count == 1 { initial.fulfill() }
            if updates.count == 2 { topologyRead.fulfill() }
        }
        await fulfillment(of: [initial], timeout: 2)

        topology.emitChange()
        await fulfillment(of: [topologyRead], timeout: 2)

        XCTAssertEqual(source.readCount, 2)
        XCTAssertEqual(updates.map(\.identifier), [.mobileDevice, .mobileDevice])
        XCTAssertEqual(updates.map(\.status), [.ready, .ready])

        provider.stop()
        XCTAssertTrue(topology.didStop)
        XCTAssertEqual(provider.status, .disabled)
    }

    func testDisabledFlagNeverStartsTopologyOrReadsTheSocketSource() async {
        let source = CountingMobileDeviceSource()
        let topology = FakeMobileDeviceTopologyMonitor()
        let provider = MobileDeviceBatteryProvider(
            source: source,
            topologyMonitor: topology,
            featureEnabled: { false }
        )
        let update = expectation(description: "disabled update")
        var received: DeviceProviderUpdate?

        provider.start {
            received = $0
            update.fulfill()
        }
        await fulfillment(of: [update], timeout: 2)

        XCTAssertEqual(received?.identifier, .mobileDevice)
        XCTAssertEqual(received?.status, .unavailable)
        XCTAssertEqual(source.readCount, 0)
        XCTAssertFalse(topology.didStart)
        provider.stop()
    }

    /// The 1.4.8 regression, pinned.
    ///
    /// Until 1.4.8 the production default for `featureEnabled` was an
    /// environment variable and an undocumented `UserDefaults` key. Neither is
    /// set on any ordinary install, so every shipped Impuls started this
    /// provider and it returned `.unavailable` before opening a socket — the
    /// phone was never looked for, while AirPods, which come from another
    /// provider, kept working. The test process has neither flag set, which is
    /// the point: build the provider the way `DevicePowerCenter` builds it and
    /// it must do real work.
    func testTheProviderWorksWithNoEnvironmentVariableAndNoHiddenDefault() async {
        XCTAssertNil(ProcessInfo.processInfo.environment["IMPULS_MOBILE_DEVICE_BATTERY"])
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "experimentalMobileDeviceBattery"))

        let source = CountingMobileDeviceSource()
        let topology = FakeMobileDeviceTopologyMonitor()
        // No `featureEnabled:` — exactly the production construction.
        let provider = MobileDeviceBatteryProvider(source: source, topologyMonitor: topology)
        let update = expectation(description: "ready update")
        var received: DeviceProviderUpdate?

        provider.start {
            received = $0
            update.fulfill()
        }
        await fulfillment(of: [update], timeout: 2)

        XCTAssertEqual(received?.status, .ready)
        XCTAssertTrue(topology.didStart, "the topology listener must open once the user has opted in")
        XCTAssertEqual(source.readCount, 1)
        provider.stop()
    }
}

private final class CountingMobileDeviceSource: DeviceBatterySource, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var readCount: Int { lock.withLock { count } }

    func read() async throws -> [AppleDeviceSnapshot] {
        lock.withLock { count += 1 }
        return []
    }
}

private final class FakeMobileDeviceTopologyMonitor: MobileDeviceTopologyMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    private var started = false
    private var stopped = false

    var didStart: Bool { lock.withLock { started } }
    var didStop: Bool { lock.withLock { stopped } }

    func start(onChange: @escaping @Sendable () -> Void) {
        lock.withLock {
            callback = onChange
            started = true
        }
    }

    func stop() {
        lock.withLock {
            callback = nil
            stopped = true
        }
    }

    func emitChange() {
        let callback = lock.withLock { self.callback }
        callback?()
    }
}
