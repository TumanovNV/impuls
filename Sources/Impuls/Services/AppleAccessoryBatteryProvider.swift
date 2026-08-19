import AppKit
import Foundation
import IOKit

/// Batteries of Apple accessories, from whichever source actually has them.
///
/// Two sources, because one measurement forced it. The IORegistry path is
/// cheap, event-adjacent and needs no process — and on the Mac this was
/// developed against, with AirPods Pro connected and macOS displaying their
/// charge, it publishes nothing at all. The `system_profiler` path costs a
/// process spawn and answers.
///
/// So the registry is asked first and `system_profiler` fills what it left
/// empty. Neither is authoritative; both are best-effort; a device that neither
/// can describe is simply not in the list.
///
/// Not a Bluetooth provider under either name: no CoreBluetooth session, no
/// scan, no Bluetooth permission prompt. A real `CoreBluetoothAccessoryProvider`
/// can be added the day some accessory genuinely needs GATT — and it would
/// bring a permission prompt with it, which is why it should never share a name
/// with something that does not.
@MainActor
final class AppleAccessoryBatteryProvider: DeviceBatteryProviding {
    let identifier = DeviceProviderIdentifier.appleAccessory

    /// Event-driven where the registry allows it, polled where it does not.
    ///
    /// IOKit will tell us when an accessory appears or disappears, and those
    /// notifications trigger an immediate read. They do not describe AirPods
    /// component topology, though: hardware QA measured the public macOS source
    /// taking more than 30 seconds to add a bud and retaining a returned bud as
    /// last-known for at least 30 seconds. While the panel is visible, ten-second
    /// polling is a bounded attempt to observe the source changing. When it is
    /// closed, battery level alone is not worth more than a ten-minute cadence.
    let refreshBehavior = DeviceRefreshBehavior.polled(activeInterval: 10, idleInterval: 600)

    private(set) var status: DeviceProviderStatus = .disabled

    private let registrySource: DeviceBatterySource
    private let profilerSource: SystemProfilerAccessorySource?
    private var onUpdate: ((DeviceProviderUpdate) -> Void)?
    // Plain C handles, and the only state `deinit` has to reach. They are
    // created and released on the main actor by `installNotifications` and
    // `stop`; `deinit` is the one other writer, and it runs when nothing else
    // can still hold a reference. Declared `nonisolated(unsafe)` so the release
    // path does not have to assert an actor it may not be running on — see the
    // note on `deinit`.
    private nonisolated(unsafe) var notificationPort: IONotificationPortRef?
    private nonisolated(unsafe) var matchedIterator: io_iterator_t = 0
    private nonisolated(unsafe) var terminatedIterator: io_iterator_t = 0
    private var readTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var lastDevices: [AppleDeviceSnapshot] = []

    init(
        registrySource: DeviceBatterySource = IORegistryAccessorySource(),
        profilerSource: SystemProfilerAccessorySource? = SystemProfilerAccessorySource()
    ) {
        self.registrySource = registrySource
        self.profilerSource = profilerSource
    }

    deinit {
        // The task holds `self` weakly and the observers are removed in `stop`,
        // which the coordinator always calls. This is the belt for the braces:
        // an iterator left registered would keep delivering into a dead object.
        //
        // `deinit` is nonisolated, so it cannot assume the main actor: the last
        // reference being released from anywhere else would have turned this
        // safety net into the crash it exists to prevent. The teardown touches
        // only C handles and is nonisolated for that reason.
        teardownNotifications()
    }

    func start(onUpdate: @escaping (DeviceProviderUpdate) -> Void) {
        guard status == .disabled else { return }
        self.onUpdate = onUpdate
        status = .starting
        installNotifications()
        observeWake()
        DevicePowerLog.note("provider appleAccessory started")
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
        DevicePowerLog.note("provider appleAccessory stopped")
    }

    func refresh() {
        guard status != .disabled else { return }
        // One read at a time. The scheduler, a wake notification and an
        // accessory connecting can all arrive within the same second, and three
        // concurrent registry walks and process spawns would return the same
        // answer three times. Cadence belongs here and in the scheduler; the
        // source itself never caches, so a manual refresh is always a real read.
        guard readTask == nil else { return }

        // The task inherits this actor, so `publish` lands back on the main
        // actor by itself. Only `read()` leaves it — that is the whole point of
        // the source being a separate, non-isolated protocol.
        readTask = Task { [weak self] in
            guard let self else { return }
            let registry = self.registrySource
            let profiler = self.profilerSource
            do {
                let devices = try await Self.combined(registry: registry, profiler: profiler)
                guard !Task.isCancelled else { return }
                self.publish(devices)
            } catch {
                guard !Task.isCancelled else { return }
                self.publishFailure()
            }
        }
    }

    /// The registry first, then whatever it could not describe.
    ///
    /// A failure in either source is survivable on its own: if the registry
    /// throws, the process path may still answer, and the reverse holds too.
    /// Only losing both is a failure worth reporting, and even then the
    /// coordinator keeps the last good list.
    private static func combined(
        registry: DeviceBatterySource,
        profiler: DeviceBatterySource?
    ) async throws -> [AppleDeviceSnapshot] {
        var devices: [AppleDeviceSnapshot] = []
        var registryFailure: Error?
        do {
            devices = try await registry.read()
        } catch {
            registryFailure = error
        }

        guard let profiler else {
            if let registryFailure { throw registryFailure }
            return devices
        }

        do {
            let seen = Set(devices.map(\.identity))
            // Identity, not name: both sources derive it from the same hardware
            // address, so the same accessory described twice collapses here
            // rather than appearing twice in the panel.
            let extra = try await profiler.read().filter { !seen.contains($0.identity) }
            devices.append(contentsOf: extra)
        } catch {
            if devices.isEmpty, let registryFailure { throw registryFailure }
            if devices.isEmpty { throw error }
        }
        return devices
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

    private nonisolated func teardownNotifications() {
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
        let provider = Unmanaged<AppleAccessoryBatteryProvider>.fromOpaque(context).takeUnretainedValue()
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
