import Foundation
import IOKit

/// The documented IOPowerSources dictionary covers the live battery state.
/// A few portable Macs omit capacity, amperage and temperature values from
/// that dictionary even though the battery service exposes them. The registry
/// API is public, but its individual property names are not a compatibility
/// promise, so this remains a conservative best-effort supplement.
struct IOBatteryRegistryReading: Equatable {
    let currentCapacity: Int?
    let maxCapacity: Int?
    let designCapacity: Int?
    let voltageMillivolts: Int?
    let currentMilliamps: Int?
    let temperatureCelsius: Double?
    let cycleCount: Int?

    static let unavailable = IOBatteryRegistryReading(
        currentCapacity: nil,
        maxCapacity: nil,
        designCapacity: nil,
        voltageMillivolts: nil,
        currentMilliamps: nil,
        temperatureCelsius: nil,
        cycleCount: nil
    )
}

enum IOBatteryRegistrySupplement {
    private static let smartBatteryService = "AppleSmartBattery"
    private static let currentCapacityKey = "CurrentCapacity"
    private static let maxCapacityKey = "MaxCapacity"
    private static let designCapacityKey = "DesignCapacity"
    private static let voltageKey = "Voltage"
    private static let amperageKey = "Amperage"
    private static let temperatureKey = "Temperature"
    private static let cycleCountKey = "CycleCount"

    static func reading() -> IOBatteryRegistryReading {
        guard let matching = IOServiceMatching(smartBatteryService) else { return .unavailable }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return .unavailable }
        defer { IOObjectRelease(service) }

        let rawTemperature = number(for: temperatureKey, service: service)
        return IOBatteryRegistryReading(
            currentCapacity: integer(for: currentCapacityKey, service: service),
            maxCapacity: integer(for: maxCapacityKey, service: service),
            designCapacity: integer(for: designCapacityKey, service: service),
            voltageMillivolts: integer(for: voltageKey, service: service),
            currentMilliamps: integer(for: amperageKey, service: service),
            temperatureCelsius: celsius(fromSmartBatteryTemperature: rawTemperature),
            cycleCount: integer(for: cycleCountKey, service: service)
        )
    }

    private static func integer(for key: String, service: io_registry_entry_t) -> Int? {
        RegistryNumber.integer(property(for: key, service: service))
    }

    private static func number(for key: String, service: io_registry_entry_t) -> Double? {
        RegistryNumber.double(property(for: key, service: service))
    }

    private static func property(for key: String, service: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }

    private static func celsius(fromSmartBatteryTemperature value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        // Smart Battery data follows the SMBus convention of tenths of Kelvin.
        // Do the conversion here rather than teaching the generic normalizer an
        // undocumented unit system used by only this optional fallback.
        let celsius = value / 10 - 273.15
        guard (-20...100).contains(celsius) else { return nil }
        return celsius
    }
}
