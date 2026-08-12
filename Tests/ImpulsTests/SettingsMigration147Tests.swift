import XCTest
@testable import ImpulsCore

/// Upgrading from 1.4.6 to 1.4.7 must cost the user nothing.
///
/// 1.4.7 adds a fourth panel preset and changes what an absent
/// `selectedDisplayID` means. Both live inside `settings.v1`, which every
/// release since 1.4.0 has written, so the blob on a real machine carries the
/// Apple-device switch, the clipboard policy and the module order from 1.4.6
/// alongside them. None of that may be disturbed — least of all the parts the
/// 1.4.6 power work depends on.
final class SettingsMigration147Tests: XCTestCase {

    /// Exactly what 1.4.6 writes: every key it knows, and none it does not.
    private let settingsFrom146 = """
    {
      "hotKey": "commandShiftSpace",
      "activationMode": "hoverAndShortcut",
      "openDelay": "balanced",
      "panelSize": "large",
      "modules": [
        {"tab": "actions", "isEnabled": true},
        {"tab": "power", "isEnabled": true},
        {"tab": "media", "isEnabled": false},
        {"tab": "clipboard", "isEnabled": true}
      ],
      "saveClipboardImages": false,
      "persistClipboardHistory": true,
      "clipboardRetention": "thirtyDays",
      "excludedClipboardBundleIdentifiers": ["com.example.passwords"],
      "showsExternalAppleDevices": true
    }
    """

    func testEveryFieldA146InstallCarriesSurvivesTheUpgrade() throws {
        let decoded = try JSONDecoder().decode(ImpulsSettingsSnapshot.self, from: Data(settingsFrom146.utf8))

        XCTAssertEqual(decoded.hotKey, .commandShiftSpace)
        XCTAssertEqual(decoded.activationMode, .hoverAndShortcut)
        XCTAssertEqual(decoded.openDelay, .balanced)
        XCTAssertEqual(decoded.panelSize, .large, "a chosen preset is never silently swapped for Automatic")
        XCTAssertFalse(decoded.saveClipboardImages)
        XCTAssertTrue(decoded.persistClipboardHistory)
        XCTAssertEqual(decoded.clipboardRetention, .thirtyDays)
        XCTAssertEqual(decoded.excludedClipboardBundleIdentifiers, ["com.example.passwords"])
        // The 1.4.6 opt-in. Losing it would either silently disable the device
        // centre or, far worse, silently enable it.
        XCTAssertTrue(decoded.showsExternalAppleDevices)
    }

    func testTheModuleOrderAndThePowerModuleAreUnchanged() async throws {
        try await MainActor.run {
            let decoded = try JSONDecoder().decode(ImpulsSettingsSnapshot.self, from: Data(settingsFrom146.utf8))
            let normalized = SettingsStore.normalizedModules(decoded.modules)

            // The four the user had keep their order and their state, and the
            // five they had not seen yet are appended enabled.
            XCTAssertEqual(Array(normalized.prefix(4).map(\.tab)), [.actions, .power, .media, .clipboard])
            XCTAssertEqual(Array(normalized.prefix(4).map(\.isEnabled)), [true, true, false, true])
            XCTAssertEqual(Set(normalized.map(\.tab)), Set(NotchViewModel.Tab.allCases))
            XCTAssertTrue(
                normalized.contains(ModulePreference(tab: .power, isEnabled: true)),
                ".power stays the module identifier settings and backups depend on"
            )
        }
    }

    func testAnAbsentDisplayChoiceNowMeansEveryDisplayRatherThanTheNotchedOne() throws {
        let decoded = try JSONDecoder().decode(ImpulsSettingsSnapshot.self, from: Data(settingsFrom146.utf8))

        XCTAssertNil(decoded.selectedDisplayID, "1.4.6 never wrote one unless the user picked a display")
        XCTAssertEqual(
            DisplayPreference(selectedDisplayID: decoded.selectedDisplayID),
            .allDisplays,
            "which is the whole fix for #34: Impuls is available everywhere by default"
        )
    }

    func testADisplayChosenIn146IsStillHonouredIn147() throws {
        let json = settingsFrom146.replacingOccurrences(
            of: "\"panelSize\": \"large\",",
            with: "\"panelSize\": \"large\",\n  \"selectedDisplayID\": 69733382,"
        )

        let decoded = try JSONDecoder().decode(ImpulsSettingsSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.selectedDisplayID, 69_733_382)
        XCTAssertEqual(DisplayPreference(selectedDisplayID: decoded.selectedDisplayID), .single(69_733_382))
    }

    /// The end-to-end path: a 1.4.6 blob already on disk, opened by 1.4.7,
    /// changed the way the release notes suggest, and read back.
    func testA146InstallUpgradesInPlaceWithoutLosingTheDeviceLayerState() async throws {
        try await MainActor.run {
            let suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }

            // What 1.4.6 left behind: the settings blob, the local per-device
            // presentation keys, and the notification consent.
            defaults.set(Data(settingsFrom146.utf8), forKey: SettingsStore.storageKey)
            let deviceKeys = [String(repeating: "a", count: 32), String(repeating: "b", count: 32)]
            defaults.set(
                try JSONEncoder().encode(["order": deviceKeys, "hidden": [deviceKeys[1]]]),
                forKey: SettingsStore.appleDevicePreferencesKey
            )
            defaults.set(true, forKey: SettingsStore.lowBatteryAlertsEnabledKey)

            let upgraded = SettingsStore(defaults: defaults)
            upgraded.displaySource = { [] }

            // 1.4.6 state, intact.
            XCTAssertTrue(upgraded.showsExternalAppleDevices)
            XCTAssertTrue(upgraded.lowBatteryAlertsEnabled)
            XCTAssertEqual(upgraded.appleDevicePreferenceOrder, deviceKeys)
            XCTAssertEqual(upgraded.hiddenAppleDevicePreferenceKeys, [deviceKeys[1]])
            XCTAssertTrue(upgraded.isPowerModuleEnabled)
            XCTAssertEqual(upgraded.clipboardRetention, .thirtyDays)
            XCTAssertEqual(upgraded.panelSize, .large)

            // 1.4.7 defaults on top of it.
            XCTAssertEqual(upgraded.displayPreference, .allDisplays)

            // The user then adopts the new settings.
            upgraded.panelSize = .automatic
            upgraded.selectedDisplayID = nil

            let relaunched = SettingsStore(defaults: defaults)
            relaunched.displaySource = { [] }
            XCTAssertEqual(relaunched.panelSize, .automatic)
            XCTAssertEqual(relaunched.displayPreference, .allDisplays)
            // And nothing from 1.4.6 was traded away for it.
            XCTAssertTrue(relaunched.showsExternalAppleDevices)
            XCTAssertTrue(relaunched.lowBatteryAlertsEnabled)
            XCTAssertEqual(relaunched.appleDevicePreferenceOrder, deviceKeys)
            XCTAssertEqual(relaunched.clipboardRetention, .thirtyDays)
            XCTAssertEqual(relaunched.excludedClipboardBundleIdentifiers, ["com.example.passwords"])
        }
    }

    /// A 1.4.6 backup file restored into 1.4.7. The snapshot is the same type
    /// the settings blob uses, so the same guarantees have to hold through
    /// `apply`, which is the path `restore(_:)` takes.
    func testA146BackupRestoresIntoA147InstallUnchanged() async throws {
        try await MainActor.run {
            let suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }

            let settings = SettingsStore(defaults: defaults)
            settings.displaySource = { [] }
            let restored = try JSONDecoder().decode(
                ImpulsSettingsSnapshot.self,
                from: Data(settingsFrom146.utf8)
            )

            settings.apply(restored)

            XCTAssertEqual(settings.panelSize, .large)
            XCTAssertEqual(settings.hotKey, .commandShiftSpace)
            XCTAssertTrue(settings.showsExternalAppleDevices)
            XCTAssertTrue(settings.persistClipboardHistory)
            XCTAssertEqual(settings.displayPreference, .allDisplays)
            XCTAssertEqual(settings.enabledTabs.first, .actions)
            XCTAssertTrue(settings.enabledTabs.contains(.power))
        }
    }

    /// The reverse direction is not supported, but it must not be destructive:
    /// 1.4.6 reading a 1.4.7 blob does not understand `automatic`. The tolerant
    /// decode added in 1.4.7 is what keeps a stray preset from taking the rest
    /// of the settings down with it.
    func testAnUnknownPresetCostsThePresetAndNothingElse() throws {
        let json = settingsFrom146.replacingOccurrences(
            of: "\"panelSize\": \"large\"",
            with: "\"panelSize\": \"automatic-plus-something-newer\""
        )

        let decoded = try JSONDecoder().decode(ImpulsSettingsSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.panelSize, .standard)
        XCTAssertTrue(decoded.showsExternalAppleDevices)
        XCTAssertEqual(decoded.clipboardRetention, .thirtyDays)
        XCTAssertEqual(decoded.hotKey, .commandShiftSpace)
    }

    /// A stale display identifier — the monitor it named is not plugged in —
    /// falls back to every display rather than to none.
    func testAChosenDisplayThatIsGoneFallsBackToAllDisplays() async {
        await MainActor.run {
            let suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }

            let settings = SettingsStore(defaults: defaults)
            settings.displaySource = {
                [DisplayFixtures.plain(id: 7, origin: .zero, size: CGSize(width: 1920, height: 1080), isPrimary: true)]
            }
            settings.selectedDisplayID = 404
            settings.refreshDisplays()

            XCTAssertNil(settings.selectedDisplayID)
            XCTAssertEqual(settings.displayPreference, .allDisplays)
            XCTAssertEqual(settings.displays.map(\.id), [7])
        }
    }
}
