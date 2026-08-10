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

        let providing = providingPowerSource(from: IOPSGetProvidingPowerSourceType(info) as String?)
        let adapterPower = externalAdapterWatts()

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any],
                isPresentInternalBattery(description) else { continue }

            return PowerSourceReading(
                providingPowerSource: providing,
                hasInternalBattery: true,
                batteryPowerSourceState: batteryPowerSourceState(
                    from: description[kIOPSPowerSourceStateKey] as? String
                ),
                currentCapacity: integer(description[kIOPSCurrentCapacityKey]),
                maxCapacity: integer(description[kIOPSMaxCapacityKey]),
                designCapacity: integer(description[kIOPSDesignCapacityKey]),
                isCharging: boolean(description[kIOPSIsChargingKey]),
                isCharged: boolean(description[kIOPSIsChargedKey]),
                isFinishingCharge: boolean(description[kIOPSIsFinishingChargeKey]),
                timeToEmptyMinutes: integer(description[kIOPSTimeToEmptyKey]),
                timeToFullChargeMinutes: integer(description[kIOPSTimeToFullChargeKey]),
                voltageMillivolts: integer(description[kIOPSVoltageKey]),
                currentMilliamps: integer(description[kIOPSCurrentKey]),
                temperatureCelsius: number(description[kIOPSTemperatureKey]),
                systemBatteryCondition: batteryCondition(description),
                cycleCount: IOBatteryRegistrySupplement.cycleCount(),
                adapterRatedPowerWatts: adapterPower,
                connectionType: ChargeConnectionDetector.currentConnection()
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
            connectionType: .unknown
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

    private func externalAdapterWatts() -> Double? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return number(details[kIOPSPowerAdapterWattsKey])
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

    private func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private func boolean(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }
}

/// `IOPSCopyExternalPowerAdapterDetails` describes an adapter, not the port
/// used by the Mac. Current public IOKit headers expose no stable property that
/// proves an active MagSafe or USB-C charging path, so the production provider
/// intentionally reports `unknown` instead of guessing from model or wattage.
enum ChargeConnectionDetector {
    static func currentConnection() -> ChargeConnectionType { .unknown }
}
