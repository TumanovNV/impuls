import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private lazy var settings = SettingsStore()
    private let hotKey = GlobalHotKey()
    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private var clearVaultItem: NSMenuItem?
    private var networkAccessItem: NSMenuItem?
    private var saveShotsItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()
    private let updateService = UpdateService()
    private lazy var settingsWindowController = SettingsWindowController(
        settings: settings,
        onExport: { [weak self] in self?.exportData() },
        onImport: { [weak self] in self?.importData() }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        LegacyMigration.runIfNeeded()
        controller = NotchController(settings: settings)
        controller?.install()
        installGlobalHotKey()
        installStatusItem()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.updateService.requestConsentIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey.onPress = nil
        controller?.teardown()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = statusIcon()
        item.button?.toolTip = "Impuls"

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(withTitle: "Impuls \(Bundle.main.shortVersion)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: localized("Open Panel"), action: #selector(togglePanel), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = true
        menu.addItem(toggle)

        let preferences = NSMenuItem(title: localized("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        preferences.target = self
        preferences.isEnabled = true
        menu.addItem(preferences)

        menu.addItem(.separator())

        let login = NSMenuItem(title: localized("Launch at Login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = launchAtLoginEnabled ? .on : .off
        login.isEnabled = true
        menu.addItem(login)
        launchAtLoginItem = login

        let saveShots = NSMenuItem(title: localized("Save Clipboard Screenshots"), action: #selector(toggleSaveClipboardImages), keyEquivalent: "")
        saveShots.target = self
        saveShots.state = settings.saveClipboardImages ? .on : .off
        saveShots.isEnabled = true
        menu.addItem(saveShots)
        saveShotsItem = saveShots

        let openFolder = NSMenuItem(title: localized("Show Screenshots Folder"), action: #selector(revealScreenshots), keyEquivalent: "")
        openFolder.target = self
        openFolder.isEnabled = true
        menu.addItem(openFolder)

        let clearVault = NSMenuItem(title: localized("Clear Screenshots Folder"), action: #selector(clearScreenshots), keyEquivalent: "")
        clearVault.target = self
        menu.addItem(clearVault)
        clearVaultItem = clearVault

        let openSnippets = NSMenuItem(title: localized("Show Snippets File"), action: #selector(revealSnippets), keyEquivalent: "")
        openSnippets.target = self
        openSnippets.isEnabled = true
        menu.addItem(openSnippets)

        menu.addItem(.separator())

        let checkUpdates = NSMenuItem(title: localized("Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdates.target = self
        checkUpdates.isEnabled = true
        menu.addItem(checkUpdates)

        let networkAccess = NSMenuItem(title: localized("Allow Update Checks"), action: #selector(toggleNetworkAccess), keyEquivalent: "")
        networkAccess.target = self
        networkAccess.isEnabled = true
        menu.addItem(networkAccess)
        networkAccessItem = networkAccess

        menu.addItem(.separator())
        let quit = NSMenuItem(title: localized("Quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.isEnabled = true
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private func statusIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "ImpulsStatusTemplate", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }

        let fallback = NSImage(
            systemSymbolName: "waveform.path.ecg",
            accessibilityDescription: "Impuls"
        )
        fallback?.isTemplate = true
        return fallback
    }

    func menuWillOpen(_ menu: NSMenu) {
        launchAtLoginItem?.state = launchAtLoginEnabled ? .on : .off
        saveShotsItem?.state = settings.saveClipboardImages ? .on : .off
        if let networkAccessItem {
            networkAccessItem.state = updateService.consent == .allowed ? .on : .off
        }

        guard let clearVaultItem else { return }
        let usage = ScreenshotVault.usage()
        if usage.files == 0 {
            clearVaultItem.title = localized("Clear Screenshots Folder")
            clearVaultItem.isEnabled = false
        } else {
            let size = ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file)
            clearVaultItem.title = localized("Clear Screenshots Folder (%@)", size)
            clearVaultItem.isEnabled = true
        }
    }

    @objc private func togglePanel() { controller?.toggle() }
    @objc private func openSettings() { settingsWindowController.show() }

    @objc private func clearScreenshots() {
        ScreenshotVault.clear()
        controller?.reloadShelf()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleSaveClipboardImages(_ sender: NSMenuItem) {
        settings.saveClipboardImages.toggle()
        sender.state = settings.saveClipboardImages ? .on : .off
    }

    @objc private func revealScreenshots() { ScreenshotVault.reveal() }
    @objc private func revealSnippets() { SnippetStore.reveal() }
    @objc private func checkForUpdates() { updateService.checkForUpdates() }

    @objc private func toggleNetworkAccess(_ sender: NSMenuItem) {
        let allowed = updateService.consent != .allowed
        updateService.setNetworkAccess(allowed)
        sender.state = allowed ? .on : .off
    }

    private var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if launchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Impuls: launch-at-login failed: \(error.localizedDescription)")
        }
        sender.state = launchAtLoginEnabled ? .on : .off
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
        BackupService.export(document, from: settingsWindowController.presentedWindow)
    }

    private func importData() {
        BackupService.importData(from: settingsWindowController.presentedWindow) { [weak self] document in
            self?.controller?.restore(document)
        }
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
