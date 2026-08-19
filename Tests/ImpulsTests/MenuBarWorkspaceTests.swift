import XCTest
@testable import ImpulsCore

final class MenuBarWorkspaceTests: XCTestCase {
    func testAutomaticPrioritisesARealLowBatteryOverAnActivePlayer() {
        let configuration = MenuBarWorkspaceConfiguration(
            smartPriorities: [.lowBattery, .activePlayer, .neutral],
            lowBatteryThreshold: 20
        )
        let state = MenuBarWorkspaceState(
            macBattery: battery("mac", "This Mac", 72, .discharging),
            visibleDevices: [battery("airpods", "AirPods", 18, .unknown)],
            player: MenuBarPlayer(title: "Track", subtitle: "Artist", isPlaying: true)
        )

        XCTAssertEqual(
            MenuBarWorkspaceResolver.resolve(mode: .automatic, configuration: configuration, state: state),
            .battery(battery("airpods", "AirPods", 18, .unknown))
        )
    }

    func testAutomaticDoesNotPretendAnUnknownBatteryIsLow() {
        let configuration = MenuBarWorkspaceConfiguration(
            smartPriorities: [.lowBattery, .activePlayer, .neutral],
            lowBatteryThreshold: 20
        )
        let state = MenuBarWorkspaceState(
            visibleDevices: [battery("device", "Device", nil, .unknown)],
            player: MenuBarPlayer(title: "Track", subtitle: "Artist", isPlaying: true)
        )

        XCTAssertEqual(
            MenuBarWorkspaceResolver.resolve(mode: .automatic, configuration: configuration, state: state),
            .player(MenuBarPlayer(title: "Track", subtitle: "Artist", isPlaying: true))
        )
    }

    func testSelectedDeviceFallsBackToMacThenLogo() {
        let configuration = MenuBarWorkspaceConfiguration()
        let mac = battery("mac", "This Mac", 81, .charging)
        XCTAssertEqual(
            MenuBarWorkspaceResolver.resolve(
                mode: .selectedDevice,
                configuration: configuration,
                state: .init(macBattery: mac, selectedDeviceIdentifier: "missing")
            ),
            .battery(mac)
        )
        XCTAssertEqual(
            MenuBarWorkspaceResolver.resolve(
                mode: .selectedDevice,
                configuration: configuration,
                state: .init(selectedDeviceIdentifier: "missing")
            ),
            .logo
        )
    }

    func testWorkspaceNormalizesDuplicateWidgetsActionsAndPriorities() {
        var configuration = MenuBarWorkspaceConfiguration(
            primaryWidget: .player,
            secondaryWidget: .player,
            quickActions: [.actions, .actions, .media, .power, .notes],
            smartPriorities: [.activePlayer, .activePlayer]
        )
        configuration.normalize()

        XCTAssertNil(configuration.secondaryWidget)
        XCTAssertEqual(configuration.quickActions, [.actions, .media, .power, .notes])
        XCTAssertEqual(configuration.smartPriorities, [.activePlayer, .lowBattery, .charging, .neutral])
    }

    func testPresetsSetBoundedStartingChoicesAndCustomKeepsManualChoice() {
        var configuration = MenuBarWorkspaceConfiguration()
        configuration.applyPreset(.work)
        XCTAssertEqual(configuration.preset, .work)
        XCTAssertEqual(configuration.quickActions, [.actions, .calendar, .clipboard, .notes])
        XCTAssertEqual(configuration.primaryWidget, .player)

        configuration.applyPreset(.custom)
        XCTAssertEqual(configuration.preset, .custom)
        XCTAssertEqual(configuration.quickActions, [.actions, .calendar, .clipboard, .notes])
    }

    func testUnavailablePlayerFallsBackToMacThenLogo() {
        let configuration = MenuBarWorkspaceConfiguration()
        let mac = battery("mac", "This Mac", 63, .discharging)
        XCTAssertEqual(
            MenuBarWorkspaceResolver.resolve(
                mode: .player,
                configuration: configuration,
                state: .init(macBattery: mac)
            ),
            .battery(mac)
        )
        XCTAssertEqual(
            MenuBarWorkspaceResolver.resolve(mode: .player, configuration: configuration, state: .init()),
            .logo
        )
    }

    func testAutomaticUsesChargingWhenNoLowBatteryOrActivePlayerExists() {
        let configuration = MenuBarWorkspaceConfiguration(
            smartPriorities: [.lowBattery, .activePlayer, .charging, .neutral]
        )
        let mac = battery("mac", "This Mac", 72, .charging)
        XCTAssertEqual(
            MenuBarWorkspaceResolver.resolve(
                mode: .automatic,
                configuration: configuration,
                state: .init(macBattery: mac)
            ),
            .battery(mac)
        )
    }

    func testUnknownActionAndWidgetIDsAreIgnoredWithoutLosingOtherChoices() throws {
        let json = #"""
        {
          "preset": "custom",
          "statusMode": "lowestBattery",
          "primaryWidget": "lowestBattery",
          "secondaryWidget": "removedWidget",
          "quickActions": ["power", "removedAction", "actions"],
          "smartPriorities": ["activePlayer", "removedPriority"],
          "lowBatteryThreshold": 15
        }
        """#
        let configuration = try JSONDecoder().decode(MenuBarWorkspaceConfiguration.self, from: Data(json.utf8))

        XCTAssertEqual(configuration.statusMode, .lowestBattery)
        XCTAssertEqual(configuration.primaryWidget, .lowestBattery)
        XCTAssertNil(configuration.secondaryWidget)
        XCTAssertEqual(configuration.quickActions, [.power, .actions])
        XCTAssertEqual(configuration.lowBatteryThreshold, 15)
    }

    func testOnboardingShowsOnlyWhatsNewForAnExistingInstall() {
        XCTAssertEqual(
            OnboardingEligibility.decision(
                hasSettingsSnapshot: true,
                completedLegacyTour: true,
                completedCurrentTour: false,
                seenVersion: "1.4.10",
                currentVersion: "1.4.11"
            ),
            .whatsNew
        )
        XCTAssertEqual(
            OnboardingEligibility.decision(
                hasSettingsSnapshot: true,
                completedLegacyTour: true,
                completedCurrentTour: false,
                seenVersion: "1.4.11",
                currentVersion: "1.4.11"
            ),
            .none
        )
    }

    func testOnboardingShowsFullTourOnlyForFreshInstall() {
        XCTAssertEqual(
            OnboardingEligibility.decision(
                hasSettingsSnapshot: false,
                completedLegacyTour: false,
                completedCurrentTour: false,
                seenVersion: nil,
                currentVersion: "1.4.11"
            ),
            .full
        )
        XCTAssertEqual(
            OnboardingEligibility.decision(
                hasSettingsSnapshot: false,
                completedLegacyTour: false,
                completedCurrentTour: true,
                seenVersion: "1.4.11",
                currentVersion: "1.4.11"
            ),
            .none
        )
    }

    func testTelemetryOfferIsOneTimeAndNeverOverridesExistingConsent() {
        XCTAssertTrue(OnboardingTelemetryOfferEligibility.shouldShow(
            presentation: .full,
            consent: .unknown,
            offerWasShown: false
        ))
        XCTAssertTrue(OnboardingTelemetryOfferEligibility.shouldShow(
            presentation: .whatsNew,
            consent: .unknown,
            offerWasShown: false
        ))
        XCTAssertFalse(OnboardingTelemetryOfferEligibility.shouldShow(
            presentation: .whatsNew,
            consent: .unknown,
            offerWasShown: true
        ))
        XCTAssertFalse(OnboardingTelemetryOfferEligibility.shouldShow(
            presentation: .whatsNew,
            consent: .allowed,
            offerWasShown: false
        ))
        XCTAssertFalse(OnboardingTelemetryOfferEligibility.shouldShow(
            presentation: .whatsNew,
            consent: .denied,
            offerWasShown: false
        ))
    }

    func testWorkspaceChoicesSurviveBackupEncoding() throws {
        let workspace = MenuBarWorkspaceConfiguration(
            preset: .custom,
            statusMode: .lowestBattery,
            primaryWidget: .lowestBattery,
            secondaryWidget: .player,
            quickActions: [.power, .actions],
            smartPriorities: [.activePlayer, .lowBattery, .neutral, .charging],
            lowBatteryThreshold: 15
        )
        let settings = ImpulsSettingsSnapshot(
            hotKey: .optionSpace,
            activationMode: .hoverAndShortcut,
            openDelay: .short,
            panelSize: .standard,
            selectedDisplayID: nil,
            modules: NotchViewModel.Tab.allCases.map { ModulePreference(tab: $0, isEnabled: true) },
            saveClipboardImages: true,
            menuBarWorkspace: workspace
        )
        let document = ImpulsBackupDocument(settings: settings, snippets: [], notes: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)

        XCTAssertEqual(try ImpulsBackupDocument.decode(data).settings.menuBarWorkspace, workspace)
    }

    func testOlderSettingsDecodeToSafeMenuBarDefaults() throws {
        let json = """
        {
          "hotKey": "optionSpace",
          "activationMode": "hoverAndShortcut",
          "openDelay": "short",
          "panelSize": "standard",
          "modules": [{"tab": "actions", "isEnabled": true}],
          "saveClipboardImages": true
        }
        """

        let snapshot = try JSONDecoder().decode(ImpulsSettingsSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.menuBarWorkspace.statusMode, .automatic)
        XCTAssertEqual(snapshot.menuBarWorkspace.primaryWidget, .automatic)
        XCTAssertFalse(snapshot.menuBarWorkspace.quickActions.isEmpty)
    }

    func testCorruptLocalSelectedDeviceKeyFallsBackToNil() async {
        await MainActor.run {
            let suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(
                Data(#"{"selectedDeviceKey":"not-an-opaque-device-key"}"#.utf8),
                forKey: SettingsStore.menuBarWorkspacePreferencesKey
            )

            XCTAssertNil(SettingsStore(defaults: defaults).menuBarSelectedDevicePreferenceKey)
        }
    }

    private func battery(
        _ identifier: String,
        _ title: String,
        _ percentage: Int?,
        _ state: MenuBarBattery.State
    ) -> MenuBarBattery {
        MenuBarBattery(identifier: identifier, title: title, percentage: percentage, state: state)
    }
}
