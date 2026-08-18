import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case updates
    case modules
    case appleDevices
    case clipboard
    case permissions
    case dataAndPrivacy
    case feedback

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return localized("General")
        case .updates: return localized("Updates")
        case .modules: return localized("Modules")
        case .appleDevices: return localized("Apple Devices")
        case .clipboard: return localized("Clipboard")
        case .permissions: return localized("Permissions")
        case .dataAndPrivacy: return localized("Data and Privacy")
        case .feedback: return localized("Feedback")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .updates: return "arrow.triangle.2.circlepath"
        case .modules: return "square.grid.2x2"
        case .appleDevices: return "battery.100percent"
        case .clipboard: return "list.clipboard"
        case .permissions: return "hand.raised"
        case .dataAndPrivacy: return "lock.shield"
        case .feedback: return "bubble.left.and.bubble.right"
        }
    }
}

@MainActor
final class SettingsNavigationState: ObservableObject {
    static let selectionKey = "settings.selectedSection.v1"

    @Published var selection: SettingsSection? {
        didSet {
            if let selection {
                defaults.set(selection.rawValue, forKey: Self.selectionKey)
            }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: Self.selectionKey)
            .flatMap(SettingsSection.init(rawValue:)) ?? .general
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private let updateService: UpdateService
    private let versionTelemetryService: VersionTelemetryService
    private let onExport: () -> Void
    private let onImport: () -> Void
    private let onFeedback: () -> Void
    private var window: NSWindow?

    init(
        settings: SettingsStore,
        updateService: UpdateService,
        versionTelemetryService: VersionTelemetryService,
        onExport: @escaping () -> Void,
        onImport: @escaping () -> Void,
        onFeedback: @escaping () -> Void
    ) {
        self.settings = settings
        self.updateService = updateService
        self.versionTelemetryService = versionTelemetryService
        self.onExport = onExport
        self.onImport = onImport
        self.onFeedback = onFeedback
    }

    var presentedWindow: NSWindow? { window }

    func show() {
        settings.refreshDisplays()
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = SettingsView(
            settings: settings,
            updateService: updateService,
            versionTelemetryService: versionTelemetryService,
            onExport: onExport,
            onImport: onImport,
            onFeedback: onFeedback
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = localized("Impuls Settings")
        window.minSize = NSSize(width: 760, height: 540)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ImpulsSettingsWindow")
        if !window.setFrameUsingName("ImpulsSettingsWindow") {
            window.setContentSize(NSSize(width: 900, height: 640))
            window.center()
        }
        window.delegate = self
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @StateObject private var permissions = PermissionCenter()
    @StateObject private var navigation = SettingsNavigationState()
    @FocusState private var sidebarFocused: Bool
    let updateService: UpdateService
    let versionTelemetryService: VersionTelemetryService
    let onExport: () -> Void
    let onImport: () -> Void
    let onFeedback: () -> Void

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $navigation.selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
                    .accessibilityLabel(section.title)
            }
            .listStyle(.sidebar)
            .navigationTitle(localized("Settings"))
            .navigationSplitViewColumnWidth(min: 220, ideal: 230, max: 280)
            .focused($sidebarFocused)
            .accessibilityLabel(localized("Settings Sections"))
        } detail: {
            detail(for: navigation.selection ?? .general)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 540)
        .onAppear { sidebarFocused = true }
    }

    @ViewBuilder
    private func detail(for section: SettingsSection) -> some View {
        SettingsDetailPage(title: section.title) {
            switch section {
            case .general:
                GeneralSettingsPane(settings: settings)
            case .updates:
                UpdateSettingsPane(updateService: updateService)
            case .modules:
                ModuleSettingsPane(settings: settings)
            case .appleDevices:
                AppleDeviceSettingsPane(settings: settings, lowBatteryAlerts: settings.lowBatteryAlerts)
            case .clipboard:
                ClipboardSettingsPane(settings: settings)
            case .permissions:
                PermissionSettingsPane(permissions: permissions)
            case .dataAndPrivacy:
                DataSettingsPane(
                    telemetryService: versionTelemetryService,
                    onExport: onExport,
                    onImport: onImport
                )
            case .feedback:
                SupportSettingsPane(onFeedback: onFeedback)
            }
        }
    }
}

private struct SettingsDetailPage<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.largeTitle.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 14)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
private struct UpdateSettingsPane: View {
    let updateService: UpdateService
    @State private var updateChecksEnabled = false
    @State private var automaticUpdatesEnabled = false
    @State private var automaticUpdatesAvailable = false

    var body: some View {
        Form {
            Section("Update Checks") {
                Toggle("Check for Updates Automatically", isOn: Binding(
                    get: { updateChecksEnabled },
                    set: { enabled in
                        updateService.setNetworkAccess(enabled)
                        refresh()
                    }
                ))
                Text("Impuls checks its signed update channel at most once every 24 hours when an internet connection is available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button("Check for Updates…") {
                    updateService.checkForUpdates()
                }
                .disabled(!updateChecksEnabled || !updateService.canCheckForUpdates)
            }

            Section("Installation") {
                Toggle("Install Updates Automatically", isOn: Binding(
                    get: { automaticUpdatesEnabled },
                    set: { enabled in
                        updateService.setAutomaticUpdates(enabled)
                        refresh()
                    }
                ))
                .disabled(!updateChecksEnabled || !automaticUpdatesAvailable)

                Text(automaticUpdatesEnabled
                    ? "Verified updates download in the background and install when you quit Impuls."
                    : "When a new version is ready, Impuls shows an update notification with an installation option.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        updateChecksEnabled = updateService.consent == .allowed
        automaticUpdatesEnabled = updateService.automaticUpdatesEnabled
        automaticUpdatesAvailable = updateService.canAutomaticallyUpdate
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject var settings: SettingsStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError = ""

    var body: some View {
        Form {
            Section("Access") {
                Picker("Global Shortcut", selection: $settings.hotKey) {
                    ForEach(SettingsStore.HotKeyPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                Picker("Open Panel", selection: $settings.activationMode) {
                    ForEach(SettingsStore.ActivationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("Hover Delay", selection: $settings.openDelay) {
                    ForEach(SettingsStore.OpenDelay.allCases) { delay in
                        Text(delay.title).tag(delay)
                    }
                }
                .disabled(settings.activationMode == .shortcutOnly)
                Text("The shortcut opens Actions. Use ↑ and ↓ to choose, Enter to copy, ← and → to change modules, and Esc to close.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = settings.hotKeyError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Appearance") {
                Picker("Panel Size", selection: $settings.panelSize) {
                    ForEach(SettingsStore.PanelSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                Text("Automatic picks Compact, Standard or Large from the size of the display the panel opens on. Every preset is kept inside that display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Display Behavior", selection: $settings.selectedDisplayID) {
                    Text("All Displays").tag(UInt32?.none)
                    ForEach(settings.displays) { display in
                        Text(display.name).tag(Optional(display.id))
                    }
                }
                Text("On All Displays, Impuls appears on every connected display and opens on the one your pointer is on. Choose a display to keep it there only. Mirrored displays count as one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup and Storage") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { updateLaunchAtLogin($0) }
                ))
                if !launchError.isEmpty {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = ""
        } catch {
            launchError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct ClipboardSettingsPane: View {
    @ObservedObject var settings: SettingsStore
    @State private var applicationError = ""

    var body: some View {
        Form {
            Section("History") {
                Toggle("Save Clipboard Screenshots", isOn: $settings.saveClipboardImages)
                Picker("Keep Unpinned Items", selection: $settings.clipboardRetention) {
                    ForEach(SettingsStore.ClipboardRetention.allCases) { retention in
                        Text(retention.title).tag(retention)
                    }
                }
                Toggle("Keep History Between Launches", isOn: $settings.persistClipboardHistory)
                Text("History stays in memory by default. If persistence is enabled, the archive is encrypted and its key is stored in macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Excluded Applications") {
                Text("Copies made while an excluded application is active are ignored. Concealed password-manager entries are always ignored.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach(settings.excludedClipboardBundleIdentifiers, id: \.self) { identifier in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(applicationName(for: identifier))
                            Text(identifier)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") {
                            settings.includeClipboardApp(bundleIdentifier: identifier)
                        }
                        .controlSize(.small)
                    }
                }

                HStack {
                    Button("Choose Application…", action: chooseApplication)
                    if !applicationError.isEmpty {
                        Text(applicationError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = localized("Exclude Application from Clipboard History")
        panel.prompt = localized("Exclude")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let identifier = Bundle(url: url)?.bundleIdentifier else {
            applicationError = localized("The selected application has no bundle identifier.")
            return
        }
        settings.excludeClipboardApp(bundleIdentifier: identifier)
        applicationError = ""
    }

    private func applicationName(for identifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            return identifier
        }
        return FileManager.default.displayName(atPath: url.path)
    }
}

private struct ModuleSettingsPane: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose which modules are shown and arrange them in the order you use them.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                ForEach(settings.modules) { preference in
                    moduleRow(preference)
                }
            }
            .listStyle(.inset)

            Text("At least one module must remain enabled. Modules are split evenly between the two rails; with an odd number the extra one goes to the left.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
    }

    private func moduleRow(_ preference: ModulePreference) -> some View {
        let index = settings.modules.firstIndex(where: { $0.tab == preference.tab }) ?? 0
        let isOnlyEnabled = preference.isEnabled && settings.enabledTabs.count == 1
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { preference.isEnabled },
                set: { settings.setModule(preference.tab, enabled: $0) }
            )) {
                Label {
                    Text(settings.moduleTitle(for: preference.tab))
                } icon: {
                    Image(systemName: settings.moduleSymbol(for: preference.tab))
                }
            }
            .toggleStyle(.switch)
            .disabled(isOnlyEnabled)

            Spacer()

            Button { settings.moveModule(preference.tab, offset: -1) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help(localized("Move Up"))

            Button { settings.moveModule(preference.tab, offset: 1) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == settings.modules.count - 1)
            .help(localized("Move Down"))
        }
        .padding(.vertical, 4)
    }
}

private struct PermissionSettingsPane: View {
    @ObservedObject var permissions: PermissionCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Impuls requests a system permission only when you use the related function.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 12) {
                    permissionRow(
                        title: localized("Calendar"),
                        detail: localized("Shows upcoming meetings inside the Calendar module."),
                        symbol: "calendar",
                        state: permissions.calendar,
                        primaryTitle: permissions.calendar == .notRequested ? localized("Allow") : nil,
                        primaryAction: permissions.requestCalendar,
                        settingsAction: permissions.openCalendarSettings
                    )

                    permissionRow(
                        title: localized("Music Automation"),
                        detail: localized("Reads track information and controls the Apple Music app. Web players do not need this permission."),
                        symbol: "music.note",
                        state: permissions.musicAutomation,
                        primaryTitle: permissions.musicAutomation == .notRequested ? localized("Allow") : nil,
                        primaryAction: permissions.requestMusicAutomation,
                        settingsAction: permissions.openAutomationSettings,
                        alwaysShowSettings: true
                    )

                    permissionRow(
                        title: localized("Notifications"),
                        detail: localized("Will be used for optional meeting reminders in a later update. No permission is requested yet."),
                        symbol: "bell",
                        state: permissions.notifications,
                        primaryTitle: nil,
                        primaryAction: {},
                        settingsAction: permissions.openNotificationSettings
                    )
                }
            }

            HStack {
                Spacer()
                Button("Refresh Status") { permissions.refresh() }
            }
        }
        .padding(8)
        .onAppear { permissions.refresh() }
    }

    private func permissionRow(
        title: String,
        detail: String,
        symbol: String,
        state: PermissionCenter.State,
        primaryTitle: String?,
        primaryAction: @escaping () -> Void,
        settingsAction: @escaping () -> Void,
        alwaysShowSettings: Bool = false
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .frame(width: 30)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                Label(state.title, systemImage: state == .allowed ? "checkmark.circle.fill" : "circle.fill")
                    .font(.caption)
                    .foregroundStyle(state == .allowed ? .green : .secondary)
                HStack(spacing: 8) {
                    if let primaryTitle {
                        Button(primaryTitle, action: primaryAction)
                    }
                    if state == .denied || state == .restricted || alwaysShowSettings {
                        Button("Open Settings", action: settingsAction)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DataSettingsPane: View {
    let telemetryService: VersionTelemetryService
    let onExport: () -> Void
    let onImport: () -> Void
    @State private var sendsVersionStatistics = false

    var body: some View {
        Form {
            Section("Backup") {
                Text("A backup contains panel and clipboard settings, module order, snippets, and notes. Clipboard history, shelf files, and screenshots are not copied.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Export Data…", action: onExport)
                    Button("Import Data…", action: onImport)
                }
            }

            Section("Privacy") {
                Text("The backup is a local JSON file. Impuls does not upload it or send it over the network.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section(localized("Help Improve Impuls")) {
                Toggle(
                    localized("Send Version Statistics"),
                    isOn: Binding(
                        get: { sendsVersionStatistics },
                        set: { enabled in
                            sendsVersionStatistics = enabled
                            telemetryService.setConsent(enabled ? .allowed : .denied)
                            if enabled {
                                Task { _ = await telemetryService.sendHeartbeatIfNeeded() }
                            }
                        }
                    )
                )
                .disabled(!telemetryService.isEndpointConfigured && !sendsVersionStatistics)
                .accessibilityHint(localized("Controls the separate opt-in version statistics network request."))

                Text(localized("When enabled, Impuls sends a random installation identifier, the current Impuls version, and the previous version when it can be determined correctly."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(localized("Impuls content and personal data are never included. The installation identifier is a pseudonym stored in this Mac's Keychain, not a hardware or user identifier."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !telemetryService.isEndpointConfigured {
                    Text(localized("Version statistics are unavailable in this build because no collector endpoint is configured."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(localized("Learn More About Privacy"), action: openPrivacyPolicy)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            sendsVersionStatistics = telemetryService.consent == .allowed
        }
    }

    private func openPrivacyPolicy() {
        guard let url = URL(string: "https://github.com/TumanovNV/impuls/blob/main/PRIVACY.md") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct SupportSettingsPane: View {
    let onFeedback: () -> Void

    var body: some View {
        Form {
            Section("Feedback") {
                Text("Report a problem, suggest an improvement, or tell us about your experience. Impuls prepares a transparent report and opens GitHub only after your action.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Send Feedback…", action: onFeedback)
            }

            Section("Privacy") {
                Text(localized("No feedback, diagnostics, or crash reports are sent automatically. Version statistics have a separate opt-in in Data and Privacy. GitHub issues are public, and the report can be reviewed before it leaves your Mac."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Security Reports") {
                Text("Do not publish an unpatched vulnerability or confidential data in a public issue. Use the private security reporting process described in SECURITY.md.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
