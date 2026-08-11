import Foundation

/// The current time, as a dependency.
///
/// Staleness is the one rule in this module that cannot be tested by feeding it
/// different inputs: it depends on how much time has passed. A test that waits
/// out a real minute is a test nobody runs, so the clock is injected and the
/// tests move it themselves.
protocol DeviceClock: Sendable {
    var now: Date { get }
}

struct SystemDeviceClock: DeviceClock {
    var now: Date { Date() }
}
