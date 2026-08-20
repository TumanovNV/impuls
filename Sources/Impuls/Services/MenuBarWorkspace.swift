import Foundation

/// A saved choice for the compact status-item title.
///
/// The title is deliberately resolved from already-published local state. This
/// model never starts a device provider, opens a player, or creates a timer;
/// the menu bar is a presentation client of the services the user already
/// enabled elsewhere.
enum MenuBarStatusMode: String, CaseIterable, Codable, Identifiable {
    case logo
    case macBattery
    case selectedDevice
    case lowestBattery
    case player
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .logo: return localized("Impuls Logo")
        case .macBattery: return localized("Mac Battery")
        case .selectedDevice: return localized("Selected Device")
        case .lowestBattery: return localized("Lowest Battery")
        case .player: return localized("Now Playing")
        case .automatic: return localized("Automatic")
        }
    }
}

/// A content block in the configurable status menu. `automatic` is shared
/// with the status-item mode so the same rules are used in both places.
enum MenuBarWorkspaceWidget: String, CaseIterable, Codable, Identifiable {
    case none
    case macBattery
    case selectedDevice
    case lowestBattery
    case player
    case quickActions
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return localized("None")
        case .macBattery: return localized("Mac Battery")
        case .selectedDevice: return localized("Selected Device")
        case .lowestBattery: return localized("Lowest Battery")
        case .player: return localized("Now Playing")
        case .quickActions: return localized("Quick Actions")
        case .automatic: return localized("Automatic")
        }
    }

    var statusMode: MenuBarStatusMode? {
        switch self {
        case .none, .quickActions: return nil
        case .macBattery: return .macBattery
        case .selectedDevice: return .selectedDevice
        case .lowestBattery: return .lowestBattery
        case .player: return .player
        case .automatic: return .automatic
        }
    }
}

enum MenuBarWorkspacePreset: String, CaseIterable, Codable, Identifiable {
    case minimal
    case batteries
    case music
    case work
    case smart
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .minimal: return localized("Minimal")
        case .batteries: return localized("Batteries")
        case .music: return localized("Music")
        case .work: return localized("Work")
        case .smart: return localized("Smart")
        case .custom: return localized("Custom")
        }
    }
}

/// The ordered, inspectable policy behind the Smart preset. A priority only
/// wins when it has an honest current value; it never manufactures a value to
/// make a configured row appear.
enum MenuBarSmartPriority: String, CaseIterable, Codable, Identifiable {
    case lowBattery
    case activePlayer
    case charging
    case neutral

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lowBattery: return localized("Low Battery")
        case .activePlayer: return localized("Active Player")
        case .charging: return localized("Charging")
        case .neutral: return localized("Neutral")
        }
    }
}

/// Intentional entrance points rather than a second collection of settings
/// toggles. Module actions are filtered at presentation time when their module
/// is disabled, but the saved order survives a temporary module change.
enum MenuBarQuickAction: String, CaseIterable, Codable, Identifiable {
    case openPanel
    case showScreenshots
    case clearScreenshots
    case actions
    case media
    case shelf
    case clipboard
    case snippets
    case calendar
    case translate
    case notes
    case power

    var id: String { rawValue }

    var title: String {
        AppFeatureCatalog.feature(for: self)?.title ?? localized("Open Panel")
    }

    var symbol: String {
        if let symbol = AppFeatureCatalog.feature(for: self)?.symbol { return symbol }
        switch self {
        case .openPanel: return "rectangle.topthird.inset.filled"
        case .showScreenshots: return "folder"
        case .clearScreenshots: return "trash"
        default: return "rectangle.topthird.inset.filled"
        }
    }

    var tab: NotchViewModel.Tab? {
        switch self {
        case .openPanel, .showScreenshots, .clearScreenshots: return nil
        case .actions: return .actions
        case .media: return .media
        case .shelf: return .shelf
        case .clipboard: return .clipboard
        case .snippets: return .snippets
        case .calendar: return .calendar
        case .translate: return .translate
        case .notes: return .notes
        case .power: return .power
        }
    }
}

/// Exportable menu-bar choices. A selected physical device is intentionally
/// kept outside this snapshot: its opaque key is local to one Mac and moving it
/// into a backup would make a restored selection misleading on another Mac.
struct MenuBarWorkspaceConfiguration: Codable, Equatable {
    static let maximumQuickActions = 4
    static let defaultLowBatteryThreshold = 20

    var preset: MenuBarWorkspacePreset
    var statusMode: MenuBarStatusMode
    var primaryWidget: MenuBarWorkspaceWidget
    var secondaryWidget: MenuBarWorkspaceWidget?
    var quickActions: [MenuBarQuickAction]
    var smartPriorities: [MenuBarSmartPriority]
    var lowBatteryThreshold: Int

    init(
        preset: MenuBarWorkspacePreset = .smart,
        statusMode: MenuBarStatusMode = .automatic,
        primaryWidget: MenuBarWorkspaceWidget = .automatic,
        secondaryWidget: MenuBarWorkspaceWidget? = .player,
        quickActions: [MenuBarQuickAction] = [.actions, .media, .power],
        smartPriorities: [MenuBarSmartPriority] = [.lowBattery, .activePlayer, .charging, .neutral],
        lowBatteryThreshold: Int = MenuBarWorkspaceConfiguration.defaultLowBatteryThreshold
    ) {
        self.preset = preset
        self.statusMode = statusMode
        self.primaryWidget = primaryWidget
        self.secondaryWidget = secondaryWidget
        self.quickActions = quickActions
        self.smartPriorities = smartPriorities
        self.lowBatteryThreshold = lowBatteryThreshold
        normalize()
    }

    private enum CodingKeys: String, CodingKey {
        case preset, statusMode, primaryWidget, secondaryWidget
        case quickActions, smartPriorities, lowBatteryThreshold
    }

    /// Decode each choice independently. A newer app can remove or rename a
    /// widget/action without making an otherwise healthy backup unreadable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let quickActionIDs = (try? container.decode([String].self, forKey: .quickActions)) ?? []
        let priorityIDs = (try? container.decode([String].self, forKey: .smartPriorities)) ?? []
        self.init(
            preset: (try? container.decode(MenuBarWorkspacePreset.self, forKey: .preset)) ?? .smart,
            statusMode: (try? container.decode(MenuBarStatusMode.self, forKey: .statusMode)) ?? .automatic,
            primaryWidget: (try? container.decode(MenuBarWorkspaceWidget.self, forKey: .primaryWidget)) ?? .automatic,
            secondaryWidget: try? container.decode(MenuBarWorkspaceWidget.self, forKey: .secondaryWidget),
            quickActions: quickActionIDs.compactMap(MenuBarQuickAction.init(rawValue:)),
            smartPriorities: priorityIDs.compactMap(MenuBarSmartPriority.init(rawValue:)),
            lowBatteryThreshold: (try? container.decode(Int.self, forKey: .lowBatteryThreshold))
                ?? Self.defaultLowBatteryThreshold
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preset, forKey: .preset)
        try container.encode(statusMode, forKey: .statusMode)
        try container.encode(primaryWidget, forKey: .primaryWidget)
        try container.encodeIfPresent(secondaryWidget, forKey: .secondaryWidget)
        try container.encode(quickActions.map(\.rawValue), forKey: .quickActions)
        try container.encode(smartPriorities.map(\.rawValue), forKey: .smartPriorities)
        try container.encode(lowBatteryThreshold, forKey: .lowBatteryThreshold)
    }

    mutating func applyPreset(_ preset: MenuBarWorkspacePreset) {
        guard preset != .custom else {
            self.preset = .custom
            return
        }

        self.preset = preset
        switch preset {
        case .minimal:
            statusMode = .logo
            primaryWidget = .none
            secondaryWidget = nil
            quickActions = []
        case .batteries:
            statusMode = .lowestBattery
            primaryWidget = .macBattery
            secondaryWidget = .lowestBattery
            quickActions = [.power]
        case .music:
            statusMode = .player
            primaryWidget = .player
            secondaryWidget = .macBattery
            quickActions = [.media, .actions]
        case .work:
            statusMode = .automatic
            primaryWidget = .player
            secondaryWidget = .lowestBattery
            quickActions = [.actions, .calendar, .clipboard, .notes]
        case .smart:
            statusMode = .automatic
            primaryWidget = .automatic
            secondaryWidget = .player
            quickActions = [.actions, .media, .power]
        case .custom:
            break
        }
        normalize()
    }

    /// Tolerates a partial/corrupt backup and configuration written by a newer
    /// build. The resolver always receives one complete set of priorities and
    /// never renders the same widget twice.
    mutating func normalize() {
        lowBatteryThreshold = min(max(lowBatteryThreshold, 5), 50)
        quickActions = Self.unique(quickActions, maximum: Self.maximumQuickActions)
        smartPriorities = Self.completePriorities(smartPriorities)
        if secondaryWidget == primaryWidget {
            secondaryWidget = nil
        }
        if secondaryWidget == MenuBarWorkspaceWidget.none {
            secondaryWidget = nil
        }
    }

    static func normalized(_ configuration: MenuBarWorkspaceConfiguration?) -> MenuBarWorkspaceConfiguration {
        var result = configuration ?? MenuBarWorkspaceConfiguration()
        result.normalize()
        return result
    }

    private static func unique<T: Hashable>(_ values: [T], maximum: Int) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }.prefix(maximum).map { $0 }
    }

    private static func completePriorities(_ supplied: [MenuBarSmartPriority]) -> [MenuBarSmartPriority] {
        var result = unique(supplied, maximum: MenuBarSmartPriority.allCases.count)
        for priority in MenuBarSmartPriority.allCases where !result.contains(priority) {
            result.append(priority)
        }
        return result
    }
}

/// Sanitised input for the pure menu-bar resolver. `identifier` is either the
/// literal local-Mac marker or an already HMAC-derived local preference key;
/// it is used only to match a local selection and is never shown or exported.
struct MenuBarBattery: Equatable, Identifiable {
    enum State: Equatable {
        case charging
        case charged
        case discharging
        case pluggedNotCharging
        case unknown
    }

    let identifier: String
    let title: String
    let percentage: Int?
    let state: State

    var id: String { identifier }
    var hasPercentage: Bool { percentage != nil }
}

struct MenuBarPlayer: Equatable {
    let title: String
    let subtitle: String
    let isPlaying: Bool
}

struct MenuBarWorkspaceState: Equatable {
    let macBattery: MenuBarBattery?
    let visibleDevices: [MenuBarBattery]
    let player: MenuBarPlayer?
    let selectedDeviceIdentifier: String?

    init(
        macBattery: MenuBarBattery? = nil,
        visibleDevices: [MenuBarBattery] = [],
        player: MenuBarPlayer? = nil,
        selectedDeviceIdentifier: String? = nil
    ) {
        self.macBattery = macBattery
        self.visibleDevices = visibleDevices
        self.player = player
        self.selectedDeviceIdentifier = selectedDeviceIdentifier
    }

    var batteries: [MenuBarBattery] {
        ([macBattery].compactMap { $0 } + visibleDevices).filter(\.hasPercentage)
    }
}

enum MenuBarWorkspaceContent: Equatable {
    case logo
    case battery(MenuBarBattery)
    case player(MenuBarPlayer)
}

/// A widget provider consumes an immutable snapshot of existing local service
/// state. Adding a future widget means registering one provider here; the
/// AppKit menu controller does not need module-specific branching.
protocol MenuBarWidgetProvider {
    var widget: MenuBarWorkspaceWidget { get }
    func compactContent(
        configuration: MenuBarWorkspaceConfiguration,
        state: MenuBarWorkspaceState,
        fallback: () -> MenuBarWorkspaceContent
    ) -> MenuBarWorkspaceContent
}

private struct StandardMenuBarWidgetProvider: MenuBarWidgetProvider {
    let widget: MenuBarWorkspaceWidget

    func compactContent(
        configuration: MenuBarWorkspaceConfiguration,
        state: MenuBarWorkspaceState,
        fallback: () -> MenuBarWorkspaceContent
    ) -> MenuBarWorkspaceContent {
        fallback()
    }
}

enum MenuBarWidgetRegistry {
    private static let providers: [MenuBarWorkspaceWidget: any MenuBarWidgetProvider] = [
        .macBattery: StandardMenuBarWidgetProvider(widget: .macBattery),
        .selectedDevice: StandardMenuBarWidgetProvider(widget: .selectedDevice),
        .lowestBattery: StandardMenuBarWidgetProvider(widget: .lowestBattery),
        .player: StandardMenuBarWidgetProvider(widget: .player),
        .automatic: StandardMenuBarWidgetProvider(widget: .automatic)
    ]

    static func content(
        for widget: MenuBarWorkspaceWidget,
        configuration: MenuBarWorkspaceConfiguration,
        state: MenuBarWorkspaceState,
        fallback: () -> MenuBarWorkspaceContent
    ) -> MenuBarWorkspaceContent {
        providers[widget]?.compactContent(
            configuration: configuration,
            state: state,
            fallback: fallback
        ) ?? .logo
    }
}

/// Pure selection policy. Keeping it independent of AppKit lets the exact
/// fallback chain be unit tested without a status bar, network, player process
/// or physical accessory.
enum MenuBarWorkspaceResolver {
    static func resolve(
        mode: MenuBarStatusMode,
        configuration: MenuBarWorkspaceConfiguration,
        state: MenuBarWorkspaceState
    ) -> MenuBarWorkspaceContent {
        switch mode {
        case .logo:
            return .logo
        case .macBattery:
            return state.macBattery.map(MenuBarWorkspaceContent.battery) ?? .logo
        case .selectedDevice:
            return selectedDevice(in: state).map(MenuBarWorkspaceContent.battery)
                ?? state.macBattery.map(MenuBarWorkspaceContent.battery)
                ?? .logo
        case .lowestBattery:
            return lowestBattery(in: state).map(MenuBarWorkspaceContent.battery) ?? .logo
        case .player:
            return state.player.map(MenuBarWorkspaceContent.player)
                ?? state.macBattery.map(MenuBarWorkspaceContent.battery)
                ?? .logo
        case .automatic:
            return automatic(configuration: configuration, state: state)
        }
    }

    static func resolve(
        widget: MenuBarWorkspaceWidget,
        configuration: MenuBarWorkspaceConfiguration,
        state: MenuBarWorkspaceState
    ) -> MenuBarWorkspaceContent {
        guard let mode = widget.statusMode else { return .logo }
        return MenuBarWidgetRegistry.content(
            for: widget,
            configuration: configuration,
            state: state,
            fallback: { resolve(mode: mode, configuration: configuration, state: state) }
        )
    }

    private static func automatic(
        configuration: MenuBarWorkspaceConfiguration,
        state: MenuBarWorkspaceState
    ) -> MenuBarWorkspaceContent {
        for priority in configuration.smartPriorities {
            switch priority {
            case .lowBattery:
                if let battery = lowestBattery(in: state),
                   let percentage = battery.percentage,
                   percentage <= configuration.lowBatteryThreshold {
                    return .battery(battery)
                }
            case .activePlayer:
                if let player = state.player, player.isPlaying { return .player(player) }
            case .charging:
                if let battery = ([state.macBattery].compactMap { $0 } + state.visibleDevices)
                    .first(where: { $0.state == .charging || $0.state == .charged }) {
                    return .battery(battery)
                }
            case .neutral:
                if let player = state.player { return .player(player) }
                if let battery = state.macBattery { return .battery(battery) }
                if let battery = lowestBattery(in: state) { return .battery(battery) }
                return .logo
            }
        }
        return .logo
    }

    private static func selectedDevice(in state: MenuBarWorkspaceState) -> MenuBarBattery? {
        guard let identifier = state.selectedDeviceIdentifier else { return nil }
        return state.visibleDevices.first { $0.identifier == identifier && $0.hasPercentage }
    }

    private static func lowestBattery(in state: MenuBarWorkspaceState) -> MenuBarBattery? {
        state.batteries.min { lhs, rhs in
            guard let left = lhs.percentage, let right = rhs.percentage else { return false }
            if left != right { return left < right }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}

extension MenuBarBattery.State {
    init(_ state: BatteryState) {
        switch state {
        case .charging: self = .charging
        case .charged, .finishingCharge: self = .charged
        case .discharging: self = .discharging
        case .pluggedNotCharging: self = .pluggedNotCharging
        case .unknown: self = .unknown
        }
    }

    init(_ state: DeviceChargingState?) {
        switch state {
        case .charging: self = .charging
        case .charged: self = .charged
        case .discharging: self = .discharging
        case .notCharging: self = .pluggedNotCharging
        case .unknown, nil: self = .unknown
        }
    }

    var title: String? {
        switch self {
        case .charging: return localized("Charging")
        case .charged: return localized("Charged")
        case .discharging: return localized("On Battery")
        case .pluggedNotCharging: return localized("Plugged In")
        case .unknown: return nil
        }
    }
}

/// Everything the menu-bar item and its menu actually read.
///
/// The status item is rebuilt from a Combine fan-in that includes
/// `MediaController.objectWillChange`, and `MediaController.position` is
/// republished four times a second while a track plays. That rebuilt the whole
/// `NSMenu` and re-read the status icon from disk at that rate — while the
/// panel was open, which is exactly when its animations run.
///
/// The menu never shows a playback position, so comparing this before
/// rebuilding turns those four rebuilds a second into none. `position` is
/// absent by design and is the only omission that matters:
/// `MenuBarWorkspaceState` already narrows the player to title, artist and
/// `isPlaying`.
///
/// Everything the menu's content or enabled state depends on has to be here, or
/// the menu goes stale. Adding a field to the menu means adding it here too.
struct MenuBarMenuFingerprint: Equatable {
    /// Widgets, status mode and the configured quick actions.
    let configuration: MenuBarWorkspaceConfiguration
    /// Mac battery, visible devices, player identity and the selected device.
    let state: MenuBarWorkspaceState
    /// Filters which quick actions are offered.
    let enabledTabs: [NotchViewModel.Tab]
    /// Whether the transport controls are exposed at all.
    let canControlPlayer: Bool
    /// The enabled state of the "Check for Updates…" item.
    let canCheckForUpdates: Bool
}
