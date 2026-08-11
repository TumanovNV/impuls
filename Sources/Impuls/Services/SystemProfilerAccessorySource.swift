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
        self.runner = runner ?? { try SystemProfilerAccessorySource.runSystemProfiler() }
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

    static func runSystemProfiler() throws -> Data {
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

        do {
            try process.run()
        } catch {
            throw MobileDeviceError.transportUnavailable
        }

        let collector = OutputCollector()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            collector.drain(output.fileHandleForReading, limit: maximumOutputBytes, keeping: true)
            finished.signal()
        }
        // Drained but discarded: an undrained stderr pipe can fill and block the
        // child forever, and its contents are of no use to anyone here.
        DispatchQueue.global(qos: .utility).async {
            collector.drain(errors.fileHandleForReading, limit: maximumErrorBytes, keeping: false)
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            // A tool that ignored SIGTERM gets one grace period, then the
            // descriptors are released regardless.
            _ = finished.wait(timeout: .now() + 1)
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            throw MobileDeviceError.timedOut
        }

        process.waitUntilExit()
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()

        guard process.terminationStatus == 0 else { throw MobileDeviceError.transportUnavailable }
        if collector.wasTruncated { throw MobileDeviceError.payloadTooLarge(maximumOutputBytes) }
        return collector.data
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        private var truncated = false

        var data: Data { lock.withLock { storage } }
        var wasTruncated: Bool { lock.withLock { truncated } }

        func drain(_ handle: FileHandle, limit: Int, keeping: Bool) {
            var total = 0
            while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                total += chunk.count
                if total > limit {
                    lock.withLock { truncated = true }
                    break
                }
                guard keeping else { continue }
                lock.withLock { storage.append(chunk) }
            }
        }
    }
}
