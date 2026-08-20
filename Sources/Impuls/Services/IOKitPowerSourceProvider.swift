import Foundation
import IOKit.ps

@MainActor
protocol PowerSourceProviding: AnyObject {
    func snapshot() -> PowerSnapshot
}

@MainActor
protocol PowerSourceObserving: PowerSourceProviding {
    func startObserving(_ onChange: @escaping () -> Void)
    func stopObserving()
}

/// Reads the public IOPowerSources surface and keeps the C/CF ownership rules
/// outside the monitor and the SwiftUI pane.
@MainActor
final class IOKitPowerSourceProvider: PowerSourceObserving {
    private var notificationSource: CFRunLoopSource?
    private var onChange: (() -> Void)?

    func snapshot() -> PowerSnapshot {
        PowerNormalizer.snapshot(from: reading())
    }

    func startObserving(_ onChange: @escaping () -> Void) {
        guard notificationSource == nil else { return }
        self.onChange = onChange
        guard let source = IOPSNotificationCreateRunLoopSource(
            Self.powerSourceChanged,
            Unmanaged.passUnretained(self).toOpaque()
        )?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        notificationSource = source
    }

    func stopObserving() {
        guard let notificationSource else {
            onChange = nil
            return
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), notificationSource, .commonModes)
        self.notificationSource = nil
        onChange = nil
    }

    private func reading() -> PowerSourceReading {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return .unavailableDesktop
        }

        let providing = providingPowerSource(
            from: IOPSGetProvidingPowerSourceType(info)
                .map { $0.takeUnretainedValue() as String }
        )
        let adapterDetails = externalAdapterDetails()
        let adapterPower = number(adapterDetails?[kIOPSPowerAdapterWattsKey])
        let registry = IOBatteryRegistrySupplement.reading()

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any],
                isPresentInternalBattery(description) else { continue }

            let usesRegistryCapacityPair = registry.maxCapacity != nil && registry.designCapacity != nil

            return PowerSourceReading(
                providingPowerSource: providing,
                hasInternalBattery: true,
                batteryPowerSourceState: batteryPowerSourceState(
                    from: description[kIOPSPowerSourceStateKey] as? String
                ),
                currentCapacity: usesRegistryCapacityPair
                    ? registry.currentCapacity ?? integer(description[kIOPSCurrentCapacityKey])
                    : integer(description[kIOPSCurrentCapacityKey]) ?? registry.currentCapacity,
                maxCapacity: usesRegistryCapacityPair
                    ? registry.maxCapacity
                    : integer(description[kIOPSMaxCapacityKey]) ?? registry.maxCapacity,
                designCapacity: usesRegistryCapacityPair
                    ? registry.designCapacity
                    : integer(description[kIOPSDesignCapacityKey]) ?? registry.designCapacity,
                isCharging: boolean(description[kIOPSIsChargingKey]),
                isCharged: boolean(description[kIOPSIsChargedKey]),
                isFinishingCharge: boolean(description[kIOPSIsFinishingChargeKey]),
                timeToEmptyMinutes: integer(description[kIOPSTimeToEmptyKey]),
                timeToFullChargeMinutes: integer(description[kIOPSTimeToFullChargeKey]),
                voltageMillivolts: integer(description[kIOPSVoltageKey]) ?? registry.voltageMillivolts,
                currentMilliamps: integer(description[kIOPSCurrentKey]) ?? registry.currentMilliamps,
                temperatureCelsius: number(description[kIOPSTemperatureKey]) ?? registry.temperatureCelsius,
                systemBatteryCondition: batteryCondition(description),
                cycleCount: registry.cycleCount,
                adapterRatedPowerWatts: adapterPower,
                connectionType: ChargeConnectionDetector.currentConnection(
                    providingPowerSource: providing,
                    adapterDetails: adapterDetails
                )
            )
        }

        return PowerSourceReading(
            providingPowerSource: providing,
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
            adapterRatedPowerWatts: adapterPower,
            connectionType: ChargeConnectionDetector.currentConnection(
                providingPowerSource: providing,
                adapterDetails: adapterDetails
            )
        )
    }

    private static let powerSourceChanged: IOPowerSourceCallbackType = { context in
        guard let context else { return }
        let provider = Unmanaged<IOKitPowerSourceProvider>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in
            provider.onChange?()
        }
    }

    private func isPresentInternalBattery(_ description: [String: Any]) -> Bool {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { return false }
        return boolean(description[kIOPSIsPresentKey]) != false
    }

    private func externalAdapterDetails() -> [String: Any]? {
        IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
    }

    private func batteryCondition(_ description: [String: Any]) -> BatteryCondition? {
        if let condition = description[kIOPSBatteryHealthConditionKey] as? String {
            switch condition {
            case kIOPSCheckBatteryValue: return .checkBattery
            case kIOPSPermanentFailureValue: return .permanentFailure
            default: break
            }
        }
        guard let health = description[kIOPSBatteryHealthKey] as? String else { return nil }
        switch health {
        case kIOPSGoodValue: return .good
        case kIOPSFairValue: return .fair
        case kIOPSPoorValue: return .poor
        default: return nil
        }
    }

    private func providingPowerSource(from value: String?) -> SystemPowerSource {
        switch value {
        case kIOPMBatteryPowerKey: return .battery
        case kIOPMACPowerKey: return .ac
        case kIOPMUPSPowerKey: return .ups
        default: return .unknown
        }
    }

    private func batteryPowerSourceState(from value: String?) -> SystemPowerSource {
        switch value {
        case kIOPSBatteryPowerValue: return .battery
        case kIOPSACPowerValue: return .ac
        default: return .unknown
        }
    }

    /// Shares the registry coercion rather than `intValue`: the power-source
    /// dictionary is another system-owned bag of `CFNumber`s, and `intValue`
    /// would read a `CFBoolean` flag as `1` and saturate a value too large for
    /// `Int` instead of reporting it as absent. The keys read here
    /// (`CurrentCapacity`, `MaxCapacity`, `DesignCapacity`, `Voltage`,
    /// `Current`) are integral, so rounding cannot move a real reading.
    private func integer(_ value: Any?) -> Int? {
        RegistryNumber.integer(value)
    }

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private func boolean(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }
}

/// `IOPSCopyExternalPowerAdapterDetails` proves that an AC adapter is attached,
/// but current public IOKit headers do not expose a stable property for the
/// physical path. A 35 W adapter can be connected through MagSafe or USB-C, so
/// reporting either one from wattage or a model name would be a false claim.
enum ChargeConnectionDetector {
    static func currentConnection(
        providingPowerSource: SystemPowerSource,
        adapterDetails: [String: Any]?
    ) -> ChargeConnectionType {
        if providingPowerSource == .ac || adapterDetails != nil { return .externalPower }
        if providingPowerSource == .battery { return .unplugged }
        return .unknown
    }
}
