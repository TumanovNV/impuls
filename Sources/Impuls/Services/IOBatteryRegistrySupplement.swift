import Foundation
import IOKit

/// The documented IOPowerSources dictionary covers the live battery state.
/// Cycle count is not one of its documented keys, so it is read separately
/// through the public IORegistry API and kept isolated here. `CycleCount` is
/// an undocumented property name; a missing or malformed value is normal.
enum IOBatteryRegistrySupplement {
    private static let smartBatteryService = "AppleSmartBattery"
    private static let cycleCountKey = "CycleCount"

    static func cycleCount() -> Int? {
        guard let matching = IOServiceMatching(smartBatteryService) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let value = IORegistryEntryCreateCFProperty(
            service,
            cycleCountKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber else { return nil }
        return value.intValue
    }
}
