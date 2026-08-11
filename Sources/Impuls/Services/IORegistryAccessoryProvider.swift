import AppKit
import Foundation
import IOKit

/// Batteries of Apple accessories, read from the IORegistry.
///
/// Named for what it does. It is not a Bluetooth provider: it opens no
/// CoreBluetooth session, starts no scan and asks for no Bluetooth permission,
/// because the values it needs are already published by the system and reading
/// them requires none of that. A real `CoreBluetoothAccessoryProvider` can be
/// added beside it the day some accessory genuinely needs GATT — and it would
/// have a permission prompt attached, which is exactly why the two should never
/// have shared a name.
///
/// Best-effort by construction. The service class is reachable through public
/// IOKit; the property names on it are not documented, so every one of them is
/// optional, no lifecycle depends on any of them, and an empty result is an
/// ordinary outcome rather than a failure.
@MainActor
final class IORegistryAccessoryProvider: DeviceBatteryProviding {
    let identifier = DeviceProviderIdentifier.ioRegistryAccessory

    /// Event-driven where the registry allows it, polled where it does not.
    ///
    /// IOKit will tell us when an accessory appears or disappears, and those
    /// notifications trigger an immediate read. It will not tell us when a
    /// battery level changes, so the level itself has to be asked for — slowly,
    /// because an accessory battery moves by a percent an hour and nobody is
    /// watching it when the panel is closed.
    let refreshBehavior = DeviceRefreshBehavior.polled(activeInterval: 60, idleInterval: 600)

    private(set) var status: DeviceProviderStatus = .disabled

    private let source: DeviceBatterySource
    private var onUpdate: ((DeviceProviderUpdate) -> Void)?
    private var notificationPort: IONotificationPortRef?
    private var matchedIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0
    private var readTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var lastDevices: [AppleDeviceSnapshot] = []

    init(source: DeviceBatterySource = IORegistryAccessorySource()) {
        self.source = source
    }

    deinit {
        // The task holds `self` weakly and the observers are removed in `stop`,
        // which the coordinator always calls. This is the belt for the braces:
        // an iterator left registered would keep delivering into a dead object.
        MainActor.assumeIsolated { teardownNotifications() }
    }

    func start(onUpdate: @escaping (DeviceProviderUpdate) -> Void) {
        guard status == .disabled else { return }
        self.onUpdate = onUpdate
        status = .starting
        installNotifications()
        observeWake()
        DevicePowerLog.note("provider ioRegistryAccessory started")
        refresh()
    }

    func stop() {
        readTask?.cancel()
        readTask = nil
        teardownNotifications()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        onUpdate = nil
        lastDevices = []
        status = .disabled
        DevicePowerLog.note("provider ioRegistryAccessory stopped")
    }

    func refresh() {
        guard status != .disabled else { return }
        // One read at a time. The scheduler, a wake notification and an
        // accessory connecting can all arrive within the same second, and three
        // concurrent registry walks would return the same answer three times.
        guard readTask == nil else { return }

        // The task inherits this actor, so `publish` lands back on the main
        // actor by itself. Only `read()` leaves it — that is the whole point of
        // the source being a separate, non-isolated protocol.
        readTask = Task { [weak self] in
            guard let self else { return }
            do {
                let devices = try await self.source.read()
                guard !Task.isCancelled else { return }
                self.publish(devices)
            } catch {
                guard !Task.isCancelled else { return }
                self.publishFailure()
            }
        }
    }

    // MARK: - Publishing

    private func publish(_ devices: [AppleDeviceSnapshot]) {
        readTask = nil
        guard onUpdate != nil else { return }
        lastDevices = devices
        status = .ready
        DevicePowerLog.note("accessory read returned \(devices.count) device(s)")
        onUpdate?(DeviceProviderUpdate(identifier: identifier, status: .ready, devices: devices))
    }

    private func publishFailure() {
        readTask = nil
        guard onUpdate != nil else { return }
        status = .temporarilyFailed
        // The last good list travels with the failure so the coordinator can
        // keep showing it with its age rather than blanking the section.
        onUpdate?(
            DeviceProviderUpdate(identifier: identifier, status: .temporarilyFailed, devices: lastDevices)
        )
    }

    // MARK: - IOKit notifications

    /// Registers for accessory arrival and departure.
    ///
    /// These are the only events the registry offers here — there is no
    /// notification for a battery level changing — so they are used for what
    /// they are: the moments when the list itself changes, which is when a
    /// person most expects the panel to be right.
    private func installNotifications() {
        guard notificationPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        let context = Unmanaged.passUnretained(self).toOpaque()
        // Each registration consumes a reference to its matching dictionary, so
        // the two calls cannot share one.
        if let matching = IOServiceMatching(IORegistryAccessoryMapper.serviceClass) {
            IOServiceAddMatchingNotification(
                port,
                kIOMatchedNotification,
                matching,
                Self.serviceChanged,
                context,
                &matchedIterator
            )
            Self.drain(matchedIterator)
        }
        if let matching = IOServiceMatching(IORegistryAccessoryMapper.serviceClass) {
            IOServiceAddMatchingNotification(
                port,
                kIOTerminatedNotification,
                matching,
                Self.serviceChanged,
                context,
                &terminatedIterator
            )
            Self.drain(terminatedIterator)
        }
    }

    private func teardownNotifications() {
        if matchedIterator != 0 {
            IOObjectRelease(matchedIterator)
            matchedIterator = 0
        }
        if terminatedIterator != 0 {
            IOObjectRelease(terminatedIterator)
            terminatedIterator = 0
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
    }

    private static let serviceChanged: IOServiceMatchingCallback = { context, iterator in
        // The iterator must be drained or the notification never fires again.
        drain(iterator)
        guard let context else { return }
        let provider = Unmanaged<IORegistryAccessoryProvider>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in provider.refresh() }
    }

    private static func drain(_ iterator: io_iterator_t) {
        guard iterator != 0 else { return }
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }

    /// After the Mac wakes, whatever we knew is from before it slept.
    ///
    /// One read, not a burst: the accessories reconnect over the following
    /// seconds and each reconnection already produces its own notification, so
    /// this exists to cover the ones that never went away.
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
