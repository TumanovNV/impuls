import Foundation

/// Arrival and departure notifications from the system usbmuxd daemon.
///
/// This is topology only. Battery reads retain their sparse scheduler cadence;
/// a phone appearing or changing from USB to Wi-Fi merely asks the provider for
/// one fresh snapshot. The socket is local, carries no application data, and is
/// closed synchronously when external-device discovery stops.
protocol MobileDeviceTopologyMonitoring: AnyObject, Sendable {
    func start(onChange: @escaping @Sendable () -> Void)
    func stop()
}

final class MobileDeviceTopologyMonitor: MobileDeviceTopologyMonitoring, @unchecked Sendable {
    static let initialRetryInterval: TimeInterval = 1
    static let maximumRetryInterval: TimeInterval = 60

    private struct State {
        var generation = 0
        var task: Task<Void, Never>?
        var channel: MobileDeviceByteChannel?
    }

    private let factory: MobileDeviceChannelFactory
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var state = State()

    init(
        factory: MobileDeviceChannelFactory = UnixSocketChannelFactory(),
        timeout: TimeInterval = MobileDeviceConversation.defaultTimeout
    ) {
        self.factory = factory
        self.timeout = timeout
    }

    deinit { stop() }

    func start(onChange: @escaping @Sendable () -> Void) {
        let generation: Int? = lock.withLock {
            guard state.task == nil else { return nil }
            state.generation += 1
            return state.generation
        }
        guard let generation else { return }

        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.run(generation: generation, onChange: onChange)
        }
        lock.withLock {
            guard state.generation == generation else {
                task.cancel()
                return
            }
            state.task = task
        }
    }

    func stop() {
        let stopped: (Task<Void, Never>?, MobileDeviceByteChannel?) = lock.withLock {
            state.generation += 1
            let result = (state.task, state.channel)
            state.task = nil
            state.channel = nil
            return result
        }
        stopped.0?.cancel()
        // Closing the descriptor wakes a blocking read immediately; waiting for
        // its ordinary timeout would leave discovery alive after the user had
        // switched external devices off.
        stopped.1?.close()
    }

    private func run(generation: Int, onChange: @escaping @Sendable () -> Void) async {
        var retryInterval = Self.initialRetryInterval
        var hasSubscribed = false

        while isCurrent(generation), !Task.isCancelled {
            do {
                let channel = try factory.connect()
                guard install(channel, generation: generation) else { return }
                defer {
                    channel.close()
                    clear(channel, generation: generation)
                }

                let conversation = MobileDeviceConversation(channel: channel, timeout: timeout)
                try conversation.sendUsbmux(Self.listenRequest, tag: 1)
                let reply = try conversation.receiveUsbmux()
                guard MobileDeviceClient.integer(reply["Number"]) == 0 else {
                    throw MobileDeviceError.serviceUnavailable("usbmuxd Listen refused")
                }

                // The provider performs its ordinary initial read itself. A
                // later subscription means the daemon/socket was lost (most
                // notably across sleep), so re-read topology even when no
                // individual Attached event survived the interruption.
                if hasSubscribed { onChange() }
                hasSubscribed = true

                while isCurrent(generation), !Task.isCancelled {
                    do {
                        let event = try conversation.receiveUsbmux()
                        if Self.isTopologyChange(event) {
                            retryInterval = Self.initialRetryInterval
                            onChange()
                        }
                    } catch MobileDeviceError.timedOut {
                        // A quiet daemon is healthy. The finite read deadline is
                        // only there so cancellation is observed even if close
                        // races with entering the next read.
                        retryInterval = Self.initialRetryInterval
                        continue
                    }
                }
            } catch {
                guard isCurrent(generation), !Task.isCancelled else { return }
                DevicePowerLog.note("mobile topology listener reconnecting")
            }

            guard isCurrent(generation), !Task.isCancelled else { return }
            let delay = UInt64(retryInterval * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            retryInterval = min(retryInterval * 2, Self.maximumRetryInterval)
        }
    }

    static func isTopologyChange(_ message: [String: Any]) -> Bool {
        guard let type = message["MessageType"] as? String else { return false }
        return type == "Attached" || type == "Detached"
    }

    private static let listenRequest: [String: Any] = [
        "MessageType": "Listen",
        "ClientVersionString": "Impuls",
        "ProgName": "Impuls",
        "kLibUSBMuxVersion": 3,
    ]

    private func isCurrent(_ generation: Int) -> Bool {
        lock.withLock { state.generation == generation }
    }

    private func install(_ channel: MobileDeviceByteChannel, generation: Int) -> Bool {
        let installed = lock.withLock { () -> Bool in
            guard state.generation == generation else { return false }
            state.channel = channel
            return true
        }
        if !installed { channel.close() }
        return installed
    }

    private func clear(_ channel: MobileDeviceByteChannel, generation: Int) {
        lock.withLock {
            guard state.generation == generation, state.channel === channel else { return }
            state.channel = nil
        }
    }
}
