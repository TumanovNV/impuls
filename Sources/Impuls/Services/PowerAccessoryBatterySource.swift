import Foundation

/// Runs `pmset` once, bounded, and returns accessory battery readings.
///
/// The second subprocess in Impuls, and it exists for the same reason as the
/// first: a measurement. A third-party headset macOS itself shows at 80%
/// publishes no battery field in `SPBluetoothDataType`, no battery property
/// anywhere in the IORegistry, and does not appear in the public
/// `IOPSCopyPowerSourcesList` at all. The number reaches macOS through
/// `IOPSCopyPowerSourcesByType`/`kIOPSAccessoryType`, which appear in no public
/// SDK header — so Impuls does not call them. It runs the shipped binary that
/// does.
///
/// **This is an undocumented compatibility surface.** `pmset` is a public system
/// tool at a fixed path, but `-g accps` and `-xml` are in no `man` page. The
/// contract is therefore deliberately weak in one direction only: every failure
/// — tool missing, non-zero exit, timeout, output that is not a plist, a schema
/// Apple changes — yields *no readings*, which costs a battery value and
/// nothing else. Power keeps working, the other sources keep working, and no
/// value is ever guessed to fill the gap.
///
/// The process boundary is the same one `SystemProfilerAccessorySource`
/// documents: fixed absolute path, fixed arguments, no shell, empty
/// environment, bounded output, deadline, and nothing from stdout or stderr in
/// a production log.
final class PowerAccessoryBatterySource: @unchecked Sendable {
    static let executablePath = "/usr/bin/pmset"
    static let arguments = ["-g", "accps", "-xml"]

    /// Measured output for one accessory is a few kilobytes. 256 KB is far
    /// beyond any plausible accessory count and still bounded.
    static let maximumOutputBytes = 256 * 1024
    static let maximumErrorBytes = 8 * 1024
    static let timeout: TimeInterval = 5

    private let runner: @Sendable () throws -> Data

    init(runner: (@Sendable () throws -> Data)? = nil) {
        self.runner = runner ?? { try BoundedProcess.powerAccessories().run() }
    }

    /// Never throws. A failure here is an absent overlay, not a provider error:
    /// the devices this would have decorated are still listed by the sources
    /// that found them, and a device with no reading is dropped exactly as it
    /// was before this source existed.
    func readings() -> [PowerAccessoryReading] {
        guard let data = try? runner() else { return [] }
        return PowerAccessoryBatteryParser.readings(fromXML: data)
    }
}

extension BoundedProcess {
    static func powerAccessories() -> BoundedProcess {
        BoundedProcess(
            executablePath: PowerAccessoryBatterySource.executablePath,
            arguments: PowerAccessoryBatterySource.arguments,
            timeout: PowerAccessoryBatterySource.timeout,
            maximumOutputBytes: PowerAccessoryBatterySource.maximumOutputBytes,
            maximumErrorBytes: PowerAccessoryBatterySource.maximumErrorBytes
        )
    }
}
