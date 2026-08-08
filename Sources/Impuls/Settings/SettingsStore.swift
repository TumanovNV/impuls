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
        case compact, standard, large

        var id: String { rawValue }
        var expandedSize: CGSize {
            switch self {
            case .compact: return CGSize(width: 560, height: 208)
            case .standard: return CGSize(width: 620, height: 208)
            case .large: return CGSize(width: 700, height: 232)
            }
        }
        var title: String {
            switch self {
            case .compact: return localized("Compact")
            case .standard: return localized("Standard")
            case .large: return localized("Large")
            }
        }
    }

    struct DisplayOption: Identifiable, Equatable {
        let id: UInt32
        let name: String
    }

    static let storageKey = "settings.v1"
    static let saveClipboardImagesKey = "saveClipboardImages"

    @Published var hotKey: HotKeyPreset { didSet { persist() } }
    @Published var activationMode: ActivationMode { didSet { persist() } }
    @Published var openDelay: OpenDelay { didSet { persist() } }
    @Published var panelSize: PanelSize { didSet { persist() } }
    @Published var selectedDisplayID: UInt32? { didSet { persist() } }
    @Published private(set) var modules: [ModulePreference] { didSet { persist() } }
    @Published var saveClipboardImages: Bool { didSet { persist() } }
    @Published private(set) var displays: [DisplayOption] = []
    @Published private(set) var hotKeyError: String?

    private let defaults: UserDefaults
    private var isApplying = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        hotKeyError = nil
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
            saveClipboardImages: saveClipboardImages
        )
    }

    var enabledTabs: [NotchViewModel.Tab] {
        modules.compactMap { $0.isEnabled ? $0.tab : nil }
    }

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

    func apply(_ snapshot: ImpulsSettingsSnapshot) {
        isApplying = true
        hotKey = snapshot.hotKey
        activationMode = snapshot.activationMode
        openDelay = snapshot.openDelay
        panelSize = snapshot.panelSize
        selectedDisplayID = snapshot.selectedDisplayID
        modules = Self.normalizedModules(snapshot.modules)
        saveClipboardImages = snapshot.saveClipboardImages
        refreshDisplays()
        isApplying = false
        persist()
    }

    func refreshDisplays() {
        displays = NSScreen.screens.compactMap { screen in
            guard let id = screen.impulsDisplayID else { return nil }
            return DisplayOption(id: id, name: screen.localizedName)
        }
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
            saveClipboardImages: savesImages
        )
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
