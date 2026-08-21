import AppKit
import Combine

struct ModulePreference: Codable, Equatable, Identifiable {
    let tab: NotchViewModel.Tab
    var isEnabled: Bool

    var id: NotchViewModel.Tab { tab }
}

struct ImpulsSettingsSnapshot: Codable, Equatable {
    var hotKey: SettingsStore.HotKeyPreset
    var activationMode: SettingsStore.ActivationMode
    var openDelay: SettingsStore.OpenDelay
    var panelSize: SettingsStore.PanelSize
    var selectedDisplayID: UInt32?
    var modules: [ModulePreference]
    var saveClipboardImages: Bool
    var persistClipboardHistory: Bool
    var clipboardRetention: SettingsStore.ClipboardRetention
    var excludedClipboardBundleIdentifiers: [String]
    /// Whether Impuls may look for the user's other Apple devices.
    ///
    /// A preference and nothing more: no identifier, no device list, no last
    /// known charge. That keeps it safe to carry in an exported backup, which
    /// is why it lives here rather than in a device cache.
    var showsExternalAppleDevices: Bool
    /// Generic Menu Bar choices remain useful after a backup is restored on a
    /// second Mac. A selected physical-device key stays local-only below.
    var menuBarWorkspace: MenuBarWorkspaceConfiguration

    init(
        hotKey: SettingsStore.HotKeyPreset,
        activationMode: SettingsStore.ActivationMode,
        openDelay: SettingsStore.OpenDelay,
        panelSize: SettingsStore.PanelSize,
        selectedDisplayID: UInt32?,
        modules: [ModulePreference],
        saveClipboardImages: Bool,
        persistClipboardHistory: Bool = false,
        clipboardRetention: SettingsStore.ClipboardRetention = .sevenDays,
        excludedClipboardBundleIdentifiers: [String] = [],
        showsExternalAppleDevices: Bool = false,
        menuBarWorkspace: MenuBarWorkspaceConfiguration = .init()
    ) {
        self.hotKey = hotKey
        self.activationMode = activationMode
        self.openDelay = openDelay
        self.panelSize = panelSize
        self.selectedDisplayID = selectedDisplayID
        self.modules = modules
        self.saveClipboardImages = saveClipboardImages
        self.persistClipboardHistory = persistClipboardHistory
        self.clipboardRetention = clipboardRetention
        self.excludedClipboardBundleIdentifiers = excludedClipboardBundleIdentifiers
        self.showsExternalAppleDevices = showsExternalAppleDevices
        self.menuBarWorkspace = MenuBarWorkspaceConfiguration.normalized(menuBarWorkspace)
    }

    private enum CodingKeys: String, CodingKey {
        case hotKey, activationMode, openDelay, panelSize, selectedDisplayID, modules
        case saveClipboardImages, persistClipboardHistory, clipboardRetention
        case excludedClipboardBundleIdentifiers, showsExternalAppleDevices, menuBarWorkspace
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotKey = try container.decode(SettingsStore.HotKeyPreset.self, forKey: .hotKey)
        activationMode = try container.decode(SettingsStore.ActivationMode.self, forKey: .activationMode)
        openDelay = try container.decode(SettingsStore.OpenDelay.self, forKey: .openDelay)
        // Tolerant on purpose. A preset this build does not know — a blob
        // written by a newer version, or one that was truncated — must cost the
        // user their panel size and nothing else. Decoding it strictly would
        // fail the whole snapshot and silently reset every other setting.
        panelSize = (try? container.decode(SettingsStore.PanelSize.self, forKey: .panelSize)) ?? .standard
        selectedDisplayID = try container.decodeIfPresent(UInt32.self, forKey: .selectedDisplayID)
        modules = try container.decode([ModulePreference].self, forKey: .modules)
        saveClipboardImages = try container.decodeIfPresent(Bool.self, forKey: .saveClipboardImages) ?? true
        persistClipboardHistory = try container.decodeIfPresent(Bool.self, forKey: .persistClipboardHistory) ?? false
        clipboardRetention = try container.decodeIfPresent(
            SettingsStore.ClipboardRetention.self,
            forKey: .clipboardRetention
        ) ?? .sevenDays
        excludedClipboardBundleIdentifiers = try container.decodeIfPresent(
            [String].self,
            forKey: .excludedClipboardBundleIdentifiers
        ) ?? []
        // Absent in every settings blob and backup written before 1.4.6, and
        // `false` is the only defensible default: a new release must not start
        // looking at the user's devices because they installed an update.
        showsExternalAppleDevices = try container.decodeIfPresent(
            Bool.self,
            forKey: .showsExternalAppleDevices
        ) ?? false
        menuBarWorkspace = MenuBarWorkspaceConfiguration.normalized(
            try? container.decodeIfPresent(MenuBarWorkspaceConfiguration.self, forKey: .menuBarWorkspace)
        )
    }
}

/// Per-device choices that belong only to this Mac.
///
/// The keys are HMAC-derived by `AppleDeviceIdentity`; they are not raw
/// identifiers, but they still do not belong in an exported backup. This blob
/// therefore has its own UserDefaults key and is never part of
/// `ImpulsSettingsSnapshot`.
private struct AppleDeviceLocalPreferences: Codable, Equatable {
    var order: [String]
    var hidden: [String]
}

/// This opaque identity is derived from a local Keychain secret. It is useful
/// only on this Mac, so it must not travel in an exported backup.
private struct MenuBarWorkspaceLocalPreferences: Codable, Equatable {
    var selectedDeviceKey: String?
}

@MainActor
final class SettingsStore: ObservableObject {
    enum HotKeyPreset: String, CaseIterable, Codable, Identifiable {
        case optionSpace
        case controlSpace
        case optionShiftSpace
        case commandShiftSpace
        case disabled

        var id: String { rawValue }

        var title: String {
            switch self {
            case .optionSpace: return "⌥ Space"
            case .controlSpace: return "⌃ Space"
            case .optionShiftSpace: return "⌥⇧ Space"
            case .commandShiftSpace: return "⌘⇧ Space"
            case .disabled: return localized("Disabled")
            }
        }
    }

    enum ActivationMode: String, CaseIterable, Codable, Identifiable {
        case hoverAndShortcut
        case shortcutOnly

        var id: String { rawValue }
        var title: String {
            switch self {
            case .hoverAndShortcut: return localized("Hover and keyboard shortcut")
            case .shortcutOnly: return localized("Keyboard shortcut only")
            }
        }
    }

    enum OpenDelay: String, CaseIterable, Codable, Identifiable {
        case immediate, short, balanced, deliberate

        var id: String { rawValue }
        var seconds: TimeInterval {
            switch self {
            case .immediate: return 0
            case .short: return 0.05
            case .balanced: return 0.15
            case .deliberate: return 0.30
            }
        }
        var title: String {
            switch self {
            case .immediate: return localized("Immediately")
            case .short: return localized("Fast — 0.05 s")
            case .balanced: return localized("Balanced — 0.15 s")
            case .deliberate: return localized("Deliberate — 0.30 s")
            }
        }
    }

    enum PanelSize: String, CaseIterable, Codable, Identifiable {
        /// The preset is chosen from the display the panel opens on. Listed
        /// first because it is the right answer for anyone with more than one
        /// display, and the three fixed presets remain for anyone who has
        /// already decided.
        case automatic
        case compact, standard, large

        var id: String { rawValue }

        /// The size this preset always means, or `nil` when it depends on the
        /// display.
        var fixedExpandedSize: CGSize? {
            switch self {
            case .automatic: return nil
            case .compact: return AdaptivePanelLayout.compact
            case .standard: return AdaptivePanelLayout.standard
            case .large: return AdaptivePanelLayout.large
            }
        }

        /// The size to ask for on a given display. `NotchGeometry` still clamps
        /// the answer to what that display can actually show, for the fixed
        /// presets as much as for Automatic.
        func expandedSize(for display: DisplayDescriptor) -> CGSize {
            fixedExpandedSize ?? AdaptivePanelLayout.expandedSize(forDisplayWidth: display.frame.width)
        }

        var title: String {
            switch self {
            case .automatic: return localized("Automatic")
            case .compact: return localized("Compact")
            case .standard: return localized("Standard")
            case .large: return localized("Large")
            }
        }
    }

    enum ClipboardRetention: String, CaseIterable, Codable, Identifiable {
        case oneHour
        case oneDay
        case sevenDays
        case thirtyDays

        var id: String { rawValue }

        var timeInterval: TimeInterval {
            switch self {
            case .oneHour: return 60 * 60
            case .oneDay: return 24 * 60 * 60
            case .sevenDays: return 7 * 24 * 60 * 60
            case .thirtyDays: return 30 * 24 * 60 * 60
            }
        }

        var title: String {
            switch self {
            case .oneHour: return localized("1 Hour")
            case .oneDay: return localized("1 Day")
            case .sevenDays: return localized("7 Days")
            case .thirtyDays: return localized("30 Days")
            }
        }
    }

    struct DisplayOption: Identifiable, Equatable {
        let id: UInt32
        let name: String
    }

    static let storageKey = "settings.v1"
    static let saveClipboardImagesKey = "saveClipboardImages"
    static let appleDevicePreferencesKey = "appleDevices.presentation.v1"
    static let lowBatteryAlertsEnabledKey = "appleDevices.lowBatteryAlerts.enabled"
    static let menuBarWorkspacePreferencesKey = "menuBarWorkspace.presentation.v1"
    static let maximumRememberedAppleDevices = 100

    @Published var hotKey: HotKeyPreset { didSet { persist() } }
    @Published var activationMode: ActivationMode { didSet { persist() } }
    @Published var openDelay: OpenDelay { didSet { persist() } }
    @Published var panelSize: PanelSize { didSet { persist() } }
    /// `nil` means every display. Before 1.4.7 it meant "let Impuls choose",
    /// and what it chose was always the display with the physical notch — which
    /// is why Impuls was missing from external monitors entirely. The stored
    /// value is unchanged, so a settings blob or backup from any earlier
    /// version keeps decoding; only what `nil` means has moved on.
    @Published var selectedDisplayID: UInt32? { didSet { persist() } }
    @Published private(set) var modules: [ModulePreference] { didSet { persist() } }
    @Published var saveClipboardImages: Bool { didSet { persist() } }
    @Published var persistClipboardHistory: Bool { didSet { persist() } }
    @Published var clipboardRetention: ClipboardRetention { didSet { persist() } }
    @Published private(set) var excludedClipboardBundleIdentifiers: [String] { didSet { persist() } }
    @Published var showsExternalAppleDevices: Bool { didSet { persist() } }
    @Published private(set) var menuBarWorkspace: MenuBarWorkspaceConfiguration { didSet { persist() } }
    /// Notification consent belongs to this Mac, like the macOS authorization
    /// it controls. It persists locally but never travels in a backup.
    @Published var lowBatteryAlertsEnabled: Bool {
        didSet { defaults.set(lowBatteryAlertsEnabled, forKey: Self.lowBatteryAlertsEnabledKey) }
    }
    /// Runtime device data for Settings. It is never encoded or copied to a
    /// backup; only the local presentation keys below survive a relaunch.
    @Published private(set) var knownExternalAppleDevices: [AppleDeviceSnapshot]
    @Published private(set) var appleDeviceDiagnostics: [DeviceProviderDiagnostic]
    @Published private(set) var appleDevicePreferenceOrder: [String]
    @Published private(set) var hiddenAppleDevicePreferenceKeys: Set<String>
    /// An HMAC-derived key for one local device, never written to a backup or
    /// exposed in UI/accessibility text.
    @Published private(set) var menuBarSelectedDevicePreferenceKey: String?
    @Published private(set) var displays: [DisplayOption] = []
    @Published private(set) var hotKeyError: String?
    /// Runtime-only presentation state. It intentionally is not persisted: the
    /// same backup can be restored on a MacBook or a desktop Mac.
    @Published private(set) var powerDeviceKind: PowerDeviceKind?

    /// Where this Impuls keeps its preferences. Internal rather than private
    /// so the stores that persist beside them — the shelf's card list — write
    /// to the same place. The app uses `.standard`; a test uses its own suite,
    /// and nothing it does can then reach the user's real data.
    let defaults: UserDefaults
    /// The connected displays, as the panel layer sees them. Injected so the
    /// picker's own behaviour — mirrors folded together, a stale choice
    /// cleared — can be exercised without the hardware.
    var displaySource: () -> [DisplayDescriptor] = { ScreenDisplaySource.descriptors() }
    private let lowBatteryAlertsOverride: LowBatteryAlertService?
    /// Lazy so command-line unit tests that exercise unrelated Settings logic
    /// never instantiate macOS Notification Center outside an application.
    lazy var lowBatteryAlerts: LowBatteryAlertService =
        lowBatteryAlertsOverride ?? LowBatteryAlertService(defaults: defaults)
    /// Held by composition, not copied. The interface language has exactly one
    /// owner — see `AppLanguageService` — and a `@Published` mirror here would be
    /// a second source of truth for the same preference. Settings only forwards
    /// this to the picker.
    let appLanguage: AppLanguageService
    private var isApplying = false
    private var currentAppleDevicePreferenceKeys = Set<String>()
    private var refreshExternalAppleDevicesAction: (() -> Void)?
    private var configureLowBatteryAlertsAction: ((Bool, Bool) -> Void)?

    init(defaults: UserDefaults = .standard, lowBatteryAlerts: LowBatteryAlertService? = nil) {
        self.defaults = defaults
        lowBatteryAlertsOverride = lowBatteryAlerts
        appLanguage = AppLanguageService(defaults: defaults)
        let fallback = Self.defaultSnapshot(defaults: defaults)
        let stored = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(ImpulsSettingsSnapshot.self, from: $0) }
        let snapshot = stored ?? fallback
        hotKey = snapshot.hotKey
        activationMode = snapshot.activationMode
        openDelay = snapshot.openDelay
        panelSize = snapshot.panelSize
        selectedDisplayID = snapshot.selectedDisplayID
        modules = Self.normalizedModules(snapshot.modules)
        saveClipboardImages = snapshot.saveClipboardImages
        persistClipboardHistory = snapshot.persistClipboardHistory
        clipboardRetention = snapshot.clipboardRetention
        excludedClipboardBundleIdentifiers = Self.normalizedBundleIdentifiers(
            snapshot.excludedClipboardBundleIdentifiers
        )
        showsExternalAppleDevices = snapshot.showsExternalAppleDevices
        menuBarWorkspace = MenuBarWorkspaceConfiguration.normalized(snapshot.menuBarWorkspace)
        lowBatteryAlertsEnabled = defaults.bool(forKey: Self.lowBatteryAlertsEnabledKey)
        let localPreferences = Self.loadAppleDevicePreferences(defaults: defaults)
        appleDevicePreferenceOrder = localPreferences.order
        hiddenAppleDevicePreferenceKeys = Set(localPreferences.hidden)
        menuBarSelectedDevicePreferenceKey = Self.loadMenuBarWorkspacePreferences(defaults: defaults).selectedDeviceKey
        knownExternalAppleDevices = []
        appleDeviceDiagnostics = []
        hotKeyError = nil
        powerDeviceKind = nil
        refreshDisplays()
    }

    var snapshot: ImpulsSettingsSnapshot {
        ImpulsSettingsSnapshot(
            hotKey: hotKey,
            activationMode: activationMode,
            openDelay: openDelay,
            panelSize: panelSize,
            selectedDisplayID: selectedDisplayID,
            modules: modules,
            saveClipboardImages: saveClipboardImages,
            persistClipboardHistory: persistClipboardHistory,
            clipboardRetention: clipboardRetention,
            excludedClipboardBundleIdentifiers: excludedClipboardBundleIdentifiers,
            showsExternalAppleDevices: showsExternalAppleDevices,
            menuBarWorkspace: menuBarWorkspace
        )
    }

    var enabledTabs: [NotchViewModel.Tab] {
        modules.compactMap { $0.isEnabled ? $0.tab : nil }
    }

    var isPowerModuleEnabled: Bool { enabledTabs.contains(.power) }

    func setModule(_ tab: NotchViewModel.Tab, enabled: Bool) {
        guard let index = modules.firstIndex(where: { $0.tab == tab }) else { return }
        if !enabled, modules[index].isEnabled, enabledTabs.count == 1 { return }
        modules[index].isEnabled = enabled
    }

    func moveModule(_ tab: NotchViewModel.Tab, offset: Int) {
        guard let source = modules.firstIndex(where: { $0.tab == tab }) else { return }
        let destination = source + offset
        guard modules.indices.contains(destination) else { return }
        modules.swapAt(source, destination)
    }

    func setPowerDeviceKind(_ kind: PowerDeviceKind) {
        guard powerDeviceKind != kind else { return }
        powerDeviceKind = kind
    }

    func moduleTitle(for tab: NotchViewModel.Tab) -> String {
        guard tab == .power else { return tab.title }
        return powerDeviceKind == .portable ? localized("Battery") : localized("Power")
    }

    func moduleSymbol(for tab: NotchViewModel.Tab) -> String {
        guard tab == .power else { return tab.symbol }
        return powerDeviceKind == .portable ? "battery.100percent" : "bolt.fill"
    }

    func excludeClipboardApp(bundleIdentifier: String) {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidBundleIdentifier(identifier),
              identifier != Bundle.main.bundleIdentifier,
              !excludedClipboardBundleIdentifiers.contains(identifier),
              excludedClipboardBundleIdentifiers.count < 50 else { return }
        excludedClipboardBundleIdentifiers.append(identifier)
        excludedClipboardBundleIdentifiers.sort()
    }

    func includeClipboardApp(bundleIdentifier: String) {
        excludedClipboardBundleIdentifiers.removeAll { $0 == bundleIdentifier }
    }

    // MARK: - Menu Bar workspace

    func updateMenuBarWorkspace(_ update: (inout MenuBarWorkspaceConfiguration) -> Void) {
        var next = menuBarWorkspace
        update(&next)
        next.normalize()
        guard next != menuBarWorkspace else { return }
        menuBarWorkspace = next
    }

    func applyMenuBarWorkspacePreset(_ preset: MenuBarWorkspacePreset) {
        updateMenuBarWorkspace { $0.applyPreset(preset) }
    }

    func setMenuBarSelectedDevice(_ device: AppleDeviceSnapshot?) {
        let candidate = device.flatMap { snapshot -> String? in
            guard !snapshot.identity.isLocalMac else { return nil }
            return snapshot.identity.localPreferenceKey
        }
        let normalized = candidate.flatMap(Self.validMenuBarDeviceKey)
        guard normalized != menuBarSelectedDevicePreferenceKey else { return }
        menuBarSelectedDevicePreferenceKey = normalized
        persistMenuBarWorkspacePreferences()
    }

    // MARK: - Apple device presentation

    /// Installs the current coordinator's explicit refresh action. A display
    /// change can rebuild the panel and its coordinator; the new view model
    /// simply replaces this weak action, so Settings never holds an obsolete
    /// provider tree alive.
    func configureExternalAppleDeviceRefresh(_ action: @escaping () -> Void) {
        refreshExternalAppleDevicesAction = action
    }

    func configureLowBatteryAlerts(_ action: @escaping (Bool, Bool) -> Void) {
        configureLowBatteryAlertsAction = action
    }

    /// Only this user-initiated path may ask macOS for notification access.
    /// Loading or restoring the preference enables policy but never prompts.
    func setLowBatteryAlertsEnabledByUser(_ enabled: Bool) {
        lowBatteryAlertsEnabled = enabled
        configureLowBatteryAlertsAction?(enabled, enabled)
    }

    /// Receives only already-sanitised domain snapshots. The list is runtime
    /// state: names, charge and timestamps are not persisted. Previously seen
    /// rows stay for this run so a stale or hidden device can be forgotten.
    func updateAppleDeviceState(
        devices: [AppleDeviceSnapshot],
        diagnostics: [DeviceProviderDiagnostic]
    ) {
        let external = devices.filter { !$0.identity.isLocalMac }
        registerAppleDevices(external)
        currentAppleDevicePreferenceKeys = Set(external.map { $0.identity.localPreferenceKey })

        var byKey: [String: AppleDeviceSnapshot] = [:]
        for device in knownExternalAppleDevices {
            byKey[device.identity.localPreferenceKey] = device
        }
        for device in external {
            byKey[device.identity.localPreferenceKey] = device
        }
        let ordered = orderedExternalAppleDevices(from: Array(byKey.values))
        if ordered != knownExternalAppleDevices { knownExternalAppleDevices = ordered }
        if diagnostics != appleDeviceDiagnostics { appleDeviceDiagnostics = diagnostics }
    }

    func findExternalAppleDevices() {
        if showsExternalAppleDevices {
            refreshExternalAppleDevicesAction?()
        } else {
            // The settings publisher starts the providers synchronously. Their
            // own first refresh is the discovery action; asking again here
            // would only create a duplicate read.
            showsExternalAppleDevices = true
        }
    }

    func refreshExternalAppleDevices() {
        guard showsExternalAppleDevices else { return }
        refreshExternalAppleDevicesAction?()
    }

    func orderedExternalAppleDevices(from devices: [AppleDeviceSnapshot]) -> [AppleDeviceSnapshot] {
        let positions = Dictionary(uniqueKeysWithValues: appleDevicePreferenceOrder.enumerated().map { ($1, $0) })
        return devices.filter { !$0.identity.isLocalMac }.sorted { lhs, rhs in
            let leftKey = lhs.identity.localPreferenceKey
            let rightKey = rhs.identity.localPreferenceKey
            let leftPosition = positions[leftKey] ?? Int.max
            let rightPosition = positions[rightKey] ?? Int.max
            if leftPosition != rightPosition { return leftPosition < rightPosition }
            let names = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if names != .orderedSame { return names == .orderedAscending }
            return leftKey < rightKey
        }
    }

    func visibleExternalAppleDevices(from devices: [AppleDeviceSnapshot]) -> [AppleDeviceSnapshot] {
        orderedExternalAppleDevices(from: devices).filter {
            !hiddenAppleDevicePreferenceKeys.contains($0.identity.localPreferenceKey)
        }
    }

    func isAppleDeviceVisible(_ device: AppleDeviceSnapshot) -> Bool {
        !hiddenAppleDevicePreferenceKeys.contains(device.identity.localPreferenceKey)
    }

    func isAppleDeviceCurrent(_ device: AppleDeviceSnapshot) -> Bool {
        currentAppleDevicePreferenceKeys.contains(device.identity.localPreferenceKey)
    }

    func canForgetAppleDevice(_ device: AppleDeviceSnapshot) -> Bool {
        !isAppleDeviceVisible(device) || !isAppleDeviceCurrent(device)
    }

    func setAppleDevice(_ device: AppleDeviceSnapshot, visible: Bool) {
        guard !device.identity.isLocalMac else { return }
        registerAppleDevices([device])
        let key = device.identity.localPreferenceKey
        var hidden = hiddenAppleDevicePreferenceKeys
        if visible {
            hidden.remove(key)
        } else {
            hidden.insert(key)
        }
        guard hidden != hiddenAppleDevicePreferenceKeys else { return }
        hiddenAppleDevicePreferenceKeys = hidden
        persistAppleDevicePreferences()
    }

    func moveAppleDevice(_ device: AppleDeviceSnapshot, offset: Int) {
        moveAppleDevice(device, offset: offset, among: knownExternalAppleDevices)
    }

    func moveAppleDevice(
        _ device: AppleDeviceSnapshot,
        offset: Int,
        among devices: [AppleDeviceSnapshot]
    ) {
        let visibleOrder = devices.map { $0.identity.localPreferenceKey }
        let key = device.identity.localPreferenceKey
        guard let source = visibleOrder.firstIndex(of: key) else { return }
        let destination = source + offset
        guard visibleOrder.indices.contains(destination) else { return }
        let otherKey = visibleOrder[destination]
        guard let sourceInAll = appleDevicePreferenceOrder.firstIndex(of: key),
              let destinationInAll = appleDevicePreferenceOrder.firstIndex(of: otherKey) else { return }
        appleDevicePreferenceOrder.swapAt(sourceInAll, destinationInAll)
        knownExternalAppleDevices = orderedExternalAppleDevices(from: knownExternalAppleDevices)
        persistAppleDevicePreferences()
    }

    func forgetAppleDevice(_ device: AppleDeviceSnapshot) {
        guard canForgetAppleDevice(device) else { return }
        let key = device.identity.localPreferenceKey
        knownExternalAppleDevices.removeAll { $0.identity.localPreferenceKey == key }
        appleDevicePreferenceOrder.removeAll { $0 == key }
        var hidden = hiddenAppleDevicePreferenceKeys
        hidden.remove(key)
        hiddenAppleDevicePreferenceKeys = hidden
        persistAppleDevicePreferences()
    }

    func apply(_ snapshot: ImpulsSettingsSnapshot) {
        isApplying = true
        hotKey = snapshot.hotKey
        activationMode = snapshot.activationMode
        openDelay = snapshot.openDelay
        panelSize = snapshot.panelSize
        selectedDisplayID = snapshot.selectedDisplayID
        modules = Self.normalizedModules(snapshot.modules)
        saveClipboardImages = snapshot.saveClipboardImages
        persistClipboardHistory = snapshot.persistClipboardHistory
        clipboardRetention = snapshot.clipboardRetention
        excludedClipboardBundleIdentifiers = Self.normalizedBundleIdentifiers(
            snapshot.excludedClipboardBundleIdentifiers
        )
        showsExternalAppleDevices = snapshot.showsExternalAppleDevices
        menuBarWorkspace = MenuBarWorkspaceConfiguration.normalized(snapshot.menuBarWorkspace)
        refreshDisplays()
        isApplying = false
        persist()
    }

    /// Which displays Impuls may present itself on.
    var displayPreference: DisplayPreference {
        DisplayPreference(selectedDisplayID: selectedDisplayID)
    }

    /// The picker lists the same displays the panel layer uses, mirrors folded
    /// together and all — offering a secondary mirror as a destination would
    /// offer a workspace that does not exist.
    func refreshDisplays() {
        let topology = DisplayTopology.resolve(from: displaySource(), preference: .allDisplays)
        displays = topology.displays.map { DisplayOption(id: $0.id, name: $0.name) }
        // A display that has been unplugged stops being a choice, and the
        // preference falls back to every display rather than to nothing.
        if let selectedDisplayID, !displays.contains(where: { $0.id == selectedDisplayID }) {
            self.selectedDisplayID = nil
        }
    }

    func reportHotKeyRegistration(succeeded: Bool) {
        hotKeyError = succeeded ? nil : localized("This shortcut is already used by macOS or another application.")
    }

    static func normalizedModules(_ supplied: [ModulePreference]) -> [ModulePreference] {
        var seen = Set<NotchViewModel.Tab>()
        var result = supplied.filter { seen.insert($0.tab).inserted }
        for tab in NotchViewModel.Tab.allCases where !seen.contains(tab) {
            let preference = ModulePreference(tab: tab, isEnabled: true)
            if tab == .actions {
                result.insert(preference, at: 0)
            } else {
                result.append(preference)
            }
        }
        if !result.contains(where: \.isEnabled), !result.isEmpty {
            result[0].isEnabled = true
        }
        return result
    }

    static func normalizedBundleIdentifiers(_ supplied: [String]) -> [String] {
        var result = Set<String>()
        // Backups are bounded as files, but an attacker can still fill one
        // field or array with excessive values. Inspect only enough candidates
        // to populate the 50 entries the settings model can retain.
        for suppliedIdentifier in supplied.prefix(500) {
            let identifier = BoundedText.prefix(suppliedIdentifier, maximumCharacters: 256)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidBundleIdentifier(identifier),
                  identifier != Bundle.main.bundleIdentifier else { continue }
            result.insert(identifier)
            if result.count == 50 { break }
        }
        return result.sorted()
    }

    static func normalizedAppleDevicePreferenceKeys(_ supplied: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for candidate in supplied.prefix(1_000) {
            guard candidate.count == 32,
                  candidate.unicodeScalars.allSatisfy({ scalar in
                      (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
                  }),
                  seen.insert(candidate).inserted else { continue }
            result.append(candidate)
            if result.count == maximumRememberedAppleDevices { break }
        }
        return result
    }

    static func isValidBundleIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty,
              identifier.lengthOfBytes(using: .utf8) <= 255,
              !identifier.hasPrefix("."),
              !identifier.hasSuffix("."),
              !identifier.contains("..") else { return false }
        return identifier.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 48...57, 65...90, 97...122:
                return true
            default:
                return false
            }
        }
    }

    private static func defaultSnapshot(defaults: UserDefaults) -> ImpulsSettingsSnapshot {
        let savesImages: Bool
        if defaults.object(forKey: saveClipboardImagesKey) == nil {
            savesImages = true
        } else {
            savesImages = defaults.bool(forKey: saveClipboardImagesKey)
        }
        return ImpulsSettingsSnapshot(
            hotKey: .optionSpace,
            activationMode: .hoverAndShortcut,
            openDelay: .short,
            panelSize: .standard,
            selectedDisplayID: nil,
            modules: NotchViewModel.Tab.allCases.map { ModulePreference(tab: $0, isEnabled: true) },
            saveClipboardImages: savesImages,
            persistClipboardHistory: false,
            clipboardRetention: .sevenDays,
            excludedClipboardBundleIdentifiers: [],
            showsExternalAppleDevices: false,
            menuBarWorkspace: .init()
        )
    }

    private static func loadAppleDevicePreferences(defaults: UserDefaults) -> AppleDeviceLocalPreferences {
        let decoded = defaults.data(forKey: appleDevicePreferencesKey)
            .flatMap { try? JSONDecoder().decode(AppleDeviceLocalPreferences.self, from: $0) }
            ?? AppleDeviceLocalPreferences(order: [], hidden: [])
        var order = normalizedAppleDevicePreferenceKeys(decoded.order)
        let hidden = normalizedAppleDevicePreferenceKeys(decoded.hidden)
        for key in hidden where !order.contains(key) {
            guard order.count < maximumRememberedAppleDevices else { break }
            order.append(key)
        }
        return AppleDeviceLocalPreferences(order: order, hidden: hidden)
    }

    private static func loadMenuBarWorkspacePreferences(defaults: UserDefaults) -> MenuBarWorkspaceLocalPreferences {
        let decoded = defaults.data(forKey: menuBarWorkspacePreferencesKey)
            .flatMap { try? JSONDecoder().decode(MenuBarWorkspaceLocalPreferences.self, from: $0) }
            ?? MenuBarWorkspaceLocalPreferences(selectedDeviceKey: nil)
        return MenuBarWorkspaceLocalPreferences(
            selectedDeviceKey: decoded.selectedDeviceKey.flatMap(validMenuBarDeviceKey)
        )
    }

    private static func validMenuBarDeviceKey(_ value: String) -> String? {
        guard normalizedAppleDevicePreferenceKeys([value]).first == value else { return nil }
        return value
    }

    private func registerAppleDevices(_ devices: [AppleDeviceSnapshot]) {
        var order = appleDevicePreferenceOrder
        for device in devices where !device.identity.isLocalMac {
            let key = device.identity.localPreferenceKey
            guard !order.contains(key), order.count < Self.maximumRememberedAppleDevices else { continue }
            order.append(key)
        }
        guard order != appleDevicePreferenceOrder else { return }
        appleDevicePreferenceOrder = order
        persistAppleDevicePreferences()
    }

    private func persistAppleDevicePreferences() {
        let preferences = AppleDeviceLocalPreferences(
            order: appleDevicePreferenceOrder,
            hidden: appleDevicePreferenceOrder.filter(hiddenAppleDevicePreferenceKeys.contains)
        )
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.appleDevicePreferencesKey)
    }

    private func persistMenuBarWorkspacePreferences() {
        let preferences = MenuBarWorkspaceLocalPreferences(
            selectedDeviceKey: menuBarSelectedDevicePreferenceKey
        )
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.menuBarWorkspacePreferencesKey)
    }

    private func persist() {
        guard !isApplying else { return }
        do {
            defaults.set(try JSONEncoder().encode(snapshot), forKey: Self.storageKey)
            defaults.set(saveClipboardImages, forKey: Self.saveClipboardImagesKey)
        } catch {
            NSLog("Impuls: cannot save settings: \(error.localizedDescription)")
        }
    }
}

extension NSScreen {
    var impulsDisplayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
