import SwiftUI

struct PowerPane: View {
    @ObservedObject var power: PowerMonitor

    var body: some View {
        switch power.snapshot.deviceKind {
        case .portable:
            battery
        case .desktop:
            desktop
        }
    }

    private var battery: some View {
        HStack(spacing: 22) {
            hero
                .frame(width: 136)

            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
                .padding(.vertical, 8)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 92), spacing: 16),
                    GridItem(.flexible(minimum: 92), spacing: 16),
                    GridItem(.flexible(minimum: 92), spacing: 16),
                ],
                alignment: .leading,
                spacing: 13
            ) {
                metric(powerValue, title: powerTitle)
                metric(connectionValue, title: localized("Connection"))
                metric(adapterValue, title: localized("Power Adapter"))
                metric(temperatureValue, title: localized("Temperature"))
                metric(capacityHealthValue, title: localized("Maximum Capacity"))
                metric(cycleCountValue, title: localized("Cycle Count"))
                metric(conditionValue, title: localized("Battery Condition"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hero: some View {
        VStack(spacing: 3) {
            Image(systemName: batterySymbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.primary.opacity(0.86))
                .padding(.bottom, 1)
            Text(batteryPercentage)
                .font(.system(size: 30, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
            Text(stateTitle)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            Text(timeValue)
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
            Text(timeTitle)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(Theme.tertiary.opacity(0.82))
                .lineLimit(1)
        }
        .multilineTextAlignment(.center)
    }

    private var desktop: some View {
        HStack(spacing: 20) {
            VStack(spacing: 5) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.primary.opacity(0.86))
                Text(localized("Power"))
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Text(desktopStateTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
            .frame(width: 160)

            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
                .padding(.vertical, 12)

            HStack(spacing: 36) {
                metric(powerSourceValue, title: localized("Source"))
                metric(desktopConnectionValue, title: localized("State"))
                metric(adapterValue, title: localized("Power Adapter"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func metric(_ value: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(title)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
        }
        .frame(minWidth: 0, alignment: .leading)
    }

    private var snapshot: PowerSnapshot { power.snapshot }

    private var batterySymbol: String {
        switch snapshot.batteryState {
        case .charging, .finishingCharge: return "battery.100percent.bolt"
        case .discharging: return "battery.50percent"
        case .charged: return "battery.100percent"
        case .pluggedNotCharging: return "battery.100percent"
        case .unknown: return "battery.0percent"
        }
    }

    private var batteryPercentage: String {
        snapshot.batteryPercentage.map { "\($0)%" } ?? "—"
    }

    private var stateTitle: String {
        switch snapshot.batteryState {
        case .charging: return localized("Charging")
        case .discharging: return localized("On Battery")
        case .charged: return localized("Charged")
        case .pluggedNotCharging: return localized("Not Charging")
        case .finishingCharge: return localized("Finishing Charge")
        case .unknown: return localized("Unavailable")
        }
    }

    private var timeValue: String {
        switch snapshot.batteryState {
        case .charging, .finishingCharge:
            return PowerTimeFormatter.string(for: snapshot.timeToFullCharge)
        case .discharging:
            return PowerTimeFormatter.string(for: snapshot.timeToEmpty)
        case .charged:
            return localized("Charged")
        case .pluggedNotCharging:
            return localized("Not Charging")
        case .unknown:
            return "—"
        }
    }

    private var timeTitle: String {
        switch snapshot.batteryState {
        case .charging, .finishingCharge: return localized("Until Full")
        case .discharging: return localized("Time Remaining")
        case .charged, .pluggedNotCharging, .unknown: return localized("Battery State")
        }
    }

    private var powerValue: String {
        formattedWatts(snapshot.batteryPowerWatts)
    }

    private var powerTitle: String {
        switch snapshot.batteryState {
        case .charging, .finishingCharge: return localized("Into Battery")
        case .discharging: return localized("Power Usage")
        case .charged, .pluggedNotCharging, .unknown: return localized("Power")
        }
    }

    private var connectionValue: String {
        switch snapshot.connectionType {
        case .magSafe: return localized("MagSafe")
        case .usbC: return localized("USB-C")
        case .externalPower: return localized("External Power")
        case .unknown: return localized("Unknown")
        }
    }

    private var adapterValue: String { formattedWatts(snapshot.adapterRatedPowerWatts) }

    private var temperatureValue: String {
        guard let temperature = snapshot.temperatureCelsius else { return "—" }
        let rounded = temperature.rounded()
        if abs(temperature - rounded) < 0.05 {
            return String(format: localized("%.0f °C"), rounded)
        }
        return String(format: localized("%.1f °C"), temperature)
    }

    private var capacityHealthValue: String {
        guard let health = snapshot.capacityHealthPercent else { return "—" }
        return "\(Int(health.rounded()))%"
    }

    private var cycleCountValue: String {
        snapshot.cycleCount.map(String.init) ?? "—"
    }

    private var conditionValue: String {
        guard let condition = snapshot.systemBatteryCondition else { return "—" }
        switch condition {
        case .good: return localized("Good")
        case .fair: return localized("Fair")
        case .poor: return localized("Poor")
        case .checkBattery: return localized("Check Battery")
        case .permanentFailure: return localized("Permanent Battery Failure")
        }
    }

    private var powerSourceValue: String {
        switch snapshot.powerSource {
        case .ac: return localized("AC")
        case .battery: return localized("Battery")
        case .ups: return localized("UPS")
        case .unknown: return localized("Unknown")
        }
    }

    private var desktopStateTitle: String {
        snapshot.powerSource == .ac ? localized("Connected") : localized("Unavailable")
    }

    private var desktopConnectionValue: String {
        snapshot.powerSource == .ac ? localized("Connected") : localized("Unavailable")
    }

    private func formattedWatts(_ watts: Double?) -> String {
        guard let watts else { return "—" }
        if abs(watts - watts.rounded()) < 0.05 {
            return String(format: localized("%.0f W"), watts)
        }
        return String(format: localized("%.1f W"), watts)
    }
}
