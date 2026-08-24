import SwiftUI

struct PowerPane: View {
    @ObservedObject var power: PowerMonitor
    @ObservedObject var devices: DevicePowerCenter
    @ObservedObject var settings: SettingsStore
    @State private var selectedDeviceKey = AppleDeviceIdentity.localMac.localPreferenceKey
    @FocusState private var focusedDeviceKey: String?
    @State private var hoveredDeviceKey: String?

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

    /// Master-detail: a tall Device Navigator on the left, the selected
    /// device's own detail card on the right. Replaces the old horizontal
    /// switcher-plus-card stack, which read as a row of chips rather than a
    /// list of the person's devices.
    ///
    /// Refresh sits above the split rather than inside `NotchContentView`'s
    /// shared header: that row leaves a hit-testing gap for menu-bar
    /// utilities and is documented as accepting nothing interactive.
    /// Anchoring the button to the top of Power's own content gives the same
    /// "title row with an action" read without touching it.
    private var multiDeviceCenter: some View {
        VStack(spacing: Theme.Space.xs) {
            HStack {
                Spacer(minLength: 0)
                refreshButton
            }

            GeometryReader { geo in
                if geo.size.width < Self.narrowLayoutThreshold {
                    VStack(spacing: Theme.Space.s) {
                        deviceNavigator
                            .frame(height: min(110, geo.size.height * 0.42))
                        Rectangle()
                            .fill(Theme.hairline)
                            .frame(height: 1)
                        detail
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    HStack(spacing: Theme.Space.m) {
                        deviceNavigator
                            .frame(width: navigatorWidth(in: geo.size.width))

                        Rectangle()
                            .fill(Theme.hairline)
                            .frame(width: 1)
                            .padding(.vertical, Theme.Space.xs)

                        detail
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .padding(.horizontal, Theme.Space.xs)
    }

    /// Below this the two columns stop being able to hold a device name and a
    /// readable detail card at once. No shipping preset reaches it — Compact's
    /// content area is already ~470 pt after the rails — but a future or
    /// unusually narrow display gets a stacked fallback instead of a squeeze.
    private static let narrowLayoutThreshold: CGFloat = 420

    /// The navigator is a fraction of the pane rather than a flat number:
    /// Standard and Large use the fraction directly, and only Compact's floor
    /// ever clamps it. 176…250 pt is what "Magic Keyboard (Николай)" needs to
    /// sit across two lines without shrinking below the type scale's floor.
    private func navigatorWidth(in paneWidth: CGFloat) -> CGFloat {
        min(250, max(176, paneWidth * 0.36))
    }

    private var refreshButton: some View {
        Button {
            devices.refreshExternalDevices()
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(NotchButtonStyle(size: Theme.Size.touchTarget))
        .help(localized("Refresh Devices"))
        .accessibilityLabel(localized("Refresh Devices"))
    }

    private var deviceNavigator: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: Theme.Space.xs) {
                    ForEach(navigatorEntries) { entry in
                        navigatorRow(entry)
                    }
                }
            }

            if let externalStatusMessage {
                Label(externalStatusMessage, systemImage: externalStatusSymbol)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(2)
                    .help(externalStatusMessage)
            }
        }
    }

    /// Fixed so every row's percentage lands in the same column instead of
    /// drifting sideways with its digit count.
    private static let navigatorTrailingWidth: CGFloat = 32

    private func navigatorRow(_ entry: NavigatorEntry) -> some View {
        let selected = effectiveSelectedDeviceKey == entry.key
        return Button {
            selectedDeviceKey = entry.key
        } label: {
            HStack(spacing: Theme.Space.xs) {
                // The selection accent lives here, as a slim bar, rather than
                // in a full-bleed fill: every row already rests on
                // `Theme.surface`, so a heavier fill would only repeat what
                // `Theme.selection` already says about the row underneath it.
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(selected ? Theme.focusRing : Color.clear)
                    .frame(width: 2, height: 15)

                Image(systemName: entry.symbol)
                    .font(Theme.Glyph.medium)
                    .foregroundStyle(Theme.primary.opacity(0.86))
                    .frame(width: 16)

                // Two lines rather than a truncated one: a clipped "Magic
                // Keyboar…" tells a person nothing they didn't already know
                // from the icon. `layoutPriority` keeps the name the last
                // thing to give ground if the row is ever squeezed.
                VStack(alignment: .leading, spacing: Theme.Space.hair) {
                    Text(entry.title)
                        .font(Theme.Typo.labelStrong)
                        .foregroundStyle(Theme.primary)
                        .lineLimit(2)
                        .layoutPriority(1)
                    HStack(spacing: Theme.Space.xs - 2) {
                        if let dotColor = entry.dotColor {
                            Circle()
                                .fill(dotColor)
                                .frame(width: 5, height: 5)
                        }
                        Text(entry.subtitle)
                            .font(Theme.Typo.caption)
                            .foregroundStyle(entry.dotColor ?? Theme.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: Theme.Space.xs)

                if let trailingValue = entry.trailingValue {
                    Text(trailingValue)
                        .font(Theme.Typo.captionDigits)
                        .foregroundStyle(entry.trailingColor ?? Theme.secondary)
                        .lineLimit(1)
                        .frame(width: Self.navigatorTrailingWidth, alignment: .trailing)
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs)
            .frame(minHeight: Theme.Size.rowDetailed)
            .background(selected ? Theme.selection : (hoveredDeviceKey == entry.key ? Theme.surfaceHover : Theme.surface))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(selected ? Theme.selectionStroke : Color.clear, lineWidth: Theme.selectionStrokeWidth)
                    .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedDeviceKey, equals: entry.key)
        .notchFocusRing(focusedDeviceKey == entry.key)
        .onHover { isHovering in
            hoveredDeviceKey = isHovering ? entry.key : (hoveredDeviceKey == entry.key ? nil : hoveredDeviceKey)
        }
        .animation(Theme.motion(Theme.contentAnimation), value: hoveredDeviceKey)
        .accessibilityLabel(entry.title)
        .accessibilityValue(entry.accessibilityValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// One row per device, This Mac first. A plain array rather than two
    /// `ForEach`s: the row view and its accessibility values are identical for
    /// both, and only the data differs.
    private var navigatorEntries: [NavigatorEntry] {
        [localMacEntry] + externalDevices.map(navigatorEntry(for:))
    }

    private var localMacEntry: NavigatorEntry {
        let isPortable = snapshot.deviceKind == .portable
        let severity = localMacSeverity
        return NavigatorEntry(
            key: AppleDeviceIdentity.localMac.localPreferenceKey,
            symbol: localMacSymbol,
            title: localized("This Mac"),
            subtitle: isPortable ? stateTitle : desktopStateTitle,
            dotColor: severityColor(severity) ?? (localMacIsPowered ? Color.green : nil),
            trailingValue: isPortable ? batteryPercentage : nil,
            trailingColor: severityColor(severity),
            accessibilityValue: isPortable
                ? "\(batteryPercentage), \(stateTitle)"
                : desktopStateTitle
        )
    }

    private func navigatorEntry(for device: AppleDeviceSnapshot) -> NavigatorEntry {
        let severity = deviceSeverity(device)
        return NavigatorEntry(
            key: device.identity.localPreferenceKey,
            symbol: navigatorSymbol(for: device.kind),
            title: device.displayName,
            subtitle: navigatorSubtitle(for: device),
            dotColor: severityColor(severity) ?? (device.externalPower == .connected ? Color.green : nil),
            trailingValue: device.headlinePercentage.map { "\($0)%" },
            trailingColor: severityColor(severity),
            accessibilityValue: AppleDevicePresentation.accessibilityValue(for: device)
        )
    }

    /// The shared `AppleDevicePresentation.symbol(for:)` picks the Bluetooth
    /// pairing glyph for a trackpad — a hand mid-gesture, not the device — and
    /// a generic mouse outline for Magic Mouse. The Navigator needs a shape a
    /// glance can tell apart from its neighbours, so those two kinds get a
    /// symbol of their own here instead of widening the shared vocabulary for
    /// one screen's sake.
    private func navigatorSymbol(for kind: AppleDeviceKind) -> String {
        switch kind {
        case .magicTrackpad: return "rectangle.roundedtop.fill"
        case .magicMouse: return "magicmouse.fill"
        default: return AppleDevicePresentation.symbol(for: kind)
        }
    }

    private func navigatorSubtitle(for device: AppleDeviceSnapshot) -> String {
        let component = device.components.first(where: { $0.kind == .primary }) ?? device.components.first
        if let component {
            if let charging = AppleDevicePresentation.chargingTitle(component.chargingState) { return charging }
            if let status = AppleDevicePresentation.statusTitle(component.status) { return status }
        }
        return AppleDevicePresentation.connectionTitle(device.connection)
    }

    private var localMacSymbol: String {
        snapshot.deviceKind == .portable ? "laptopcomputer" : "desktopcomputer"
    }

    private var localMacIsPowered: Bool {
        switch snapshot.deviceKind {
        case .portable:
            switch snapshot.batteryState {
            case .charging, .charged, .pluggedNotCharging, .finishingCharge: return true
            case .discharging, .unknown: return false
            }
        case .desktop:
            return snapshot.powerSource == .ac
        }
    }

    // MARK: - Severity
    //
    // One policy for the whole pane: a reading at 20% or below is a warning,
    // 10% or below is critical. It mirrors `LowBatteryAlertEngine.Policy`, so
    // a device that is about to alert already reads that way here.

    private enum BatterySeverity {
        case normal
        case warning
        case critical
    }

    private static let warningThreshold = 20
    private static let criticalThreshold = 10

    private func severity(forPercentage percentage: Int?) -> BatterySeverity {
        guard let percentage else { return .normal }
        if percentage <= Self.criticalThreshold { return .critical }
        if percentage <= Self.warningThreshold { return .warning }
        return .normal
    }

    private func severity(for status: DeviceBatteryStatus?) -> BatterySeverity {
        switch status {
        case .critical: return .critical
        case .low: return .warning
        case .ok, nil: return .normal
        }
    }

    private func severity(for component: DeviceBatteryComponent) -> BatterySeverity {
        if component.percentage != nil { return severity(forPercentage: component.percentage) }
        return severity(for: component.status)
    }

    private func deviceSeverity(_ device: AppleDeviceSnapshot) -> BatterySeverity {
        if device.headlinePercentage != nil { return severity(forPercentage: device.headlinePercentage) }
        let severities = device.components.map { severity(for: $0.status) }
        if severities.contains(.critical) { return .critical }
        if severities.contains(.warning) { return .warning }
        return .normal
    }

    private var localMacSeverity: BatterySeverity {
        guard snapshot.deviceKind == .portable else { return .normal }
        return severity(forPercentage: snapshot.batteryPercentage)
    }

    private func severityColor(_ severity: BatterySeverity) -> Color? {
        switch severity {
        case .normal: return nil
        case .warning: return .orange
        case .critical: return .red
        }
    }

    // MARK: - Detail

    /// What the header's own big reading is, when the selected device has
    /// one. A device with several real components — AirPods' two ears and
    /// their case — shows each of them large instead of collapsing them into
    /// one figure that would describe neither.
    private enum PrimaryReading {
        case percentage(Int, tint: Color?)
        case status(String, tint: Color?)
        case components([MetricItem])
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedExternalDevice {
            externalDetail(selectedExternalDevice)
        } else {
            localDetail
        }
    }

    private var localDetail: some View {
        detailCard(
            symbol: localMacSymbol,
            title: localized("This Mac"),
            subtitle: snapshot.deviceKind == .portable ? stateTitle : desktopStateTitle,
            isBeta: false,
            primary: localPrimary,
            metrics: localDetailMetrics
        )
    }

    /// `nil` on desktop rather than a fabricated 0% or 100%: a Mac mini or
    /// Studio has no internal battery to read a number from.
    private var localPrimary: PrimaryReading? {
        guard snapshot.deviceKind == .portable, let percentage = snapshot.batteryPercentage else { return nil }
        return .percentage(percentage, tint: severityColor(localMacSeverity))
    }

    /// The desktop branch shows only what a Mac without a battery actually
    /// has: its power source, its adapter if the system reports one, how many
    /// other devices are visible, and whether low-battery notifications are
    /// on. No battery percentage, no health, no fabricated wattage — those
    /// stay entirely out of the list rather than being shown as invented
    /// values.
    private var localDetailMetrics: [MetricItem] {
        guard snapshot.deviceKind == .portable else {
            var items = [MetricItem(value: powerSourceValue, title: localized("Source"))]
            if snapshot.adapterRatedPowerWatts != nil {
                items.append(MetricItem(value: adapterValue, title: localized("Power Adapter")))
            }
            items.append(contentsOf: sharedMacFacts)
            return items
        }
        var items = [MetricItem(value: timeValue, title: timeTitle)]
        items.append(contentsOf: batteryMetrics)
        items.append(contentsOf: sharedMacFacts)
        return items
    }

    /// Facts that exist regardless of battery hardware. Both come straight
    /// from state that already drives real behaviour elsewhere in the app —
    /// `DevicePowerCenter`'s own device list and the low-battery alert
    /// setting — never invented for this card.
    private var sharedMacFacts: [MetricItem] {
        [
            MetricItem(value: "\(externalDevices.count)", title: localized("Devices")),
            MetricItem(
                value: settings.lowBatteryAlertsEnabled ? localized("Enabled") : localized("Disabled"),
                title: localized("Notifications")
            ),
        ]
    }

    private func externalDetail(_ device: AppleDeviceSnapshot) -> some View {
        detailCard(
            symbol: navigatorSymbol(for: device.kind),
            title: device.displayName,
            subtitle: externalDetailSubtitle(for: device),
            isBeta: AppleDevicePresentation.isBeta(device.kind),
            primary: externalPrimary(for: device),
            metrics: externalDetailFacts(for: device)
        )
    }

    private func externalDetailSubtitle(for device: AppleDeviceSnapshot) -> String {
        "\(AppleDevicePresentation.connectionTitle(device.connection)) · \(availabilityTitle(device.availability))"
    }

    private func availabilityTitle(_ availability: DeviceAvailability) -> String {
        availability == .connected ? localized("Connected") : localized("Unavailable")
    }

    /// One real reading becomes the header's big number; several real
    /// components become one large figure each, never an average that would
    /// describe none of them.
    private func externalPrimary(for device: AppleDeviceSnapshot) -> PrimaryReading? {
        let readable = device.components.filter(\.hasReading)
        if readable.count > 1 {
            return .components(readable.map(componentMetric))
        }
        guard let only = readable.first else { return nil }
        if let percentage = only.percentage {
            return .percentage(percentage, tint: severityColor(severity(for: only)))
        }
        return .status(AppleDevicePresentation.readingTitle(only), tint: severityColor(severity(for: only)))
    }

    private func componentMetric(_ component: DeviceBatteryComponent) -> MetricItem {
        var value = AppleDevicePresentation.readingTitle(component)
        if let charging = AppleDevicePresentation.chargingTitle(component.chargingState), charging != value {
            value += " · \(charging)"
        }
        return MetricItem(
            value: value,
            title: AppleDevicePresentation.componentTitle(component.kind),
            tint: severityColor(severity(for: component))
        )
    }

    private func externalDetailFacts(for device: AppleDeviceSnapshot) -> [MetricItem] {
        var items = [
            MetricItem(value: AppleDevicePresentation.connectionTitle(device.connection), title: localized("Connection")),
            MetricItem(value: availabilityTitle(device.availability), title: localized("State")),
            MetricItem(
                value: AppleDevicePresentation.ageTitle(
                    since: device.lastUpdated,
                    freshness: AppleDevicePresentation.freshness(for: device),
                    source: device.source,
                    abbreviated: true
                ),
                title: localized("Updated")
            ),
        ]
        let representative = device.components.first(where: { $0.kind == .primary }) ?? device.components.first
        if let representative, let charging = AppleDevicePresentation.chargingTitle(representative.chargingState) {
            items.append(MetricItem(value: charging, title: localized("Charging")))
        }
        return items
    }

    private func detailCard(
        symbol: String,
        title: String,
        subtitle: String,
        isBeta: Bool,
        primary: PrimaryReading?,
        metrics: [MetricItem]
    ) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: symbol)
                        .font(Theme.Glyph.heroStrong)
                        .foregroundStyle(Theme.primary.opacity(0.86))
                    VStack(alignment: .leading, spacing: Theme.Space.hair) {
                        HStack(spacing: Theme.Space.xs) {
                            Text(title)
                                .font(Theme.Typo.title)
                                .foregroundStyle(Theme.primary)
                                .lineLimit(1)
                            if isBeta {
                                Text(localized("Beta"))
                                    .font(Theme.Typo.captionSemibold)
                                    .foregroundStyle(Theme.secondary)
                                    .padding(.horizontal, Theme.Space.xs)
                                    .padding(.vertical, 1)
                                    .background(Theme.surfaceHover, in: Capsule())
                            }
                        }
                        Text(subtitle)
                            .font(Theme.Typo.caption)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                if let primary {
                    primaryReadingView(primary)
                }

                if !metrics.isEmpty {
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(height: 1)

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(minimum: 80), spacing: Theme.Space.l),
                            GridItem(.flexible(minimum: 80), spacing: Theme.Space.l),
                        ],
                        alignment: .leading,
                        spacing: Theme.Space.s
                    ) {
                        ForEach(metrics) { item in
                            metric(item.value, title: item.title, tint: item.tint)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Space.xs)
            .padding(.bottom, Theme.Space.xs)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func primaryReadingView(_ primary: PrimaryReading) -> some View {
        switch primary {
        case .percentage(let value, let tint):
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("\(value)%")
                    .font(Theme.Typo.hero)
                    .foregroundStyle(tint ?? Theme.primary)
                batteryBar(percentage: value, tint: tint)
                    .frame(maxWidth: 180)
            }
        case .status(let text, let tint):
            Text(text)
                .font(Theme.Typo.title)
                .foregroundStyle(tint ?? Theme.primary)
        case .components(let items):
            HStack(alignment: .top, spacing: Theme.Space.l) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: Theme.Space.hair) {
                        Text(item.value)
                            .font(Theme.Typo.bodyDigits)
                            .foregroundStyle(item.tint ?? Theme.primary)
                            .lineLimit(2)
                        Text(item.title)
                            .font(Theme.Typo.caption)
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func batteryBar(percentage: Int, tint: Color?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface)
                Capsule()
                    .fill(tint ?? Theme.focusRing)
                    .frame(width: geo.size.width * CGFloat(min(100, max(0, percentage))) / 100)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
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
        if diagnostics.contains(where: { $0.status == .deviceLocked }) {
            return localized("A device is locked. Its last known reading is shown until it unlocks.")
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
        if devices.diagnostics.contains(where: { $0.status == .deviceLocked }) {
            return "lock"
        }
        if devices.diagnostics.contains(where: { $0.status == .temporarilyFailed }) {
            return "exclamationmark.triangle"
        }
        return externalDevices.isEmpty ? "minus.circle" : "checkmark.circle"
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
                    .padding(.vertical, Theme.Space.s)

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
        .padding(.horizontal, Theme.Space.xs)
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
                    // Matches `battery`'s equivalent hero-row divider — the
                    // laptop and desktop hero layouts differ, but this divider
                    // plays the same visual role in both.
                    .padding(.vertical, Theme.Space.s)

                HStack(spacing: Theme.Space.xl + 12) {
                    metric(powerSourceValue, title: localized("Source"))
                    metric(desktopConnectionValue, title: localized("State"))
                    metric(adapterValue, title: localized("Power Adapter"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.horizontal, Theme.Space.xs)
    }

    /// Same trade as `heroWidth`, and the same reason: a flat 160 pt here left
    /// the compact preset 243 pt for metrics that need 268, so the Power
    /// Adapter column ran off the edge. This hero has more slack than the
    /// battery one — its widest line is "Питание" at 86 pt — so the floor of
    /// 104 pt is a guard rather than a working value; compact settles at 128.
    private func desktopHeroWidth(in paneWidth: CGFloat) -> CGFloat {
        min(160, max(104, paneWidth - Self.desktopMetricsReservation))
    }

    private func metric(_ value: String, title: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs - 1) {
            Text(value)
                .font(Theme.Typo.bodyDigits)
                .foregroundStyle(tint ?? Theme.primary)
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
    var tint: Color? = nil

    var id: String { title }
}

/// One row of the Device Navigator. This Mac and every external device
/// resolve to the same shape, so the row view and its accessibility wiring
/// exist exactly once.
private struct NavigatorEntry: Identifiable {
    let key: String
    let symbol: String
    let title: String
    let subtitle: String
    let dotColor: Color?
    let trailingValue: String?
    let trailingColor: Color?
    let accessibilityValue: String

    var id: String { key }
}
