import SwiftUI

/// Local controls for the opt-in Apple Device Battery Center.
///
/// This view receives only sanitised snapshots. Per-device choices are keyed by
/// the local HMAC value inside SettingsStore and never enter a backup.
@MainActor
struct AppleDeviceSettingsPane: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var lowBatteryAlerts: LowBatteryAlertService
    @State private var devicePendingForget: AppleDeviceSnapshot?

    var body: some View {
        Form {
            Section(localized("Discovery")) {
                Toggle(
                    localized("Show Connected Apple Devices"),
                    isOn: $settings.showsExternalAppleDevices
                )
                Text(localized("External device discovery is off by default. Device data is never sent over the internet; processing stays local to this Mac and its connected devices. Bluetooth permission is not requested."))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(
                        settings.showsExternalAppleDevices
                            ? localized("Refresh Devices")
                            : localized("Find Devices"),
                        action: settings.findExternalAppleDevices
                    )
                    .disabled(!settings.isPowerModuleEnabled)

                    if isStarting {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(localized("Looking for connected Apple devices"))
                    }
                }

                if !settings.isPowerModuleEnabled {
                    Text(localized("Enable the Power module before looking for Apple devices."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if settings.showsExternalAppleDevices {
                    Label(statusMessage, systemImage: statusSymbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(localized("Devices")) {
                if displayedDevices.isEmpty {
                    Text(emptyDevicesMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(displayedDevices, id: \.identity) { device in
                        deviceRow(device)
                    }
                }
            }

            Section(localized("Battery Notifications")) {
                Toggle(
                    localized("Warn About Low Battery"),
                    isOn: Binding(
                        get: { settings.lowBatteryAlertsEnabled },
                        set: { settings.setLowBatteryAlertsEnabledByUser($0) }
                    )
                )
                Text(localized("Impuls will notify you when a connected device reaches 20% or 10%."))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if settings.lowBatteryAlertsEnabled, lowBatteryAlerts.authorization == .denied {
                    Text(localized("Notifications are disabled for Impuls in macOS settings. Battery monitoring will continue without alerts."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if MobileDeviceBatteryProvider.isEnabled {
                Section(localized("Beta")) {
                    Text(localized("iPhone and iPad battery support is experimental. It uses an existing trust relationship over USB or macOS Wi-Fi sync and never pairs or changes the device."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { lowBatteryAlerts.refreshAuthorization() }
        .alert(
            localized("Forget Device?"),
            isPresented: Binding(
                get: { devicePendingForget != nil },
                set: { if !$0 { devicePendingForget = nil } }
            )
        ) {
            Button(localized("Cancel"), role: .cancel) {
                devicePendingForget = nil
            }
            Button(localized("Forget"), role: .destructive) {
                if let devicePendingForget {
                    settings.forgetAppleDevice(devicePendingForget)
                }
                devicePendingForget = nil
            }
        } message: {
            Text(localized("Impuls will remove this device's local visibility and order preferences. A connected device can appear again after discovery."))
        }
    }

    private var relevantDiagnostics: [DeviceProviderDiagnostic] {
        settings.appleDeviceDiagnostics.filter { diagnostic in
            switch diagnostic.provider {
            case .localMac: return false
            case .mobileDevice: return MobileDeviceBatteryProvider.isEnabled
            case .appleAccessory: return true
            }
        }
    }

    /// A mobile snapshot can remain in this run's Settings list after the
    /// experimental flag is removed. The flag is the product boundary, so its
    /// rows disappear with it even though their local order preference remains.
    private var displayedDevices: [AppleDeviceSnapshot] {
        settings.knownExternalAppleDevices.filter {
            MobileDeviceBatteryProvider.isEnabled || !AppleDevicePresentation.isBeta($0.kind)
        }
    }

    private var isStarting: Bool {
        relevantDiagnostics.contains { $0.status == .starting }
    }

    private var statusMessage: String {
        if relevantDiagnostics.contains(where: { $0.status == .permissionRequired }) {
            return localized("Unlock your iPhone or iPad and tap Trust This Computer.")
        }
        if relevantDiagnostics.contains(where: { $0.status == .temporarilyFailed }) {
            return localized("Some devices could not be refreshed. Last known readings show their age.")
        }
        if isStarting { return localized("Looking for connected Apple devices…") }
        if displayedDevices.contains(where: settings.isAppleDeviceCurrent) {
            return localized("Connected devices are up to date.")
        }
        return localized("No connected Apple devices found.")
    }

    private var statusSymbol: String {
        if relevantDiagnostics.contains(where: { $0.status == .permissionRequired }) {
            return "lock.open"
        }
        if relevantDiagnostics.contains(where: { $0.status == .temporarilyFailed }) {
            return "exclamationmark.triangle"
        }
        if isStarting { return "magnifyingglass" }
        if displayedDevices.contains(where: settings.isAppleDeviceCurrent) {
            return "checkmark.circle"
        }
        return "minus.circle"
    }

    private var emptyDevicesMessage: String {
        if !settings.showsExternalAppleDevices {
            return localized("Turn on discovery to find connected AirPods and Apple accessories.")
        }
        return statusMessage
    }

    private func deviceRow(_ device: AppleDeviceSnapshot) -> some View {
        let index = displayedDevices.firstIndex(where: { $0.identity == device.identity }) ?? 0
        let isCurrent = settings.isAppleDeviceCurrent(device)
        let freshness = isCurrent
            ? AppleDevicePresentation.freshness(for: device)
            : DeviceFreshness.stale
        let age = AppleDevicePresentation.ageTitle(
            since: device.lastUpdated,
            freshness: freshness,
            source: device.source
        )

        return HStack(spacing: 12) {
            Image(systemName: AppleDevicePresentation.symbol(for: device.kind))
                .font(.system(size: 18))
                .frame(width: 26)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.displayName)
                        .lineLimit(1)
                    if AppleDevicePresentation.isBeta(device.kind) {
                        Text(localized("Beta"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(deviceSummary(device, age: age))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Toggle(
                localized("Show %@", device.displayName),
                isOn: Binding(
                    get: { settings.isAppleDeviceVisible(device) },
                    set: { settings.setAppleDevice(device, visible: $0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel(localized("Show %@", device.displayName))

            Button { settings.moveAppleDevice(device, offset: -1, among: displayedDevices) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help(localized("Move %@ Up", device.displayName))
            .accessibilityLabel(localized("Move %@ Up", device.displayName))

            Button { settings.moveAppleDevice(device, offset: 1, among: displayedDevices) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == displayedDevices.count - 1)
            .help(localized("Move %@ Down", device.displayName))
            .accessibilityLabel(localized("Move %@ Down", device.displayName))

            Button(role: .destructive) {
                devicePendingForget = device
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!settings.canForgetAppleDevice(device))
            .help(
                settings.canForgetAppleDevice(device)
                    ? localized("Forget %@", device.displayName)
                    : localized("Hide or disconnect this device before forgetting it.")
            )
            .accessibilityLabel(localized("Forget %@", device.displayName))
        }
        .padding(.vertical, 4)
    }

    private func deviceSummary(_ device: AppleDeviceSnapshot, age: String) -> String {
        let readings = device.components.map(AppleDevicePresentation.readingTitle).joined(separator: " · ")
        let connection = AppleDevicePresentation.connectionTitle(device.connection)
        return [readings, connection, age].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
