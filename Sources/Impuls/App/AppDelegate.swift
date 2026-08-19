import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var settings = SettingsStore()
    private let hotKey = GlobalHotKey()
    private var controller: NotchController?
    private var cancellables = Set<AnyCancellable>()
    private let updateService = UpdateService()
    private let versionTelemetryService = VersionTelemetryService()
    private lazy var feedbackWindowController = FeedbackWindowController()
    private var settingsWindowController: SettingsWindowController?
    private var onboardingController: OnboardingWindowController?
    private lazy var menuBarWorkspaceController = MenuBarWorkspaceController(
        settings: settings,
        updateService: updateService,
        actions: .init(
            openPanel: { [weak self] in self?.controller?.open() },
            openTab: { [weak self] tab in self?.controller?.open(tab: tab) },
            openSettings: { [weak self] in self?.settingsWindowController?.show() },
            checkForUpdates: { [weak self] in self?.updateService.checkForUpdates() },
            openFeedback: { [weak self] in self?.feedbackWindowController.show() },
            revealScreenshots: { ScreenshotVault.reveal() },
            clearScreenshots: { [weak self] in
                ScreenshotVault.clear { self?.controller?.reloadShelf() }
            },
            quit: { NSApp.terminate(nil) }
        )
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        LegacyMigration.runIfNeeded()
        controller = NotchController(settings: settings, environment: .live)
        controller?.install()
        installWindowControllers()
        settings.lowBatteryAlerts.onOpenPowerCenter = { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.controller?.openPower()
        }
        installGlobalHotKey()
        if let viewModel = controller?.viewModel {
            menuBarWorkspaceController.install(viewModel: viewModel)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.updateService.requestConsentIfNeeded()
        }
        // Consent and endpoint checks happen before the network transport is touched.
        // Delaying the best-effort heartbeat also keeps it outside the launch
        // path that builds the panel, status item, and global shortcut.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            Task { _ = await self.versionTelemetryService.sendHeartbeatIfNeeded() }
        }
        onboardingController?.presentIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey.onPress = nil
        controller?.teardown()
    }

    private func installWindowControllers() {
        onboardingController = OnboardingWindowController(
            settings: settings,
            defaults: settings.defaults,
            versionTelemetryService: versionTelemetryService,
            onOpenSettings: { [weak self] in self?.settingsWindowController?.show() }
        )
        settingsWindowController = SettingsWindowController(
            settings: settings,
            updateService: updateService,
            versionTelemetryService: versionTelemetryService,
            onExport: { [weak self] in self?.exportData() },
            onImport: { [weak self] in self?.importData() },
            onFeedback: { [weak self] in self?.feedbackWindowController.show() },
            onShowOnboarding: { [weak self] in self?.onboardingController?.showFullTour() }
        )
    }

    private func installGlobalHotKey() {
        hotKey.onPress = { [weak self] in
            Task { @MainActor in self?.controller?.toggleFromKeyboard() }
        }
        settings.$hotKey
            .removeDuplicates()
            .sink { [weak self] preset in
                guard let self else { return }
                let succeeded = self.hotKey.register(preset)
                self.settings.reportHotKeyRegistration(succeeded: succeeded)
                if !succeeded {
                    NSLog("Impuls: global shortcut registration failed with status \(self.hotKey.registrationStatus)")
                }
            }
            .store(in: &cancellables)
    }

    private func exportData() {
        guard let document = controller?.makeBackup(settings: settings.snapshot) else { return }
        BackupService.export(document, from: settingsWindowController?.presentedWindow)
    }

    private func importData() {
        BackupService.importData(from: settingsWindowController?.presentedWindow) { [weak self] document in
            self?.controller?.restore(document)
        }
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
