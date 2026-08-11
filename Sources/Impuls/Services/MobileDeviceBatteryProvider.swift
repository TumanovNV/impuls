import Foundation

/// iPhone and iPad batteries over USB — experimental, and off by default.
///
/// Everything about this provider is deliberately quarantined. The protocol it
/// speaks is Apple's own and undocumented; writing the client ourselves keeps
/// the licence clean and adds no dependency, but it does not turn an
/// undocumented protocol into a supported API. If Apple changes it, this row
/// disappears from the panel and nothing else in Impuls notices — not the Mac's
/// battery, not the accessories, not any other module.
///
/// It does not run unless someone asks for it twice: the user has to turn on
/// Apple devices, and the flag below has to be set. Until hardware validation
/// exists, that flag stays off, and the capability document says so.
@MainActor
final class MobileDeviceBatteryProvider: DeviceBatteryProviding {
    /// Off unless explicitly enabled, and not exposed in Settings yet.
    ///
    /// Shipping a switch for something that has never been proven against a
    /// real phone would be promising a feature; this is how it gets tested on
    /// hardware without promising anything.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["IMPULS_MOBILE_DEVICE_BATTERY"] == "1"
            || UserDefaults.standard.bool(forKey: "experimentalMobileDeviceBattery")
    }

    let identifier = DeviceProviderIdentifier.mobileUSB

    /// A phone's charge moves slowly and a USB conversation is not free, so it
    /// is asked rarely. Connection and disconnection are not observed here:
    /// usbmuxd can report them, and that is a natural improvement once the read
    /// itself is proven to work on hardware.
    let refreshBehavior = DeviceRefreshBehavior.polled(activeInterval: 60, idleInterval: 900)

    private(set) var status: DeviceProviderStatus = .disabled

    private let source: DeviceBatterySource
    private var onUpdate: ((DeviceProviderUpdate) -> Void)?
    private var readTask: Task<Void, Never>?
    private var lastDevices: [AppleDeviceSnapshot] = []

    init(source: DeviceBatterySource = MobileDeviceBatterySource()) {
        self.source = source
    }

    func start(onUpdate: @escaping (DeviceProviderUpdate) -> Void) {
        guard status == .disabled else { return }
        self.onUpdate = onUpdate
        guard Self.isEnabled else {
            // Started but inert: the coordinator gets one honest status and no
            // socket is ever opened.
            status = .unavailable
            DevicePowerLog.note("provider mobileUSB is behind a disabled flag")
            onUpdate(DeviceProviderUpdate(identifier: identifier, status: .unavailable, devices: []))
            return
        }
        status = .starting
        DevicePowerLog.note("provider mobileUSB started")
        refresh()
    }

    func stop() {
        readTask?.cancel()
        readTask = nil
        onUpdate = nil
        lastDevices = []
        status = .disabled
        DevicePowerLog.note("provider mobileUSB stopped")
    }

    func refresh() {
        guard status != .disabled, status != .unavailable || Self.isEnabled else { return }
        guard Self.isEnabled, readTask == nil else { return }

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
        let devices = try client.listUSBDevices()
        guard !devices.isEmpty else { return [] }

        let now = clock.now
        var snapshots: [AppleDeviceSnapshot] = []
        var pendingTrust: Error?

        for device in devices {
            try Task.checkCancellation()
            // A device that has never been trusted cannot be read at all, and
            // asking anyway produces the pairing dialog on the phone — which is
            // a prompt the user did not ask this Mac to raise.
            guard try client.isTrusted(device) else {
                pendingTrust = MobileDeviceError.notTrusted
                continue
            }
            do {
                let reading = try client.batteryReading(for: device)
                guard let snapshot = Self.snapshot(
                    from: reading,
                    device: device,
                    now: now,
                    resolver: resolver
                ) else { continue }
                snapshots.append(snapshot)
            } catch let error as MobileDeviceError {
                // One unhappy phone does not spoil the list. If it is the only
                // one, its state is what the provider reports.
                if devices.count == 1 { throw error }
                pendingTrust = pendingTrust ?? error
            }
        }

        if snapshots.isEmpty, let pendingTrust { throw pendingTrust }
        return snapshots
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
            chargingState: chargingState(from: reading),
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
            connection: .usb,
            availability: .connected,
            externalPower: reading.externallyConnected.map { $0 ? .connected : .disconnected } ?? .unknown,
            components: [component],
            lastSeen: now,
            lastUpdated: now,
            source: .mobileUSB,
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

    static func chargingState(from reading: MobileDeviceBatteryReading) -> DeviceChargingState? {
        guard let isCharging = reading.isCharging else { return nil }
        if isCharging { return .charging }
        // Not charging while plugged in is a real state and a different one
        // from running on the battery.
        guard let external = reading.externallyConnected else { return nil }
        return external ? .notCharging : .discharging
    }
}
