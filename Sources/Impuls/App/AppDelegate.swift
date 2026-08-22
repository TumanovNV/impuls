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
    private lazy var versionTelemetryScheduler = VersionTelemetryScheduler { [weak self] in
        guard let self else { return }
        _ = await self.versionTelemetryService.sendHeartbeatIfNeeded()
    }
    private lazy var feedbackWindowController = FeedbackWindowController()
    private var settingsWindowController: SettingsWindowController?
    private var onboardingController: OnboardingWindowController?
    /// Machine-local eligibility for the app's only proactive project-support
    /// ask. Impuls does put other requests to the user — update consent, the
    /// version-statistics offer, macOS permission flows — but each of those is
    /// tied to a feature being set up or used. This one asks for a favour, so it
    /// is the one that has to earn its appearance and then stop.
    ///
    /// Shares the settings defaults so a test suite pointing Settings at its own
    /// domain cannot reach the real counters either.
    private lazy var projectSupportPrompt = ProjectSupportPromptService(defaults: settings.defaults)
    private lazy var projectSupportPromptWindowController = ProjectSupportPromptWindowController(
        service: projectSupportPrompt,
        onFeedback: { [weak self] in self?.feedbackWindowController.show() }
    )
    /// The single pending "ask after the dust settles" item.
    ///
    /// Not a timer and not a repeating anything: it is created only by a quiet
    /// transition, replaced by nothing, cancelled by the user starting work
    /// again, and cancelled once more on termination.
    private var projectSupportPromptWork: DispatchWorkItem?
    private var didPresentProjectSupportPrompt = false
    /// When this process started, so a prompt can never be part of launch.
    private let launchedAt = Date()

    /// How long Impuls stays quiet after the panel folds before it considers
    /// asking. Long enough that the prompt is clearly not a reaction to the
    /// action just taken, short enough to still belong to the same sitting.
    private static let projectSupportPromptQuietDelay: TimeInterval = 8
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
        installProjectSupportPrompt()
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
        // path that builds the panel, status item, and global shortcut. The
        // scheduler then keeps proposing an attempt roughly hourly for the rest
        // of the run — VersionTelemetryService still owns whether any of those
        // proposals actually becomes a request.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            Task { _ = await self.versionTelemetryService.sendHeartbeatIfNeeded() }
            self.versionTelemetryScheduler.start()
        }
        onboardingController?.presentIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey.onPress = nil
        versionTelemetryScheduler.stop()
        cancelProjectSupportPrompt()
        controller?.teardown()
    }

    // MARK: - Project support prompt

    private func installProjectSupportPrompt() {
        controller?.onMeaningfulUse = { [weak self] in
            guard let self else { return }
            // Work resuming retires anything waiting to be asked: the quiet
            // moment the prompt was queued for has ended, and the next fold
            // will offer a new one.
            self.cancelProjectSupportPrompt()
            self.projectSupportPrompt.recordMeaningfulUse()
        }
        controller?.onReturnedToIdle = { [weak self] in
            self?.scheduleProjectSupportPrompt()
        }
    }

    /// Queues the single delayed check that may put the prompt on screen.
    ///
    /// Eligibility is consulted before anything is scheduled, so the ordinary
    /// case — somebody who has not been using Impuls for a month, or who already
    /// answered — creates no work at all.
    private func scheduleProjectSupportPrompt() {
        guard projectSupportPromptWork == nil,
              !didPresentProjectSupportPrompt,
              projectSupportPrompt.isEligible else { return }

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.presentProjectSupportPromptIfQuiet() }
        }
        projectSupportPromptWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.projectSupportPromptQuietDelay,
            execute: work
        )
    }

    private func cancelProjectSupportPrompt() {
        projectSupportPromptWork?.cancel()
        projectSupportPromptWork = nil
    }

    /// The last gate. Everything is re-read here rather than captured when the
    /// work was queued: eight seconds is long enough for the user to have opened
    /// Settings, started an update, or chosen a new language.
    private func presentProjectSupportPromptIfQuiet() {
        projectSupportPromptWork = nil

        let moment = ProjectSupportPromptMoment(
            timeSinceLaunch: Date().timeIntervalSince(launchedAt),
            isPanelOpen: controller?.viewModel?.isOpen ?? false,
            showsAnotherWindow: showsTitledWindow,
            isAwaitingLanguageRelaunch: settings.appLanguage.requiresRelaunch,
            didPresentInThisSession: didPresentProjectSupportPrompt
        )
        guard projectSupportPrompt.shouldPresent(in: moment) else { return }

        // Recorded before the window exists. If presentation somehow fails, the
        // safe outcome is one fewer prompt, not a loop that keeps trying.
        didPresentProjectSupportPrompt = true
        projectSupportPrompt.recordPresented()
        projectSupportPromptWindowController.show()
    }

    /// Whether any Impuls window with a title bar is on screen.
    ///
    /// One rule instead of a list of controllers to keep in step: onboarding,
    /// What's New, Settings, Feedback and Sparkle's update dialogs are all
    /// ordinary titled windows, and so would a future one be. The notch panels
    /// and the status item are borderless, so neither is mistaken for something
    /// the user is busy with.
    ///
    /// The limit is worth stating plainly: `NSApp.windows` contains only this
    /// process's windows. A macOS permission (TCC) dialog belongs to a system
    /// process and is **not** visible here, so this check does not by itself
    /// prove the prompt cannot appear alongside one. What covers that in
    /// practice is where TCC prompts come from — Impuls only triggers one from
    /// an explicit user action, and those happen either in Settings or in the
    /// open panel, both of which are already blocking. The residual case is a
    /// system dialog that outlives the surface that triggered it; the eight
    /// seconds are measured from the fold, so this is narrow rather than
    /// impossible. `SUP-01` is where it gets checked on real hardware.
    private var showsTitledWindow: Bool {
        NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
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
            // Stateless on purpose: Settings must keep offering this path after
            // the automatic prompt has ended for good, and choosing it there is
            // not an answer to a question Impuls asked.
            onSupportProject: { ProjectSupportPromptService.openProjectPageInBrowser() },
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
