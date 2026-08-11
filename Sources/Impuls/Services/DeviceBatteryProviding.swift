import Foundation

/// The boundary between "where the numbers come from" and everything else.
///
/// Two protocols rather than one, because they answer to different rules.
///
/// `DeviceBatteryProviding` owns state and publishes it, so it lives on the
/// main actor with the rest of the observable objects. `DeviceBatterySource`
/// does the reading — a registry walk, a socket conversation — and is
/// deliberately **not** `@MainActor`. Isolation on the provider is not a licence
/// to do slow work inside it: a USB exchange with a phone that has just gone to
/// sleep is measured in seconds, and a second of that on the main actor is a
/// frozen panel.
///
/// Keeping the reading side in its own non-isolated protocol is what makes that
/// mistake fail to compile rather than fail in front of a user.
protocol DeviceBatterySource: Sendable {
    func read() async throws -> [AppleDeviceSnapshot]
}

enum DeviceProviderIdentifier: String, Equatable, Hashable, Sendable, CaseIterable {
    case localMac
    case appleAccessory
    case mobileUSB
    case mobileWiFi
}

/// What a provider is doing, in terms the interface can explain to a person.
///
/// Raw `NSError` never reaches the UI. "Bluetooth is not permitted" is a state
/// with a button next to it; `CBError 7` is a support ticket.
enum DeviceProviderStatus: Equatable, Hashable, Sendable {
    case disabled
    case starting
    case ready
    case permissionRequired
    case unavailable
    case temporarilyFailed
}

/// How a provider expects to be kept up to date.
///
/// The provider states its nature; the scheduler decides the timetable. This
/// separation exists so that `PowerMonitor` — which already has IOKit
/// notifications and its own fast timer while the panel is open — is never
/// polled on top of that, and so a future event-driven accessory provider does
/// not inherit a cadence invented for a USB one.
enum DeviceRefreshBehavior: Equatable, Sendable {
    /// The provider reports changes by itself. Nothing polls it.
    case eventDriven
    /// The provider needs to be asked. Intervals are a suggestion from the
    /// provider, which knows what its own reads cost; the scheduler applies
    /// them and owns the back-off when a device stops answering.
    case polled(activeInterval: TimeInterval, idleInterval: TimeInterval)
}

/// One delivery from a provider: everything it currently knows, plus its state.
///
/// Providers hand over their whole view rather than deltas. A device that has
/// disappeared is expressed by its absence from `devices` or by a snapshot with
/// a lower `availability`, never by a separate removal message that could be
/// lost or arrive out of order.
struct DeviceProviderUpdate: Equatable, Sendable {
    let identifier: DeviceProviderIdentifier
    let status: DeviceProviderStatus
    let devices: [AppleDeviceSnapshot]

    init(identifier: DeviceProviderIdentifier, status: DeviceProviderStatus, devices: [AppleDeviceSnapshot]) {
        self.identifier = identifier
        self.status = status
        self.devices = devices
    }
}

@MainActor
protocol DeviceBatteryProviding: AnyObject {
    var identifier: DeviceProviderIdentifier { get }
    var refreshBehavior: DeviceRefreshBehavior { get }
    var status: DeviceProviderStatus { get }

    /// Begin. The provider may call back immediately and as often as it has
    /// something new; the coordinator is prepared for both.
    func start(onUpdate: @escaping (DeviceProviderUpdate) -> Void)

    /// Stop, releasing observers, tasks and connections. After this the
    /// provider must not call back at all — a provider that keeps a socket open
    /// because the module was merely hidden is the bug this method exists for.
    func stop()

    /// Read now. Called by the scheduler, and by the user pressing refresh.
    func refresh()
}

extension DeviceBatteryProviding {
    /// The panel just opened.
    ///
    /// Most providers have nothing to do here — `refresh()` follows
    /// immediately. It exists for the ones that cache deliberately: the moment
    /// a person looks is the moment a cached answer should be thrown away, and
    /// that is different from the periodic refresh the scheduler performs.
    func prepareForForeground() {}
}
