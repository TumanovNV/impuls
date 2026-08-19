import AppKit
import Combine

/// Owns the one status item and translates the pure workspace policy into
/// AppKit menu rows. It observes existing publishers only: no polling, no
/// provider activation and no network work starts from this controller.
@MainActor
final class MenuBarWorkspaceController: NSObject, NSMenuDelegate {
    struct Actions {
        let openPanel: () -> Void
        let openTab: (NotchViewModel.Tab) -> Void
        let openSettings: () -> Void
        let checkForUpdates: () -> Void
        let openFeedback: () -> Void
        let revealScreenshots: () -> Void
        let clearScreenshots: () -> Void
        let quit: () -> Void
    }

    private let settings: SettingsStore
    private let updateService: UpdateService
    private let actions: Actions
    private var statusItem: NSStatusItem?
    private weak var viewModel: NotchViewModel?
    private var cancellables = Set<AnyCancellable>()

    init(settings: SettingsStore, updateService: UpdateService, actions: Actions) {
        self.settings = settings
        self.updateService = updateService
        self.actions = actions
    }

    func install(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.toolTip = "Impuls"
        statusItem = item

        settings.$menuBarWorkspace
            .combineLatest(settings.$menuBarSelectedDevicePreferenceKey)
            .sink { [weak self] _, _ in self?.refresh() }
            .store(in: &cancellables)
        settings.$modules
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        viewModel.power.$snapshot
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        viewModel.devices.$devices
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        viewModel.media.objectWillChange
            .sink { [weak self] _ in
                // ObservableObject announces before its stored values change.
                // Deferring one main-loop turn reads the matching player state
                // without introducing a poll or a retained task.
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &cancellables)

        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
        // A menu can remain open across a source update. Rebuild at the moment
        // of presentation so its disabled/enabled state is truthful without a
        // periodic refresh loop.
        refresh()
    }

    private func refresh() {
        guard let item = statusItem else { return }
        let state = workspaceState()
        let configuration = settings.menuBarWorkspace
        let content = MenuBarWorkspaceResolver.resolve(
            mode: configuration.statusMode,
            configuration: configuration,
            state: state
        )
        updateStatusButton(item, content: content)
        item.menu = makeMenu(configuration: configuration, state: state)
    }

    private func workspaceState() -> MenuBarWorkspaceState {
        guard let viewModel else { return MenuBarWorkspaceState() }
        let snapshot = viewModel.power.snapshot
        let macBattery: MenuBarBattery?
        if snapshot.deviceKind == .portable, snapshot.batteryPercentage != nil {
            macBattery = MenuBarBattery(
                identifier: "local-mac",
                title: localized("This Mac"),
                percentage: snapshot.batteryPercentage,
                state: .init(snapshot.batteryState)
            )
        } else {
            macBattery = nil
        }

        let devices = settings.visibleExternalAppleDevices(from: viewModel.devices.visibleDevices)
            .filter { $0.availability == .connected && viewModel.devices.freshness(for: $0) == .fresh }
            .compactMap(menuBarBattery)
        let player = viewModel.media.track.map {
            MenuBarPlayer(title: $0.title, subtitle: $0.artist, isPlaying: viewModel.media.isPlaying)
        }
        return MenuBarWorkspaceState(
            macBattery: macBattery,
            visibleDevices: devices,
            player: player,
            selectedDeviceIdentifier: settings.menuBarSelectedDevicePreferenceKey
        )
    }

    private func menuBarBattery(for snapshot: AppleDeviceSnapshot) -> MenuBarBattery? {
        let primary = snapshot.components.first { $0.kind == .primary && $0.percentage != nil }
        let lowest = snapshot.components
            .filter { $0.percentage != nil }
            .min { ($0.percentage ?? .max) < ($1.percentage ?? .max) }
        guard let component = primary ?? lowest else { return nil }
        return MenuBarBattery(
            identifier: snapshot.identity.localPreferenceKey,
            title: snapshot.displayName,
            percentage: component.percentage,
            state: .init(component.chargingState)
        )
    }

    private func updateStatusButton(_ item: NSStatusItem, content: MenuBarWorkspaceContent) {
        guard let button = item.button else { return }
        switch content {
        case .logo:
            item.length = NSStatusItem.squareLength
            button.image = statusIcon()
            button.title = ""
            button.toolTip = "Impuls"
        case .battery(let battery):
            item.length = NSStatusItem.variableLength
            button.image = statusIcon()
            let charging = battery.state == .charging || battery.state == .charged
            button.title = battery.percentage.map { charging ? " ⚡ \($0)%" : " \($0)%" } ?? ""
            button.toolTip = batteryDescription(battery)
        case .player(let player):
            item.length = NSStatusItem.variableLength
            button.image = statusIcon()
            button.title = player.isPlaying ? " ♪" : " ♫"
            button.toolTip = player.subtitle.isEmpty ? player.title : "\(player.title) — \(player.subtitle)"
        }
    }

    private func makeMenu(
        configuration: MenuBarWorkspaceConfiguration,
        state: MenuBarWorkspaceState
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let title = NSMenuItem(title: "Impuls \(Bundle.main.shortVersion)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        addWidget(configuration.primaryWidget, configuration: configuration, state: state, to: menu)
        if let secondary = configuration.secondaryWidget,
           secondary != configuration.primaryWidget {
            let primaryContent = MenuBarWorkspaceResolver.resolve(
                widget: configuration.primaryWidget,
                configuration: configuration,
                state: state
            )
            let secondaryContent = MenuBarWorkspaceResolver.resolve(
                widget: secondary,
                configuration: configuration,
                state: state
            )
            if secondaryContent != primaryContent || secondary == .quickActions {
                addWidget(secondary, configuration: configuration, state: state, to: menu)
            }
        }

        if exposesPlayer(configuration: configuration, state: state), canControlPlayer {
            menu.addItem(.separator())
            addPlayerControls(to: menu)
        }

        let enabledActions = configuration.quickActions.filter { action in
            guard let tab = action.tab else { return true }
            return settings.enabledTabs.contains(tab)
        }
        let quickActionsAreWidget = configuration.primaryWidget == .quickActions
            || configuration.secondaryWidget == .quickActions
        if !enabledActions.isEmpty && !quickActionsAreWidget {
            menu.addItem(.separator())
            addQuickActions(enabledActions, to: menu)
        }

        menu.addItem(.separator())
        menu.addItem(item(localized("Open Panel"), action: #selector(openPanel)))
        menu.addItem(item(localized("Settings…"), action: #selector(openSettings), keyEquivalent: ","))
        let updates = item(localized("Check for Updates…"), action: #selector(checkForUpdates))
        updates.isEnabled = updateService.canCheckForUpdates
        menu.addItem(updates)
        menu.addItem(item(localized("Send Feedback…"), action: #selector(openFeedback)))
        menu.addItem(item(localized("Quit"), action: #selector(quit), keyEquivalent: "q"))
        return menu
    }

    private func addWidget(
        _ widget: MenuBarWorkspaceWidget,
        configuration: MenuBarWorkspaceConfiguration,
        state: MenuBarWorkspaceState,
        to menu: NSMenu
    ) {
        guard widget != .none else { return }
        if widget == .quickActions {
            let enabledActions = configuration.quickActions.filter { action in
                guard let tab = action.tab else { return true }
                return settings.enabledTabs.contains(tab)
            }
            guard !enabledActions.isEmpty else { return }
            let title = NSMenuItem(title: localized("Quick Actions"), action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            addQuickActions(enabledActions, to: menu)
            return
        }
        let content = MenuBarWorkspaceResolver.resolve(widget: widget, configuration: configuration, state: state)
        let item: NSMenuItem
        switch content {
        case .battery(let battery):
            item = self.item(batteryDescription(battery), action: #selector(openPower))
            item.image = statusImage(named: batterySymbol(for: battery.percentage))
        case .player(let player):
            let description = player.subtitle.isEmpty ? player.title : "\(player.title) — \(player.subtitle)"
            item = self.item(description, action: #selector(openMusic))
            item.image = statusImage(named: player.isPlaying ? "pause.fill" : "music.note")
        case .logo:
            // The fixed footer owns the universal Open Panel command. A
            // missing provider should remove only its widget, not create a
            // second generic command above the footer.
            return
        }
        item.toolTip = widget.title
        menu.addItem(item)
    }

    private func addQuickActions(_ actions: [MenuBarQuickAction], to menu: NSMenu) {
        for action in actions { menu.addItem(quickActionItem(action)) }
    }

    private var canControlPlayer: Bool {
        guard let media = viewModel?.media, media.track != nil else { return false }
        return media.selectedSource == .appleMusic || media.webPlayerWasOpened
    }

    private func exposesPlayer(
        configuration: MenuBarWorkspaceConfiguration,
        state: MenuBarWorkspaceState
    ) -> Bool {
        let status = MenuBarWorkspaceResolver.resolve(
            mode: configuration.statusMode,
            configuration: configuration,
            state: state
        )
        let widgets = [configuration.primaryWidget, configuration.secondaryWidget].compactMap { $0 }
        let contents = [status] + widgets.map {
            MenuBarWorkspaceResolver.resolve(widget: $0, configuration: configuration, state: state)
        }
        return contents.contains { content in
            if case .player = content { return true }
            return false
        }
    }

    private func addPlayerControls(to menu: NSMenu) {
        guard let media = viewModel?.media else { return }
        let previous = item(localized("Previous Track"), action: #selector(previousTrack))
        previous.image = statusImage(named: "backward.fill")
        menu.addItem(previous)

        let playPause = item(media.isPlaying ? localized("Pause") : localized("Play"), action: #selector(togglePlayPause))
        playPause.image = statusImage(named: media.isPlaying ? "pause.fill" : "play.fill")
        menu.addItem(playPause)

        let next = item(localized("Next Track"), action: #selector(nextTrack))
        next.image = statusImage(named: "forward.fill")
        menu.addItem(next)
    }

    private func quickActionItem(_ action: MenuBarQuickAction) -> NSMenuItem {
        let item = self.item(action.title, action: #selector(performQuickAction(_:)))
        item.representedObject = action.rawValue
        item.image = statusImage(named: action.symbol)
        return item
    }

    private func item(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.isEnabled = true
        return item
    }

    @objc private func openPanel() { actions.openPanel() }
    @objc private func openSettings() { actions.openSettings() }
    @objc private func checkForUpdates() { actions.checkForUpdates() }
    @objc private func openFeedback() { actions.openFeedback() }
    @objc private func quit() { actions.quit() }
    @objc private func openMusic() { actions.openTab(.media) }
    @objc private func openPower() { actions.openTab(.power) }
    @objc private func previousTrack() { viewModel?.media.previous() }
    @objc private func togglePlayPause() { viewModel?.media.togglePlayPause() }
    @objc private func nextTrack() { viewModel?.media.next() }

    @objc private func performQuickAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = MenuBarQuickAction(rawValue: raw) else { return }
        if let tab = action.tab {
            actions.openTab(tab)
            return
        }
        switch action {
        case .openPanel:
            actions.openPanel()
        case .showScreenshots:
            actions.revealScreenshots()
        case .clearScreenshots:
            actions.clearScreenshots()
        default:
            return
        }
    }

    private func batteryDescription(_ battery: MenuBarBattery) -> String {
        var values = [battery.title]
        if let percentage = battery.percentage { values.append("\(percentage)%") }
        if let state = battery.state.title { values.append(state) }
        return values.joined(separator: " — ")
    }

    private func batterySymbol(for percentage: Int?) -> String {
        guard let percentage else { return "battery.0" }
        switch percentage {
        case 0...10: return "battery.0"
        case 11...35: return "battery.25"
        case 36...65: return "battery.50"
        case 66...90: return "battery.75"
        default: return "battery.100percent"
        }
    }

    private func statusImage(named name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private func statusIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "ImpulsStatusTemplate", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }
        return statusImage(named: "waveform.path.ecg")
    }
}
