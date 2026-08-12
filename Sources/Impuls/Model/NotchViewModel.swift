import AppKit
import Combine

@MainActor
final class NotchViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Codable, Hashable, Identifiable {
        case actions, media, shelf, clipboard, snippets, calendar, translate, notes, power
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .actions: return "bolt.fill"
            case .media: return "music.note"
            case .shelf: return "tray.full.fill"
            case .clipboard: return "list.clipboard.fill"
            case .snippets: return "pin.fill"
            case .calendar: return "calendar"
            case .translate: return "translate"
            case .notes: return "note.text"
            // Not `bolt.fill`: Actions used to carry that symbol too, and on a
            // desktop Mac — where this module never becomes the battery — the
            // rail showed the same glyph twice with nothing to tell them apart.
            case .power: return "powerplug.fill"
            }
        }

        var title: String {
            switch self {
            case .actions: return localized("Actions")
            case .media: return localized("Music")
            case .shelf: return localized("Shelf")
            case .clipboard: return localized("Clipboard")
            case .snippets: return localized("Snippets")
            case .calendar: return localized("Calendar")
            case .translate: return localized("Translate")
            case .notes: return localized("Notes")
            case .power: return localized("Power")
            }
        }

        /// Tabs with a field in them. Landing on one hands it the keyboard, so
        /// that arriving and typing is a single move.
        var needsKeyboard: Bool { self == .actions || self == .translate || self == .snippets || self == .notes }

    }

    @Published var isOpen = false
    @Published var isDropTargeted = false
    @Published var tab: Tab = .media {
        didSet {
            // Opening the tab only re-checks the status. The permission prompt
            // is the user's own press on the button inside the pane. A
            // sensitive permission deserves an explanation before the system
            // dialog, not after.
            if tab == .calendar { calendar.refreshAccess() }
            if tab == .actions { snippets.reload() }
            // The snippets file is edited from outside the app, so it is read
            // on the way in rather than held from launch.
            if tab == .snippets { snippets.reload() }
            // Leaving the notes sweeps out the blank ones — they cost one
            // hover to recreate, and a trail of empty cards is the clutter a
            // scratchpad exists to avoid.
            if oldValue == .notes, tab != .notes { notes.leave() }
            if oldValue == .actions, tab != .actions { actions.query = "" }
            // Leaving the tab that types gives the keyboard straight back.
            if !tab.needsKeyboard { wantsKeyboard = false }
        }
    }

    /// Whether the panel currently holds the keyboard.
    ///
    /// Tracked apart from `tab` because the two come apart in one direction:
    /// clicking into another app drops the claim without changing which tab is
    /// showing, so the text one was typing survives and the panel is free to
    /// collapse. Landing on a tab that types always raises it again — there is
    /// no such thing as a panel that shows a field but cannot receive a key.
    @Published var wantsKeyboard = false

    /// A panel opened from the global shortcut remains a keyboard surface even
    /// on modules that have no text field. Arrow keys can then move through the
    /// rail and Escape can close the panel without requiring the pointer.
    @Published var keyboardNavigationActive = false

    let geometry: NotchGeometry
    let settings: SettingsStore
    let media: MediaController
    let actions: ImpulsActionsStore
    let shelf: ShelfStore
    let fileTools: FileToolsCoordinator
    let clipboard: ClipboardStore
    let calendar: CalendarStore
    let translator: Translator
    let snippets: SnippetStore
    let notes: NoteStore
    let power: PowerMonitor
    /// The Apple device layer. It sits beside `power` rather than replacing it:
    /// the local Mac still comes from `PowerMonitor`, and the centre adds the
    /// devices around it once the user asks for them.
    let devices: DevicePowerCenter

    private var cancellables = Set<AnyCancellable>()

    init(geometry: NotchGeometry, settings: SettingsStore) {
        self.geometry = geometry
        self.settings = settings
        self.actions = ImpulsActionsStore()
        self.media = MediaController()
        self.shelf = ShelfStore()
        self.fileTools = FileToolsCoordinator(shelf: self.shelf)
        self.clipboard = ClipboardStore()
        self.calendar = CalendarStore()
        self.translator = Translator()
        self.snippets = SnippetStore()
        self.notes = NoteStore()
        let power = PowerMonitor()
        self.power = power
        self.devices = DevicePowerCenter(monitor: power)

        self.clipboard.isApplicationExcluded = { [weak settings] bundleIdentifier in
            settings?.excludedClipboardBundleIdentifiers.contains(bundleIdentifier) ?? false
        }

        if let first = settings.enabledTabs.first, !settings.enabledTabs.contains(tab) {
            tab = first
        }

        // The panel header reads through to the stores — counters, the source
        // name, the equalizer. Nested ObservableObjects do not propagate on
        // their own, so those would only refresh when something else happened
        // to redraw the view.
        //
        // Forwarded only while the panel is open. Collapsed, there is nothing
        // these redraws could change — the panel is a black shape — yet the
        // stores keep their own schedule: a track change every few minutes, a
        // copy whenever one happens, and each send re-evaluated the whole
        // view for nobody. Opening repaints from the stores directly, because
        // `isOpen` is itself @Published and its own send does that.
        //
        // The stores with a text field in their pane — Actions, the translator,
        // snippets and notes — are deliberately absent. They change on every
        // keystroke, and redrawing the whole panel per letter costs more than a
        // stale counter: it rebuilds the field, which drops the focus, so the
        // first letter typed is also the last one that lands. Their panes
        // observe them directly, and the header counter refreshes anyway,
        // because the list is only ever re-read on the way into the tab.
        for child in [
            media.objectWillChange,
            shelf.objectWillChange,
            fileTools.objectWillChange,
            clipboard.objectWillChange,
            calendar.objectWillChange,
            power.objectWillChange,
            devices.objectWillChange,
        ] {
            child
                .sink { [weak self] _ in
                    guard let self, self.isOpen || self.isDropTargeted else { return }
                    self.objectWillChange.send()
                }
                .store(in: &cancellables)
        }

        settings.$modules
            .dropFirst()
            .sink { [weak self] preferences in
                guard let self else { return }
                let enabled = preferences.compactMap { $0.isEnabled ? $0.tab : nil }
                self.power.setEnabled(enabled.contains(.power))
                self.devices.setEnabled(enabled.contains(.power))
                if !enabled.contains(self.tab), let first = enabled.first {
                    self.tab = first
                }
                self.objectWillChange.send()
            }
            .store(in: &cancellables)

        power.$snapshot
            .sink { [weak settings] snapshot in
                settings?.setPowerDeviceKind(snapshot.deviceKind)
            }
            .store(in: &cancellables)

        settings.$showsExternalAppleDevices
            .sink { [weak self] enabled in
                self?.devices.setExternalDevicesEnabled(enabled)
            }
            .store(in: &cancellables)

        // Settings sees the same sanitised snapshots as the panel, and only at
        // runtime. The callback is weak because Settings outlives a coordinator
        // when the panel is rebuilt for another display.
        settings.configureExternalAppleDeviceRefresh { [weak devices] in
            devices?.refreshExternalDevices()
        }
        Publishers.CombineLatest(devices.$devices, devices.$diagnostics)
            .sink { [weak settings] devices, diagnostics in
                settings?.updateAppleDeviceState(devices: devices, diagnostics: diagnostics)
            }
            .store(in: &cancellables)

        settings.$persistClipboardHistory
            .combineLatest(settings.$clipboardRetention)
            .sink { [weak self] enabled, retention in
                self?.clipboard.configurePersistence(enabled: enabled, retention: retention)
            }
            .store(in: &cancellables)
    }

    /// Size of the visible body for the current state.
    var bodySize: CGSize {
        isOpen || isDropTargeted ? geometry.expandedSize : geometry.collapsedSize
    }

    var visibleTabs: [Tab] { settings.enabledTabs }

    func title(for tab: Tab) -> String {
        guard tab == .power else { return tab.title }
        return power.snapshot.deviceKind == .portable ? localized("Battery") : localized("Power")
    }

    func symbol(for tab: Tab) -> String {
        guard tab == .power else { return tab.symbol }
        return power.snapshot.deviceKind == .portable ? "battery.100percent" : "bolt.fill"
    }

    /// The rails are split evenly, with the odd module going left.
    ///
    /// It used to be the first six on the left and the remainder on the right,
    /// which put nine modules into a 6/3 split. Six is what the taller rail has
    /// to fit, and at six the fitted button height lands exactly on the space
    /// available — the rail filled the panel edge to edge with nothing to
    /// spare. Halving the count makes five the number to fit, the button
    /// reaches its 28 pt ceiling at every preset instead of being squeezed
    /// below it, and the margin below stops being theoretical.
    var leftRailTabs: [Tab] {
        Array(visibleTabs.prefix((visibleTabs.count + 1) / 2))
    }

    var rightRailTabs: [Tab] {
        Array(visibleTabs.dropFirst((visibleTabs.count + 1) / 2))
    }

    /// Hover and click both land here. A tab that types takes the keyboard
    /// either way: showing a field one cannot type into is worse than briefly
    /// dimming the caret of the window underneath, and the dwell threshold on
    /// the rail already keeps a passing pointer from arriving here at all.
    func select(_ tab: Tab, requestKeyboard: Bool = true) {
        guard visibleTabs.contains(tab) else { return }
        self.tab = tab
        if requestKeyboard, tab.needsKeyboard { wantsKeyboard = true }
    }

    func moveSelection(by offset: Int) {
        let tabs = visibleTabs
        guard tabs.count > 1, let index = tabs.firstIndex(of: tab) else { return }
        let destination = (index + offset + tabs.count) % tabs.count
        select(tabs[destination], requestKeyboard: false)
    }

    /// The global shortcut is the direct entrance to the command surface.
    /// Hovering still returns to whichever module was last used; the shortcut
    /// is intentional keyboard input, so it starts with a clean search.
    func prepareActionsForKeyboard() {
        guard visibleTabs.contains(.actions) else { return }
        actions.query = ""
        select(.actions)
    }

    @discardableResult
    func perform(_ command: ImpulsActionCommand, on result: ImpulsActionResult) -> String? {
        switch command {
        case .copy:
            if case .clipboard(let id) = result.origin,
               let item = clipboard.items.first(where: { $0.id == id }) {
                clipboard.copy(item)
            } else {
                writeToPasteboard(result.value)
            }
            return localized("Copied")

        case .saveSnippet:
            guard let text = result.value.text else { return nil }
            snippets.add(label: "", text: text)
            return localized("Saved to Snippets")

        case .createNote:
            guard let text = result.value.text else { return nil }
            notes.add(text: text)
            if visibleTabs.contains(.notes) {
                select(.notes)
                return nil
            }
            return localized("Saved to Notes")

        case .translate:
            guard let text = result.value.text else { return nil }
            guard visibleTabs.contains(.translate) else {
                return localized("Enable Translate in Settings")
            }
            translator.input = text
            select(.translate)
            return nil

        case .open:
            guard let url = result.externalURL else { return nil }
            NSWorkspace.shared.open(url)
            return localized("Opened")

        case .email:
            guard result.contentKind == .email, let url = result.externalURL else { return nil }
            NSWorkspace.shared.open(url)
            return localized("Email Opened")

        case .call:
            guard result.contentKind == .phone, let url = result.externalURL else { return nil }
            NSWorkspace.shared.open(url)
            return localized("Call Opened")

        case .formatJSON:
            guard let text = result.value.text,
                  let formatted = ClipboardContentClassifier.prettyPrintedJSON(text) else { return nil }
            clipboard.copy(.text(formatted))
            return localized("Formatted JSON Copied")

        case .pin, .unpin:
            guard case .clipboard(let id) = result.origin else { return nil }
            let pinned = command == .pin
            clipboard.setPinned(id: id, pinned: pinned)
            return pinned ? localized("Pinned") : localized("Unpinned")

        case .reveal:
            guard case .file(let url) = result.value else { return nil }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return localized("Shown in Finder")
        }
    }

    private func writeToPasteboard(_ value: ImpulsActionValue) {
        switch value {
        case .text(let text): clipboard.copy(.text(text))
        case .file(let url): clipboard.copy(.file(url))
        }
    }

    func start() {
        media.start()
        shelf.load()
        snippets.reload()
        // Only picks up where it left off if access was granted earlier; it
        // never prompts on its own.
        calendar.start()
        power.setEnabled(visibleTabs.contains(.power))
        devices.setEnabled(visibleTabs.contains(.power))
        // Nothing external starts on its own. The switch is off for everyone
        // who has not turned it on, including everyone updating from 1.4.5.
        devices.setExternalDevicesEnabled(settings.showsExternalAppleDevices)

        // Screenshots reach the shelf through here whether they were taken on
        // this Mac or on a phone: a copy made on the phone arrives in the same
        // pasteboard, carried over by Continuity.
        //
        // The switch is asked by the store before it touches image data, not
        // here after the fact: turned off, a copied picture used to be encoded
        // to PNG in full just to be dropped on this doorstep — pure heat on
        // exactly the machines whose owners turned the feature off.
        clipboard.wantsImages = { [weak settings] in settings?.saveClipboardImages ?? true }
        clipboard.onImage = { [weak self] png, date in
            ScreenshotVault.save(png, at: date) { [weak self] url in
                guard let self, let url else { return }
                self.shelf.add([url])
                self.clipboard.record(ClipItem(payload: .file(url), date: date))
                self.tab = .shelf
            }
        }
        clipboard.start()
    }

    func stop() {
        media.stop()
        clipboard.stop()
        calendar.stop()
        power.stop()
        devices.stop()
        // Whatever was typed makes it to disk even when quitting mid-thought.
        notes.flushSynchronously()
    }

    func accept(urls: [URL]) -> Bool {
        shelf.add(urls)
        tab = .shelf
        return true
    }
}
