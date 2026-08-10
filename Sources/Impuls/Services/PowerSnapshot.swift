import Foundation

/// A hardware-neutral view of the currently available power information.
/// Every hardware-dependent field is optional: absence is data in its own
/// right and must never be rewritten as a zero or a diagnosis.
enum PowerDeviceKind: Equatable {
    case portable
    case desktop
}

enum SystemPowerSource: Equatable {
    case battery
    case ac
    case ups
    case unknown
}

enum BatteryState: Equatable {
    case charging
    case discharging
    case charged
    case pluggedNotCharging
    case finishingCharge
    case unknown
}

enum ChargeConnectionType: Equatable {
    case magSafe
    case usbC
    case externalPower
    case unplugged
    case unknown
}

enum BatteryCondition: Equatable {
    case good
    case fair
    case poor
    case checkBattery
    case permanentFailure
}

enum PowerTimeEstimate: Equatable {
    case minutes(Int)
    case calculating
    case unavailable
}

struct PowerSnapshot: Equatable {
    let deviceKind: PowerDeviceKind
    let powerSource: SystemPowerSource
    let batteryState: BatteryState
    let batteryPercentage: Int?
    let timeToEmpty: PowerTimeEstimate
    let timeToFullCharge: PowerTimeEstimate
    let voltageMillivolts: Int?
    /// Magnitude only. `batteryState` supplies the direction, so a vendor's
    /// current-sign convention never leaks into UI code.
    let batteryCurrentMilliamps: Int?
    let batteryPowerWatts: Double?
    let adapterRatedPowerWatts: Double?
    let temperatureCelsius: Double?
    let cycleCount: Int?
    let currentCapacity: Int?
    let maxCapacity: Int?
    let designCapacity: Int?
    let capacityHealthPercent: Double?
    let systemBatteryCondition: BatteryCondition?
    let connectionType: ChargeConnectionType

    static let unavailableDesktop = PowerSnapshot(
        deviceKind: .desktop,
        powerSource: .unknown,
        batteryState: .unknown,
        batteryPercentage: nil,
        timeToEmpty: .unavailable,
        timeToFullCharge: .unavailable,
        voltageMillivolts: nil,
        batteryCurrentMilliamps: nil,
        batteryPowerWatts: nil,
        adapterRatedPowerWatts: nil,
        temperatureCelsius: nil,
        cycleCount: nil,
        currentCapacity: nil,
        maxCapacity: nil,
        designCapacity: nil,
        capacityHealthPercent: nil,
        systemBatteryCondition: nil,
        connectionType: .unknown
    )
}

/// The IOPowerSources and narrowly scoped registry inputs before validation.
/// Keeping this separate makes all unit conversions and hardware sanity checks
/// testable without a battery-equipped CI runner.
struct PowerSourceReading: Equatable {
    var providingPowerSource: SystemPowerSource
    var hasInternalBattery: Bool
    var batteryPowerSourceState: SystemPowerSource
    var currentCapacity: Int?
    var maxCapacity: Int?
    var designCapacity: Int?
    var isCharging: Bool?
    var isCharged: Bool?
    var isFinishingCharge: Bool?
    var timeToEmptyMinutes: Int?
    var timeToFullChargeMinutes: Int?
    var voltageMillivolts: Int?
    var currentMilliamps: Int?
    var temperatureCelsius: Double?
    var systemBatteryCondition: BatteryCondition?
    var cycleCount: Int?
    var adapterRatedPowerWatts: Double?
    var connectionType: ChargeConnectionType

    static let unavailableDesktop = PowerSourceReading(
        providingPowerSource: .unknown,
        hasInternalBattery: false,
        batteryPowerSourceState: .unknown,
        currentCapacity: nil,
        maxCapacity: nil,
        designCapacity: nil,
        isCharging: nil,
        isCharged: nil,
        isFinishingCharge: nil,
        timeToEmptyMinutes: nil,
        timeToFullChargeMinutes: nil,
        voltageMillivolts: nil,
        currentMilliamps: nil,
        temperatureCelsius: nil,
        systemBatteryCondition: nil,
        cycleCount: nil,
        adapterRatedPowerWatts: nil,
        connectionType: .unknown
    )
}

enum PowerNormalizer {
    private static let maximumReasonableCurrentMilliamps = 50_000
    private static let minimumReasonableVoltageMillivolts = 3_000
    private static let maximumReasonableVoltageMillivolts = 25_000
    private static let maximumReasonableCycleCount = 10_000
    private static let minimumReasonableTemperatureCelsius = -20.0
    private static let maximumReasonableTemperatureCelsius = 100.0

    static func snapshot(from reading: PowerSourceReading) -> PowerSnapshot {
        guard reading.hasInternalBattery else {
            return PowerSnapshot(
                deviceKind: .desktop,
                powerSource: reading.providingPowerSource,
                batteryState: .unknown,
                batteryPercentage: nil,
                timeToEmpty: .unavailable,
                timeToFullCharge: .unavailable,
                voltageMillivolts: nil,
                batteryCurrentMilliamps: nil,
                batteryPowerWatts: nil,
                adapterRatedPowerWatts: validatedAdapterPower(reading.adapterRatedPowerWatts),
                temperatureCelsius: nil,
                cycleCount: nil,
                currentCapacity: nil,
                maxCapacity: nil,
                designCapacity: nil,
                capacityHealthPercent: nil,
                systemBatteryCondition: nil,
                connectionType: .unknown
            )
        }

        let state = batteryState(from: reading)
        let voltage = validatedVoltage(reading.voltageMillivolts)
        let current = validatedCurrent(reading.currentMilliamps)
        let normalizedCurrent = current.map(abs)

        return PowerSnapshot(
            deviceKind: .portable,
            powerSource: reading.providingPowerSource,
            batteryState: state,
            batteryPercentage: batteryPercentage(
                currentCapacity: reading.currentCapacity,
                maxCapacity: reading.maxCapacity
            ),
            timeToEmpty: timeEstimate(reading.timeToEmptyMinutes),
            timeToFullCharge: timeEstimate(reading.timeToFullChargeMinutes),
            voltageMillivolts: voltage,
            batteryCurrentMilliamps: normalizedCurrent,
            batteryPowerWatts: batteryPowerWatts(
                currentMilliamps: current,
                voltageMillivolts: voltage,
                state: state
            ),
            adapterRatedPowerWatts: validatedAdapterPower(reading.adapterRatedPowerWatts),
            temperatureCelsius: validatedTemperature(reading.temperatureCelsius),
            cycleCount: validatedCycleCount(reading.cycleCount),
            currentCapacity: validatedCapacity(reading.currentCapacity),
            maxCapacity: validatedCapacity(reading.maxCapacity),
            designCapacity: validatedCapacity(reading.designCapacity),
            capacityHealthPercent: capacityHealthPercent(
                fullChargeCapacity: reading.maxCapacity,
                designCapacity: reading.designCapacity
            ),
            systemBatteryCondition: reading.systemBatteryCondition,
            connectionType: reading.connectionType
        )
    }

    static func batteryPercentage(currentCapacity: Int?, maxCapacity: Int?) -> Int? {
        guard let current = validatedCapacity(currentCapacity),
              let maximum = validatedCapacity(maxCapacity),
              maximum > 0,
              current <= maximum else { return nil }
        return Int((Double(current) / Double(maximum) * 100).rounded())
    }

    static func capacityHealthPercent(fullChargeCapacity: Int?, designCapacity: Int?) -> Double? {
        guard let fullCharge = validatedCapacity(fullChargeCapacity),
              let design = validatedCapacity(designCapacity),
              fullCharge > 0,
              design > 0 else { return nil }
        let health = Double(fullCharge) / Double(design) * 100
        // A fresh battery may legitimately exceed its nominal design capacity.
        // The upper bound rejects corrupted registry data, not real >100% packs.
        guard health.isFinite, health > 0, health <= 200 else { return nil }
        return health
    }

    static func timeEstimate(_ minutes: Int?) -> PowerTimeEstimate {
        guard let minutes else { return .unavailable }
        if minutes == -1 { return .calculating }
        guard minutes >= 0 else { return .unavailable }
        return .minutes(minutes)
    }

    static func batteryPowerWatts(
        currentMilliamps: Int?,
        voltageMillivolts: Int?,
        state: BatteryState
    ) -> Double? {
        guard state != .unknown,
              let current = validatedCurrent(currentMilliamps),
              let voltage = validatedVoltage(voltageMillivolts) else { return nil }
        let watts = Double(abs(current)) * Double(voltage) / 1_000_000
        guard watts.isFinite, watts >= 0, watts <= 1_000 else { return nil }
        return watts
    }

    static func batteryState(from reading: PowerSourceReading) -> BatteryState {
        if reading.isCharged == true { return .charged }
        if reading.isFinishingCharge == true { return .finishingCharge }
        if reading.isCharging == true { return .charging }
        if reading.batteryPowerSourceState == .ac || reading.providingPowerSource == .ac {
            return .pluggedNotCharging
        }
        if reading.batteryPowerSourceState == .battery || reading.providingPowerSource == .battery {
            return .discharging
        }
        return .unknown
    }

    private static func validatedCapacity(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    private static func validatedVoltage(_ value: Int?) -> Int? {
        guard let value,
              (minimumReasonableVoltageMillivolts...maximumReasonableVoltageMillivolts).contains(value) else {
            return nil
        }
        return value
    }

    private static func validatedCurrent(_ value: Int?) -> Int? {
        guard let value,
              value != Int.min,
              abs(value) <= maximumReasonableCurrentMilliamps else { return nil }
        return value
    }

    private static func validatedTemperature(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        if (minimumReasonableTemperatureCelsius...maximumReasonableTemperatureCelsius).contains(value) {
            return value
        }
        // Some IOPowerSources implementations forward the Smart Battery value
        // in tenths of Kelvin. It is the same physical sensor, so normalize it
        // only when the converted reading is plainly a plausible battery range.
        let celsius = value / 10 - 273.15
        guard (minimumReasonableTemperatureCelsius...maximumReasonableTemperatureCelsius).contains(celsius) else {
            return nil
        }
        return celsius
    }

    private static func validatedCycleCount(_ value: Int?) -> Int? {
        guard let value, (0...maximumReasonableCycleCount).contains(value) else { return nil }
        return value
    }

    private static func validatedAdapterPower(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value <= 1_000 else { return nil }
        return value
    }
}

enum PowerTimeFormatter {
    static func string(for estimate: PowerTimeEstimate) -> String {
        switch estimate {
        case .minutes(let minutes):
            let hours = minutes / 60
            let remainder = minutes % 60
            if hours == 0 { return localized("%d min", remainder) }
            if remainder == 0 { return localized("%d h", hours) }
            return localized("%d h %d min", hours, remainder)
        case .calculating:
            return localized("Calculating…")
        case .unavailable:
            return "—"
        }
    }
}
