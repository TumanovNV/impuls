import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private let onExport: () -> Void
    private let onImport: () -> Void
    private let onFeedback: () -> Void
    private var window: NSWindow?

    init(
        settings: SettingsStore,
        onExport: @escaping () -> Void,
        onImport: @escaping () -> Void,
        onFeedback: @escaping () -> Void
    ) {
        self.settings = settings
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
            onExport: onExport,
            onImport: onImport,
            onFeedback: onFeedback
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = localized("Impuls Settings")
        window.setContentSize(NSSize(width: 700, height: 540))
        window.minSize = NSSize(width: 640, height: 500)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @StateObject private var permissions = PermissionCenter()
    let onExport: () -> Void
    let onImport: () -> Void
    let onFeedback: () -> Void

    var body: some View {
        TabView {
            GeneralSettingsPane(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            ModuleSettingsPane(settings: settings)
                .tabItem { Label("Modules", systemImage: "square.grid.2x2") }
            ClipboardSettingsPane(settings: settings)
                .tabItem { Label("Clipboard", systemImage: "list.clipboard") }
            PermissionSettingsPane(permissions: permissions)
                .tabItem { Label("Permissions", systemImage: "hand.raised") }
            DataSettingsPane(onExport: onExport, onImport: onImport)
                .tabItem { Label("Data", systemImage: "externaldrive") }
            SupportSettingsPane(onFeedback: onFeedback)
                .tabItem { Label("Feedback", systemImage: "bubble.left.and.bubble.right") }
        }
        .padding(18)
        .frame(minWidth: 600, minHeight: 430)
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
                Picker("Display", selection: $settings.selectedDisplayID) {
                    Text("Automatic").tag(UInt32?.none)
                    ForEach(settings.displays) { display in
                        Text(display.name).tag(Optional(display.id))
                    }
                }
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

            Text("At least one module must remain enabled. The first six modules appear on the left rail; any remaining module appears on the right.")
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
                    Text(preference.tab.title)
                } icon: {
                    Image(systemName: preference.tab.symbol)
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
                title: localized("Accessibility"),
                detail: localized("Lets media controls send standard system media keys when no supported player is active."),
                symbol: "accessibility",
                state: permissions.accessibility,
                primaryTitle: permissions.accessibility == .allowed ? nil : localized("Allow"),
                primaryAction: permissions.requestAccessibility,
                settingsAction: permissions.openAccessibilitySettings
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

            Spacer()
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
        settingsAction: @escaping () -> Void
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
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                Label(state.title, systemImage: state == .allowed ? "checkmark.circle.fill" : "circle.fill")
                    .font(.caption)
                    .foregroundStyle(state == .allowed ? .green : .secondary)
                HStack(spacing: 8) {
                    if let primaryTitle {
                        Button(primaryTitle, action: primaryAction)
                    }
                    if state == .denied || state == .restricted || title == localized("Accessibility") {
                        Button("Open Settings", action: settingsAction)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DataSettingsPane: View {
    let onExport: () -> Void
    let onImport: () -> Void

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
        }
        .formStyle(.grouped)
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
                Text("No feedback, analytics, diagnostics, or crash reports are sent automatically. GitHub issues are public, and the report can be reviewed before it leaves your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
