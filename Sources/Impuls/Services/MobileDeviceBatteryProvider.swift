import AppKit
import Foundation

/// iPhone and iPad batteries over USB or macOS Wi-Fi sync — experimental, and
/// off by default.
///
/// Everything about this provider is deliberately quarantined. The protocol it
/// speaks is Apple's own and undocumented; writing the client ourselves keeps
/// the licence clean and adds no dependency, but it does not turn an
/// undocumented protocol into a supported API. If Apple changes it, this row
/// disappears from the panel and nothing else in Impuls notices — not the Mac's
/// battery, not the accessories, not any other module.
///
/// It does not run unless someone asks for it twice: the user has to turn on
/// Apple devices, and the flag below has to be set. Hardware validation on one
/// phone is not a broad support promise, so the flag stays off by default.
@MainActor
final class MobileDeviceBatteryProvider: DeviceBatteryProviding {
    let identifier = DeviceProviderIdentifier.mobileDevice

    /// Battery cadence stays sparse. Topology is a separate usbmuxd Listen
    /// subscription, so appearing, disappearing and USB/Wi-Fi transitions do
    /// not wait for this timer and do not make us ask for charge every second.
    let refreshBehavior = DeviceRefreshBehavior.polled(activeInterval: 60, idleInterval: 900)

    private(set) var status: DeviceProviderStatus = .disabled

    private let source: DeviceBatterySource
    private let topologyMonitor: MobileDeviceTopologyMonitoring
    private let featureEnabled: () -> Bool
    private var onUpdate: ((DeviceProviderUpdate) -> Void)?
    private var readTask: Task<Void, Never>?
    private var refreshPending = false
    private var wakeObserver: NSObjectProtocol?
    private var lastDevices: [AppleDeviceSnapshot] = []

    /// `featureEnabled` exists so a test can hold the provider inert without a
    /// phone attached. It is **not** the product's switch and has no hidden
    /// production value: until 1.4.8 it fell back to an environment variable
    /// and an undocumented `UserDefaults` key, which meant that every ordinary
    /// install started this provider and immediately returned `.unavailable`.
    /// AirPods came from another provider with no such flag, so the symptom was
    /// an app that found accessories and never once looked for a phone.
    ///
    /// The user's own switch is *Show Connected Apple Devices*, which decides
    /// whether `DevicePowerCenter` starts external providers at all. That is
    /// the privacy boundary, and it is the only one.
    init(
        source: DeviceBatterySource = MobileDeviceBatterySource(),
        topologyMonitor: MobileDeviceTopologyMonitoring = MobileDeviceTopologyMonitor(),
        featureEnabled: (() -> Bool)? = nil
    ) {
        self.source = source
        self.topologyMonitor = topologyMonitor
        self.featureEnabled = featureEnabled ?? { true }
    }

    func start(onUpdate: @escaping (DeviceProviderUpdate) -> Void) {
        guard status == .disabled else { return }
        self.onUpdate = onUpdate
        guard featureEnabled() else {
            // Started but inert: the coordinator gets one honest status and no
            // socket is ever opened.
            status = .unavailable
            DevicePowerLog.note("provider mobileDevice is behind a disabled flag")
            onUpdate(DeviceProviderUpdate(identifier: identifier, status: .unavailable, devices: []))
            return
        }
        status = .starting
        topologyMonitor.start { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        observeWake()
        DevicePowerLog.note("provider mobileDevice started")
        refresh()
    }

    func stop() {
        topologyMonitor.stop()
        readTask?.cancel()
        readTask = nil
        refreshPending = false
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        onUpdate = nil
        lastDevices = []
        status = .disabled
        DevicePowerLog.note("provider mobileDevice stopped")
    }

    func refresh() {
        guard status != .disabled, status != .unavailable || featureEnabled() else { return }
        guard featureEnabled() else { return }
        guard readTask == nil else {
            // A topology event, wake and manual refresh may coincide. One
            // follow-up read preserves the newest topology without starting
            // duplicate lockdown sessions.
            refreshPending = true
            return
        }

        readTask = Task { [weak self] in
            guard let self else { return }
            do {
                let devices = try await self.source.read()
                guard !Task.isCancelled else { return }
                self.publish(devices)
            } catch {
                guard !Task.isCancelled else { return }
                self.publish(failure: error)
            }
        }
    }

    private func publish(_ devices: [AppleDeviceSnapshot]) {
        readTask = nil
        guard onUpdate != nil else { return }
        lastDevices = devices
        status = .ready
        DevicePowerLog.note("mobile read returned \(devices.count) device(s)")
        onUpdate?(DeviceProviderUpdate(identifier: identifier, status: .ready, devices: devices))
        performPendingRefreshIfNeeded()
    }

    /// Trust is not a failure, it is an instruction.
    ///
    /// A device this Mac has never been trusted with maps to
    /// `permissionRequired`, which is the state the interface turns into
    /// "unlock your iPhone and tap Trust". Everything the phone genuinely
    /// cannot answer stays `unavailable`, and everything transient keeps the
    /// last good reading.
    private func publish(failure error: Error) {
        readTask = nil
        guard onUpdate != nil else { return }
        let status: DeviceProviderStatus
        switch error {
        case MobileDeviceError.notTrusted, MobileDeviceError.deviceLocked:
            status = .permissionRequired
        case MobileDeviceError.sessionRequired,
             MobileDeviceError.transportUnavailable,
             MobileDeviceError.batteryUnavailable:
            status = .unavailable
        default:
            status = .temporarilyFailed
        }
        self.status = status
        DevicePowerLog.note("mobile read ended as \(status)")
        onUpdate?(
            DeviceProviderUpdate(
                identifier: identifier,
                status: status,
                devices: status == .temporarilyFailed ? lastDevices : []
            )
        )
        performPendingRefreshIfNeeded()
    }

    private func performPendingRefreshIfNeeded() {
        guard refreshPending else { return }
        refreshPending = false
        refresh()
    }

    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}

/// The reading half: usbmuxd conversation to device snapshots.
///
/// Not main-actor isolated, and this is the type the architectural test in
/// `DevicePowerCenterTests` exists to protect. Socket I/O on the actor that
/// draws the panel would freeze it for as long as a sleeping phone takes to
/// answer.
struct MobileDeviceBatterySource: DeviceBatterySource {
    private let client: MobileDeviceClient
    private let clock: DeviceClock
    private let resolver: DeviceIdentityResolver

    init(
        client: MobileDeviceClient = MobileDeviceClient(),
        clock: DeviceClock = SystemDeviceClock(),
        resolver: DeviceIdentityResolver = .shared
    ) {
        self.client = client
        self.clock = clock
        self.resolver = resolver
    }

    func read() async throws -> [AppleDeviceSnapshot] {
        let devices = try client.listDevices()
        guard !devices.isEmpty else { return [] }
        let routes = Self.routesByDevice(devices)

        let now = clock.now
        var snapshots: [AppleDeviceSnapshot] = []
        var pendingTrust: Error?

        for deviceRoutes in routes {
            try Task.checkCancellation()
            // A device that has never been trusted cannot be read at all, and
            // asking anyway produces the pairing dialog on the phone — which is
            // a prompt the user did not ask this Mac to raise.
            guard let firstRoute = deviceRoutes.first,
                  try client.isTrusted(firstRoute) else {
                pendingTrust = MobileDeviceError.notTrusted
                continue
            }

            var routeFailure: MobileDeviceError?
            for device in deviceRoutes {
                do {
                    let reading = try client.batteryReading(for: device)
                    guard let snapshot = Self.snapshot(
                        from: reading,
                        device: device,
                        now: now,
                        resolver: resolver
                    ) else { continue }
                    snapshots.append(snapshot)
                    routeFailure = nil
                    break
                } catch let error as MobileDeviceError {
                    // The cable can disappear between ListDevices and Connect.
                    // If macOS advertised the same phone over Network too, try
                    // that route before turning a harmless transition into an
                    // unavailable card.
                    routeFailure = error
                }
            }

            if let routeFailure {
                // One unhappy physical phone does not spoil the list. Multiple
                // transport entries for it still count as one device.
                if routes.count == 1 { throw routeFailure }
                pendingTrust = pendingTrust ?? routeFailure
            }
        }

        if snapshots.isEmpty, let pendingTrust { throw pendingTrust }
        return snapshots
    }

    /// One physical device, one ordered route list. The stable raw identifier
    /// is used only inside this transport boundary; the transient numeric IDs
    /// are routes, and USB wins while both routes are present.
    static func routesByDevice(_ devices: [MobileDeviceDescriptor]) -> [[MobileDeviceDescriptor]] {
        var order: [String] = []
        var grouped: [String: [MobileDeviceDescriptor]] = [:]
        for device in devices {
            if grouped[device.rawIdentifier] == nil {
                order.append(device.rawIdentifier)
                grouped[device.rawIdentifier] = []
            }
            if !(grouped[device.rawIdentifier]?.contains(device) ?? false) {
                grouped[device.rawIdentifier, default: []].append(device)
            }
        }
        return order.compactMap { identifier in
            grouped[identifier]?.sorted { lhs, rhs in
                if lhs.connection != rhs.connection { return lhs.connection == .usb }
                return lhs.deviceID < rhs.deviceID
            }
        }
    }

    /// No percentage, no device. A phone that answered without a battery value
    /// is a phone we know nothing useful about, and a card that says nothing is
    /// worse than no card.
    static func snapshot(
        from reading: MobileDeviceBatteryReading,
        device: MobileDeviceDescriptor,
        now: Date,
        resolver: DeviceIdentityResolver
    ) -> AppleDeviceSnapshot? {
        guard reading.hasBattery else { return nil }
        let kind = self.kind(from: reading.productType)
        guard let identity = resolver.identity(forRawIdentifier: device.rawIdentifier, kind: kind) else {
            return nil
        }

        let component = AppleDeviceNormalizer.component(
            kind: .primary,
            percentage: reading.percentage,
            chargingState: chargingState(from: reading, connection: device.connection),
            lastUpdated: now
        )
        guard let component else { return nil }

        return AppleDeviceSnapshot(
            identity: identity,
            kind: kind,
            displayName: AppleDeviceNormalizer.displayName(
                reading.deviceName,
                fallback: kind == .iPad ? "iPad" : "iPhone"
            ),
            connection: device.connection.snapshotConnection,
            availability: .connected,
            externalPower: reading.externallyConnected.map { $0 ? .connected : .disconnected } ?? .unknown,
            components: [component],
            lastSeen: now,
            lastUpdated: now,
            source: device.connection.snapshotSource,
            capabilities: AppleDeviceNormalizer.capabilities(for: [component])
        )
    }

    /// The device's own model identifier, not a guess from a product name.
    /// Anything unrecognised stays unknown rather than being called an iPhone.
    static func kind(from productType: String?) -> AppleDeviceKind {
        guard let productType = productType?.lowercased() else { return .unknown }
        if productType.hasPrefix("iphone") { return .iPhone }
        if productType.hasPrefix("ipad") { return .iPad }
        return .unknown
    }

    static func chargingState(
        from reading: MobileDeviceBatteryReading,
        connection: MobileDeviceConnection = .usb
    ) -> DeviceChargingState? {
        guard let isCharging = reading.isCharging else { return nil }
        if isCharging { return .charging }
        // Not charging while plugged in is a real state and a different one
        // from running on the battery.
        guard let external = reading.externallyConnected else { return nil }
        if external { return .notCharging }
        // Over Wi-Fi the useful human-facing state is simply that the phone is
        // not charging. "On Battery" describes the Mac power source well, but
        // reads oddly beside a remote iPhone card.
        return connection == .network ? .notCharging : .discharging
    }
}
