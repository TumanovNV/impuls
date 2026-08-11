import Combine
import Foundation

/// The one place that knows about every Apple device Impuls can see.
///
/// It owns providers rather than being one, so the panel asks a single object
/// for a single list. Everything hardware-specific lives behind
/// `DeviceBatteryProviding`; nothing here knows what IOKit or a USB socket is.
///
/// Two ownership boundaries, not one:
///
/// - the **module** switch, which the Power module already has. Off means the
///   coordinator holds nothing at all;
/// - the **external devices** switch, which the user turns on deliberately.
///   Until they do, no external provider is even created, so an update from
///   1.4.5 to 1.4.6 cannot produce a permission prompt or a scan that nobody
///   asked for.
@MainActor
final class DevicePowerCenter: ObservableObject {
    @Published private(set) var devices: [AppleDeviceSnapshot] = []
    @Published private(set) var diagnostics: [DeviceProviderDiagnostic] = []

    private let localProvider: DeviceBatteryProviding
    private let externalProviders: [DeviceBatteryProviding]
    private let scheduler: DeviceRefreshScheduler
    private let clock: DeviceClock
    private let staleInterval: TimeInterval

    /// The last good view from each provider, kept per provider on purpose.
    ///
    /// A transient failure must not blank the list. A phone that failed one
    /// read is still a phone whose charge we knew a minute ago, and the
    /// interface can say so with a timestamp; replacing it with nothing would
    /// be losing information we have, which is a different lie from the one
    /// this module refuses to tell.
    private var lastGoodDevices: [DeviceProviderIdentifier: [AppleDeviceSnapshot]] = [:]
    private var statuses: [DeviceProviderIdentifier: DeviceProviderStatus] = [:]

    private var isModuleEnabled = false
    private var isExternalEnabled = false
    private var isActive = false
    private var startedProviders: [DeviceProviderIdentifier: DeviceBatteryProviding] = [:]

    init(
        localProvider: DeviceBatteryProviding,
        externalProviders: [DeviceBatteryProviding] = [],
        scheduler: DeviceRefreshScheduler? = nil,
        clock: DeviceClock = SystemDeviceClock(),
        staleInterval: TimeInterval = DeviceSnapshotMerger.defaultStaleInterval
    ) {
        self.localProvider = localProvider
        self.externalProviders = externalProviders
        // Constructed here rather than as a default argument: the scheduler is
        // main-actor isolated, and a default argument is evaluated outside the
        // initialiser's isolation.
        self.scheduler = scheduler ?? DeviceRefreshScheduler()
        self.clock = clock
        self.staleInterval = staleInterval
    }

    /// The arrangement the application uses.
    ///
    /// External providers are constructed here but not started: construction is
    /// inert — no registry walk, no notification, no permission — and
    /// `setExternalDevicesEnabled` is the only thing that wakes them.
    convenience init(monitor: PowerMonitor, clock: DeviceClock = SystemDeviceClock()) {
        self.init(
            localProvider: LocalMacDeviceProvider(monitor: monitor, clock: clock),
            externalProviders: [IORegistryAccessoryProvider(source: IORegistryAccessorySource(clock: clock))],
            clock: clock
        )
    }

    /// The module setting, mirroring `PowerMonitor.setEnabled`.
    func setEnabled(_ enabled: Bool) {
        guard isModuleEnabled != enabled else { return }
        isModuleEnabled = enabled
        enabled ? startProviders() : stopProviders()
    }

    /// The user's own decision to look for their other devices.
    func setExternalDevicesEnabled(_ enabled: Bool) {
        guard isExternalEnabled != enabled else { return }
        isExternalEnabled = enabled
        guard isModuleEnabled else { return }
        enabled ? startExternalProviders() : stopExternalProviders()
    }

    /// The panel opened or closed.
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        scheduler.setActive(active)
        guard isModuleEnabled, active else { return }
        // Opening is the one moment a person is definitely looking, so it is
        // worth one immediate read rather than waiting out the interval.
        for provider in startedProviders.values where provider.identifier != .localMac {
            provider.refresh()
        }
    }

    /// An explicit refresh — the button in Settings, or the discovery action.
    func refreshExternalDevices() {
        guard isModuleEnabled, isExternalEnabled else { return }
        for provider in startedProviders.values where provider.identifier != .localMac {
            provider.refresh()
        }
    }

    func stop() {
        setEnabled(false)
    }

    /// Devices with something worth showing. The Mac is always among them when
    /// the module is on, battery or not.
    var visibleDevices: [AppleDeviceSnapshot] {
        devices.filter { $0.identity.isLocalMac || $0.hasBatteryReading }
    }

    func freshness(for snapshot: AppleDeviceSnapshot) -> DeviceFreshness {
        DeviceSnapshotMerger.freshness(for: snapshot, now: clock.now, staleAfter: staleInterval)
    }

    // MARK: - Provider lifecycle

    private func startProviders() {
        start(localProvider)
        if isExternalEnabled { startExternalProviders() }
    }

    private func startExternalProviders() {
        guard !externalProviders.isEmpty else { return }
        for provider in externalProviders { start(provider) }
        scheduler.setProviders(Array(startedProviders.values))
        scheduler.setActive(isActive)
        scheduler.start()
    }

    private func start(_ provider: DeviceBatteryProviding) {
        guard startedProviders[provider.identifier] == nil else { return }
        startedProviders[provider.identifier] = provider
        statuses[provider.identifier] = .starting
        provider.start { [weak self] update in
            self?.apply(update)
        }
        publish()
    }

    private func stopProviders() {
        scheduler.stop()
        for provider in startedProviders.values { provider.stop() }
        startedProviders = [:]
        lastGoodDevices = [:]
        statuses = [:]
        publish()
    }

    private func stopExternalProviders() {
        scheduler.stop()
        for (identifier, provider) in startedProviders where identifier != .localMac {
            provider.stop()
            startedProviders[identifier] = nil
            lastGoodDevices[identifier] = nil
            statuses[identifier] = nil
        }
        publish()
    }

    // MARK: - Updates

    private func apply(_ update: DeviceProviderUpdate) {
        // A provider that has been stopped is not allowed to keep publishing.
        // This is a guard against the class of bug where an in-flight task
        // lands after the module was switched off and quietly revives it.
        guard startedProviders[update.identifier] != nil else { return }

        statuses[update.identifier] = update.status
        switch update.status {
        case .temporarilyFailed:
            // Keep whatever this provider last knew; the age is visible.
            DevicePowerLog.note("provider \(update.identifier.rawValue) failed temporarily")
        case .disabled, .permissionRequired, .unavailable:
            lastGoodDevices[update.identifier] = []
        case .starting, .ready:
            lastGoodDevices[update.identifier] = update.devices
        }

        scheduler.noteOutcome(
            for: update.identifier,
            succeeded: update.status == .ready || update.status == .starting
        )
        publish()
    }

    private func publish() {
        let now = clock.now
        let merged = DeviceSnapshotMerger.merge(
            Array(lastGoodDevices.values),
            now: now,
            staleAfter: staleInterval
        )
        if merged != devices { devices = merged }

        let diagnostics = DeviceProviderIdentifier.allCases.compactMap { identifier -> DeviceProviderDiagnostic? in
            guard let status = statuses[identifier] else { return nil }
            return DeviceProviderDiagnostic(
                provider: identifier,
                status: status,
                deviceCount: lastGoodDevices[identifier]?.count ?? 0
            )
        }
        if diagnostics != self.diagnostics { self.diagnostics = diagnostics }
    }
}
