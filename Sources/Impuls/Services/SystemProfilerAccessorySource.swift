import Foundation

/// Runs `system_profiler` once, bounded, and hands the bytes to the parser.
///
/// This is the first subprocess in Impuls, and it exists because a measurement
/// forced it: with AirPods Pro connected and macOS showing their charge, the
/// IORegistry publishes nothing — no battery property, no AirPods node at all.
/// The value the user sees comes from `bluetoothd`, and this is the only
/// non-private way found to reach it.
///
/// It is named for what it is. Nothing here pretends to be a registry read, and
/// the process boundary is deliberately narrow:
///
/// - a fixed absolute executable path, never a `$PATH` lookup;
/// - a fixed argument list, never anything a user typed;
/// - no shell at any point — `Process` runs the binary directly, so there is no
///   string for an injection to live in;
/// - an empty environment, verified to be enough for this tool;
/// - bounded stdout and stderr, a deadline, and termination when it expires;
/// - output that is malformed or oversized becomes an ordinary provider
///   failure, never a parse of whatever arrived;
/// - nothing from stdout or stderr reaches a production log.
final class SystemProfilerAccessorySource: DeviceBatterySource, @unchecked Sendable {
    static let executablePath = "/usr/sbin/system_profiler"
    /// JSON, not the text form: these keys are stable identifiers, while the
    /// text output is localised and would make the parser depend on the
    /// language the Mac happens to be set to.
    static let arguments = ["-json", "SPBluetoothDataType"]

    /// The measured output is about 2 KB. A megabyte is four hundred times that
    /// and still small enough that a runaway tool cannot exhaust memory.
    static let maximumOutputBytes = 1 << 20
    static let maximumErrorBytes = 8 * 1024
    static let timeout: TimeInterval = 5

    /// Measured at 0.08–0.12 s wall clock and ~2 KB of output on this Mac, so
    /// the cost is small — but it is a process spawn, and a process spawn every
    /// minute for a number that moves by one percent an hour is waste. This is
    /// the floor between two runs; the scheduler's cadence sits above it, and
    /// opening the panel is what actually asks for a fresh one.
    static let minimumInterval: TimeInterval = 30

    private let clock: DeviceClock
    private let resolver: DeviceIdentityResolver
    private let runner: @Sendable () throws -> Data
    private let lock = NSLock()
    private var cachedDevices: [AppleDeviceSnapshot] = []
    private var lastRun: Date?

    init(
        clock: DeviceClock = SystemDeviceClock(),
        resolver: DeviceIdentityResolver = .shared,
        runner: (@Sendable () throws -> Data)? = nil
    ) {
        self.clock = clock
        self.resolver = resolver
        self.runner = runner ?? { try BoundedProcess.systemProfiler().run() }
    }

    func read() async throws -> [AppleDeviceSnapshot] {
        let now = clock.now
        if let cached = cachedResult(now: now) { return cached }

        let data = try runner()
        let devices = try SystemProfilerAccessoryParser.devices(fromJSON: data, now: now, resolver: resolver)
        lock.withLock {
            cachedDevices = devices
            lastRun = now
        }
        return devices
    }

    /// Forget the cache, so the next read really runs the tool. Used when the
    /// panel opens, which is the one moment the answer has to be current.
    func invalidate() {
        lock.withLock { lastRun = nil }
    }

    private func cachedResult(now: Date) -> [AppleDeviceSnapshot]? {
        lock.withLock {
            guard let lastRun, now.timeIntervalSince(lastRun) < Self.minimumInterval else { return nil }
            return cachedDevices
        }
    }

    // MARK: - The process
}

/// One short-lived child process, with a deadline on its whole life.
///
/// Written as its own type so the boundary can be tested with something other
/// than `system_profiler`: a tool that never exits, a tool that floods stdout,
/// a tool that fails. An injected closure that throws on cue proves nothing
/// about process handling, and process handling is where this class of bug
/// lives.
///
/// Three rules, each of which was a real failure mode in the first version:
///
/// - the deadline covers the **process**, not the arrival of end-of-file on
///   stdout. Waiting for EOF and then calling `waitUntilExit()` means an
///   unbounded wait on a child that has stopped talking but not stopped;
/// - the pipes keep being drained even after the output limit is passed. A
///   reader that walks away leaves the child blocked on a full pipe forever,
///   which is the same hang wearing a different hat;
/// - passing the limit terminates the child immediately rather than at the end,
///   because there is nothing more to learn from it.
struct BoundedProcess {
    let executablePath: String
    let arguments: [String]
    let timeout: TimeInterval
    let maximumOutputBytes: Int
    let maximumErrorBytes: Int

    static func systemProfiler() -> BoundedProcess {
        BoundedProcess(
            executablePath: SystemProfilerAccessorySource.executablePath,
            arguments: SystemProfilerAccessorySource.arguments,
            timeout: SystemProfilerAccessorySource.timeout,
            maximumOutputBytes: SystemProfilerAccessorySource.maximumOutputBytes,
            maximumErrorBytes: SystemProfilerAccessorySource.maximumErrorBytes
        )
    }

    /// How long a terminated child is given to die before it is killed.
    static let terminationGrace: TimeInterval = 1

    func run() throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw MobileDeviceError.transportUnavailable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        // Nothing inherited. The tool was verified to work with none, and an
        // inherited environment is a channel this process does not need.
        process.environment = [:]

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            throw MobileDeviceError.transportUnavailable
        }

        let collector = OutputCollector()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            collector.drain(
                output.fileHandleForReading,
                limit: maximumOutputBytes,
                keeping: true,
                onOverflow: { Self.terminate(process) }
            )
            drained.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            collector.drain(
                errors.fileHandleForReading,
                limit: maximumErrorBytes,
                keeping: false,
                onOverflow: { Self.terminate(process) }
            )
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            Self.terminate(process)
            if exited.wait(timeout: .now() + Self.terminationGrace) == .timedOut {
                // A child that ignored SIGTERM gets SIGKILL, which it cannot.
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + Self.terminationGrace)
            }
        }

        // The reader ends when the pipe reaches end-of-file, which the dead
        // child guarantees. Bounded anyway: this method never waits on anything
        // without a limit.
        _ = drained.wait(timeout: .now() + Self.terminationGrace)
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()

        if timedOut { throw MobileDeviceError.timedOut }
        if collector.wasTruncated { throw MobileDeviceError.payloadTooLarge(maximumOutputBytes) }
        guard process.terminationStatus == 0 else { throw MobileDeviceError.transportUnavailable }
        return collector.data
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        private var truncated = false

        var data: Data { lock.withLock { storage } }
        var wasTruncated: Bool { lock.withLock { truncated } }

        /// Reads to end-of-file, always. Past the limit it stops keeping bytes
        /// and asks for the child to be terminated, but it keeps reading —
        /// abandoning a pipe is how a child ends up blocked on a full one.
        func drain(_ handle: FileHandle, limit: Int, keeping: Bool, onOverflow: () -> Void) {
            var total = 0
            var overflowed = false
            while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                total += chunk.count
                if total > limit {
                    if !overflowed {
                        overflowed = true
                        lock.withLock { truncated = true }
                        onOverflow()
                    }
                    continue
                }
                guard keeping else { continue }
                lock.withLock { storage.append(chunk) }
            }
        }
    }
}
