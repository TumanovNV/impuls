import Combine
import Foundation

/// This Mac, expressed as one device among the others.
///
/// An adapter and nothing more. `PowerMonitor` keeps every rule it already
/// has — the module setting owns the observation, IOKit notifications drive the
/// updates, the fast timer exists only while the panel is open — and this class
/// translates each snapshot it publishes into the shared vocabulary. Rewriting
/// the local path to look like the new one would have risked the only part of
/// the module that is already known to work.
///
/// Its refresh behaviour is `.eventDriven` for the same reason: the monitor is
/// already awake at the right moments, and a scheduler polling it on top of
/// that would duplicate work the module deliberately avoids when the panel is
/// closed.
@MainActor
final class LocalMacDeviceProvider: DeviceBatteryProviding {
    let identifier = DeviceProviderIdentifier.localMac
    let refreshBehavior = DeviceRefreshBehavior.eventDriven
    private(set) var status: DeviceProviderStatus = .disabled

    private let monitor: PowerMonitor
    private let clock: DeviceClock
    private let deviceName: String
    private var cancellable: AnyCancellable?
    private var onUpdate: ((DeviceProviderUpdate) -> Void)?

    init(monitor: PowerMonitor, clock: DeviceClock = SystemDeviceClock(), deviceName: String? = nil) {
        self.monitor = monitor
        self.clock = clock
        // The computer's own name, which macOS shows in every sharing and
        // AirDrop surface. It is a name, not an identifier: no serial number is
        // read here, and `AppleDeviceIdentity.localMac` needs none.
        self.deviceName = AppleDeviceNormalizer.displayName(
            deviceName ?? Host.current().localizedName,
            fallback: "Mac"
        )
    }

    func start(onUpdate: @escaping (DeviceProviderUpdate) -> Void) {
        self.onUpdate = onUpdate
        status = .ready
        cancellable = monitor.$snapshot
            .sink { [weak self] snapshot in
                guard let self else { return }
                self.publish(snapshot)
            }
        DevicePowerLog.note("provider localMac started")
    }

    func stop() {
        cancellable = nil
        onUpdate = nil
        status = .disabled
        DevicePowerLog.note("provider localMac stopped")
    }

    func refresh() {
        guard status != .disabled else { return }
        publish(monitor.snapshot)
    }

    private func publish(_ snapshot: PowerSnapshot) {
        onUpdate?(
            DeviceProviderUpdate(
                identifier: identifier,
                status: .ready,
                devices: [Self.device(from: snapshot, name: deviceName, now: clock.now)]
            )
        )
    }

    /// A desktop Mac is a device with no battery, not the absence of a device.
    ///
    /// Mac mini, Mac Studio, iMac and Mac Pro owners have a working Power
    /// module today, and it reports source, state and adapter without any
    /// battery at all. Dropping them here — "no components, nothing to show" —
    /// is how that would have quietly regressed one layer below the pane. They
    /// arrive with an empty component list and a real `externalPower`, and it
    /// stays the interface's decision how to draw them.
    static func device(from snapshot: PowerSnapshot, name: String, now: Date) -> AppleDeviceSnapshot {
        var components: [DeviceBatteryComponent] = []
        if snapshot.deviceKind == .portable,
           let component = AppleDeviceNormalizer.component(
               kind: .primary,
               percentage: snapshot.batteryPercentage,
               chargingState: chargingState(from: snapshot.batteryState),
               lastUpdated: now
           ) {
            components.append(component)
        }

        return AppleDeviceSnapshot(
            identity: .localMac,
            kind: .mac,
            displayName: name,
            connection: .builtIn,
            availability: .connected,
            externalPower: externalPower(from: snapshot),
            components: components,
            lastSeen: now,
            lastUpdated: now,
            source: .localIOKit,
            capabilities: AppleDeviceNormalizer.capabilities(for: components)
        )
    }

    private static func chargingState(from state: BatteryState) -> DeviceChargingState {
        switch state {
        case .charging, .finishingCharge: return .charging
        case .discharging: return .discharging
        case .charged: return .charged
        case .pluggedNotCharging: return .notCharging
        case .unknown: return .unknown
        }
    }

    private static func externalPower(from snapshot: PowerSnapshot) -> DeviceExternalPowerState {
        switch snapshot.powerSource {
        case .ac, .ups: return .connected
        case .battery: return .disconnected
        case .unknown: return .unknown
        }
    }
}
