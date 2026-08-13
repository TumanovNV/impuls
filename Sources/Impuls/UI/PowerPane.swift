import SwiftUI

struct PowerPane: View {
    @ObservedObject var power: PowerMonitor
    @ObservedObject var devices: DevicePowerCenter
    @ObservedObject var settings: SettingsStore
    @State private var selectedDeviceKey = AppleDeviceIdentity.localMac.localPreferenceKey
    @FocusState private var focusedDeviceKey: String?

    var body: some View {
        if settings.showsExternalAppleDevices {
            multiDeviceCenter
        } else {
            localPower
        }
    }

    @ViewBuilder
    private var localPower: some View {
        switch power.snapshot.deviceKind {
        case .portable:
            battery
        case .desktop:
            desktop
        }
    }

    private var externalDevices: [AppleDeviceSnapshot] {
        settings.visibleExternalAppleDevices(from: devices.visibleDevices)
    }

    private var effectiveSelectedDeviceKey: String {
        externalDevices.contains { $0.identity.localPreferenceKey == selectedDeviceKey }
            ? selectedDeviceKey
            : AppleDeviceIdentity.localMac.localPreferenceKey
    }

    private var selectedExternalDevice: AppleDeviceSnapshot? {
        externalDevices.first { $0.identity.localPreferenceKey == effectiveSelectedDeviceKey }
    }

    private var multiDeviceCenter: some View {
        VStack(spacing: Theme.Space.xs) {
            deviceSwitcher
            Group {
                if let selectedExternalDevice {
                    externalDeviceCard(selectedExternalDevice)
                } else {
                    localPower
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var deviceSwitcher: some View {
        HStack(spacing: Theme.Space.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.xs) {
                    deviceChoice(
                        key: AppleDeviceIdentity.localMac.localPreferenceKey,
                        name: localized("This Mac"),
                        symbol: power.snapshot.deviceKind == .portable ? "laptopcomputer" : "desktopcomputer",
                        value: power.snapshot.deviceKind == .portable ? batteryPercentage : desktopStateTitle,
                        accessibilityValue: power.snapshot.deviceKind == .portable
                            ? "\(batteryPercentage), \(stateTitle)"
                            : desktopStateTitle
                    )

                    ForEach(externalDevices, id: \.identity) { device in
                        deviceChoice(
                            key: device.identity.localPreferenceKey,
                            name: device.displayName,
                            symbol: AppleDevicePresentation.symbol(for: device.kind),
                            value: device.headlinePercentage.map { "\($0)%" },
                            accessibilityValue: AppleDevicePresentation.accessibilityValue(for: device)
                        )
                    }

                    if let externalStatusMessage {
                        Label(externalStatusMessage, systemImage: externalStatusSymbol)
                            .font(Theme.Typo.caption)
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                            .help(externalStatusMessage)
                    }
                }
            }

            Button {
                devices.refreshExternalDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(NotchButtonStyle(size: Theme.Size.touchTarget))
            .help(localized("Refresh Devices"))
            .accessibilityLabel(localized("Refresh Devices"))
        }
        .frame(height: Theme.Size.row)
    }

    private func deviceChoice(
        key: String,
        name: String,
        symbol: String,
        value: String?,
        accessibilityValue: String
    ) -> some View {
        let selected = effectiveSelectedDeviceKey == key
        return Button {
            selectedDeviceKey = key
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: symbol)
                    .font(Theme.Glyph.medium)
                Text(name)
                    .font(Theme.Typo.captionStrong)
                    .lineLimit(1)
                if let value {
                    Text(value)
                        .font(Theme.Typo.captionDigits)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(Theme.primary)
            .padding(.horizontal, Theme.Space.s)
            .frame(height: Theme.Size.touchTarget)
            .background(selected ? Theme.selection : Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(selected ? Theme.selectionStroke : Theme.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            )
        }
        .buttonStyle(.plain)
        .focused($focusedDeviceKey, equals: key)
        .notchFocusRing(focusedDeviceKey == key)
        .accessibilityLabel(name)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var externalStatusMessage: String? {
        let diagnostics = devices.diagnostics.filter { diagnostic in
            switch diagnostic.provider {
            case .localMac: return false
            case .mobileDevice: return true
            case .appleAccessory: return true
            }
        }
        if diagnostics.contains(where: { $0.status == .permissionRequired }) {
            return localized("Unlock your iPhone or iPad and tap Trust This Computer.")
        }
        if diagnostics.contains(where: { $0.status == .temporarilyFailed }) {
            return localized("Some device readings are stale.")
        }
        if externalDevices.isEmpty {
            if diagnostics.contains(where: { $0.status == .starting }) {
                return localized("Looking for connected Apple devices…")
            }
            return localized("No connected Apple devices found.")
        }
        return nil
    }

    private var externalStatusSymbol: String {
        if devices.diagnostics.contains(where: { $0.status == .permissionRequired }) {
            return "lock.open"
        }
        if devices.diagnostics.contains(where: { $0.status == .temporarilyFailed }) {
            return "exclamationmark.triangle"
        }
        return externalDevices.isEmpty ? "minus.circle" : "checkmark.circle"
    }

    private func externalDeviceCard(_ device: AppleDeviceSnapshot) -> some View {
        HStack(spacing: Theme.Space.m) {
            VStack(spacing: Theme.Space.xs) {
                Image(systemName: AppleDevicePresentation.symbol(for: device.kind))
                    .font(Theme.Glyph.hero)
                    .foregroundStyle(Theme.primary.opacity(0.86))
                Text(AppleDevicePresentation.connectionTitle(device.connection))
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
            .frame(width: 64)

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.xs) {
                    Text(device.displayName)
                        .font(Theme.Typo.title)
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if AppleDevicePresentation.isBeta(device.kind) {
                        Text(localized("Beta"))
                            .font(Theme.Typo.captionSemibold)
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, Theme.Space.xs)
                            .padding(.vertical, 1)
                            .background(Theme.surfaceHover, in: Capsule())
                    }
                }
                if let modelTitle = AppleDevicePresentation.modelTitle(for: device) {
                    Text(modelTitle)
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
                Text(
                    AppleDevicePresentation.ageTitle(
                        since: device.lastUpdated,
                        freshness: AppleDevicePresentation.freshness(for: device),
                        source: device.source,
                        abbreviated: true
                    )
                )
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            }
            .frame(minWidth: 92, maxWidth: 154, alignment: .leading)

            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
                .padding(.vertical, Theme.Space.s)

            HStack(spacing: Theme.Space.m) {
                ForEach(device.components, id: \.kind) { component in
                    componentColumn(component, device: device)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(device.displayName)
        .accessibilityValue(AppleDevicePresentation.accessibilityValue(for: device))
    }

    private func componentColumn(
        _ component: DeviceBatteryComponent,
        device: AppleDeviceSnapshot
    ) -> some View {
        let freshness = AppleDevicePresentation.freshness(
            for: component,
            availability: device.availability,
            fallbackDate: device.lastUpdated
        )
        let age = AppleDevicePresentation.ageTitle(
            since: component.lastUpdated ?? device.lastUpdated,
            freshness: freshness,
            source: device.source,
            abbreviated: true
        )
        return VStack(spacing: Theme.Space.hair) {
            Text(AppleDevicePresentation.readingTitle(component))
                .font(device.components.count == 1 ? Theme.Typo.hero : Theme.Typo.bodyDigits)
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(AppleDevicePresentation.componentTitle(component.kind))
                .font(Theme.Typo.captionStrong)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            if let charging = AppleDevicePresentation.chargingTitle(component.chargingState) {
                Text(charging)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
            Text(age)
                .font(Theme.Typo.caption)
                .foregroundStyle(freshness == .stale ? Theme.secondary : Theme.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(minWidth: 54, maxWidth: .infinity)
    }

    /// What the three metric columns and their furniture need to the right of
    /// the hero: the grid itself, the two gaps around the divider and the
    /// divider. The hero gets whatever is left over.
    private static let metricsReservation: CGFloat = 340

    private var battery: some View {
        GeometryReader { geo in
            HStack(spacing: Theme.Space.xl - 2) {
                hero
                    .frame(width: heroWidth(in: geo.size.width))

                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1)
                    .padding(.vertical, 8)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 84), spacing: Theme.Space.l),
                        GridItem(.flexible(minimum: 84), spacing: Theme.Space.l),
                        GridItem(.flexible(minimum: 84), spacing: Theme.Space.l),
                    ],
                    alignment: .leading,
                    spacing: Theme.Space.m + 1
                ) {
                    ForEach(batteryMetrics) { item in
                        metric(item.value, title: item.title)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.horizontal, 4)
    }

    /// The hero column is squeezed before the metrics are.
    ///
    /// It was a flat 136 pt, which is 31% of the compact pane. The grid beside
    /// it was asking three columns of at least 92 pt plus 32 pt of gaps, and
    /// compact could not pay: 308 pt wanted against 263 available, so the third
    /// column of metrics fell outside the panel and was clipped. Taking the
    /// difference out of the hero, which has the slack, keeps three columns at
    /// every preset.
    ///
    /// The floor is 112 pt and not lower because of the hero's own text, which
    /// is wider than its number. The percentage is only 80 pt at "100 %", but
    /// `stateTitle` reaches 120 pt on "Завершение зарядки" and `timeTitle`
    /// reaches 127 pt on "Состояние аккумулятора" — both ordinary Russian
    /// states, both measured at the sizes they actually render at. With the
    /// 0.85 floor those two land at 102 and 108 pt, so 112 clears the worst of
    /// them with a little room and still leaves the compact grid an 85 pt
    /// column, above the 84 pt minimum below.
    private func heroWidth(in paneWidth: CGFloat) -> CGFloat {
        min(136, max(112, paneWidth - Self.metricsReservation))
    }

    private var hero: some View {
        VStack(spacing: Theme.Space.xs - 1) {
            Image(systemName: batterySymbol)
                .font(Theme.Glyph.largeStrong)
                .foregroundStyle(Theme.primary.opacity(0.86))
                .padding(.bottom, 1)
            Text(batteryPercentage)
                .font(Theme.Typo.hero)
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
            // The two text lines scale on the same 0.85 floor as the metric
            // titles. They are the widest thing in this column — wider than the
            // percentage — and the column is no longer a fixed 136 pt, so
            // "Завершение зарядки" and "Состояние аккумулятора" need somewhere
            // to give at the compact preset.
            Text(stateTitle)
                .font(Theme.Typo.labelSemibold)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(timeValue)
                .font(Theme.Typo.captionDigits)
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
            Text(timeTitle)
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.tertiary.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized("Battery"))
        .accessibilityValue("\(batteryPercentage), \(stateTitle), \(timeTitle) \(timeValue)")
    }

    /// What the three desktop metrics and their furniture need to the right of
    /// the hero. The metrics here are content-sized rather than gridded, so the
    /// number is measured from the widest they get: 268 pt for three columns
    /// with two 36 pt gaps — "Подключено" is the long one — plus the divider
    /// and the two 20 pt gaps around it, rounded up for margin.
    private static let desktopMetricsReservation: CGFloat = 316

    private var desktop: some View {
        GeometryReader { geo in
            HStack(spacing: Theme.Space.l + 4) {
                VStack(spacing: Theme.Space.xs + 1) {
                    Image(systemName: "bolt.fill")
                        .font(Theme.Glyph.heroStrong)
                        .foregroundStyle(Theme.primary.opacity(0.86))
                    Text(localized("Power"))
                        .font(Theme.Typo.display)
                        .foregroundStyle(Theme.primary)
                    Text(desktopStateTitle)
                        .font(Theme.Typo.labelStrong)
                        .foregroundStyle(Theme.secondary)
                }
                .frame(width: desktopHeroWidth(in: geo.size.width))

                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1)
                    .padding(.vertical, 12)

                HStack(spacing: Theme.Space.xl + 12) {
                    metric(powerSourceValue, title: localized("Source"))
                    metric(desktopConnectionValue, title: localized("State"))
                    metric(adapterValue, title: localized("Power Adapter"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.horizontal, 4)
    }

    /// Same trade as `heroWidth`, and the same reason: a flat 160 pt here left
    /// the compact preset 243 pt for metrics that need 268, so the Power
    /// Adapter column ran off the edge. This hero has more slack than the
    /// battery one — its widest line is "Питание" at 86 pt — so the floor of
    /// 104 pt is a guard rather than a working value; compact settles at 128.
    private func desktopHeroWidth(in paneWidth: CGFloat) -> CGFloat {
        min(160, max(104, paneWidth - Self.desktopMetricsReservation))
    }

    private func metric(_ value: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs - 1) {
            Text(value)
                .font(Theme.Typo.bodyDigits)
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            // Scales like the value above it. The titles moved from 8.5 pt to
            // the 10 pt of the type scale, and at the compact preset the grid
            // column comes out near 75 pt — which is what "Макс. ёмкость" needs
            // at 10 pt exactly. The floor is 0.85 rather than the value's 0.72
            // so a squeezed title lands on 8.5 pt, the size these labels had
            // before the scale existed, instead of somewhere below it.
            Text(title)
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(minWidth: 0, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private var snapshot: PowerSnapshot { power.snapshot }

    private var batteryMetrics: [MetricItem] {
        var items = [
            MetricItem(value: powerValue, title: powerTitle),
            MetricItem(value: connectionValue, title: localized("Connection")),
        ]
        if snapshot.adapterRatedPowerWatts != nil {
            items.append(MetricItem(value: adapterValue, title: localized("Power Adapter")))
        }
        if snapshot.temperatureCelsius != nil {
            items.append(MetricItem(value: temperatureValue, title: localized("Temperature")))
        }
        if snapshot.capacityHealthPercent != nil {
            items.append(MetricItem(value: capacityHealthValue, title: localized("Maximum Capacity")))
        }
        if snapshot.cycleCount != nil {
            items.append(MetricItem(value: cycleCountValue, title: localized("Cycle Count")))
        }
        if snapshot.systemBatteryCondition != nil {
            items.append(MetricItem(value: conditionValue, title: localized("Battery Condition")))
        }
        return items
    }

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
            return connectionValue
        case .pluggedNotCharging:
            return connectionValue
        case .unknown:
            return "—"
        }
    }

    private var timeTitle: String {
        switch snapshot.batteryState {
        case .charging, .finishingCharge: return localized("Until Full")
        case .discharging: return localized("Time Remaining")
        case .charged, .pluggedNotCharging: return localized("Connection")
        case .unknown: return localized("Battery State")
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
        case .unplugged: return localized("Not Connected")
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

private struct MetricItem: Identifiable {
    let value: String
    let title: String

    var id: String { title }
}
