import AppKit
import Combine
import SwiftUI

/// Everything the controller reaches outside itself.
///
/// The live values are the real display list, the real pointer and a real
/// window per display. Replacing them is what lets the suite ask "the pointer
/// is on the second monitor and a low-battery notification is clicked — where
/// does the Power pane open?" without three monitors and a battery running out.
@MainActor
struct NotchEnvironment {
    var descriptors: () -> [DisplayDescriptor]
    var mainDisplayID: () -> UInt32?
    var pointerLocation: () -> CGPoint
    var makeSurface: (NotchGeometry, NotchViewModel) -> any NotchSurfacing
    /// Injected rather than called directly so a test can drive the display
    /// logic without starting the clipboard watcher, the media poller and the
    /// calendar. The live value is the real thing and nothing else.
    var startServices: (NotchViewModel) -> Void

    static var live: NotchEnvironment {
        NotchEnvironment(
            descriptors: { ScreenDisplaySource.descriptors() },
            mainDisplayID: { ScreenDisplaySource.mainDisplayID },
            pointerLocation: { NSEvent.mouseLocation },
            makeSurface: { geometry, viewModel in
                NotchDisplaySurface(geometry: geometry, viewModel: viewModel)
            },
            startServices: { $0.start() }
        )
    }
}

@MainActor
final class NotchController {
    private let settings: SettingsStore
    private let environment: NotchEnvironment
    /// Shared, built once, never rebuilt. Every store, timer and monitor in
    /// Impuls hangs off this object, so anything that re-created it — the old
    /// `rebuild()` on a screen-parameter change did — restarted the clipboard
    /// watcher, the media poller and the whole 1.4.6 device layer along with it.
    private(set) var viewModel: NotchViewModel?
    /// One sampler for every display. See `PointerWatcher`.
    private let pointer = PointerWatcher()
    private let coordinator = DisplayCoordinator()
    private var topology = DisplayTopology.empty
    private var closeActiveRectWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var lifetimeCancellables = Set<AnyCancellable>()
    private var menuTrackingObservers: [NSObjectProtocol] = []
    private var menuTrackingState = PanelMenuTrackingState()
    /// Monotonic stamp for the deferred half of closing: any newer open or
    /// close outdates the one still in flight.
    private var openGeneration = 0

    /// Read by the suite to assert that exactly one display owns the panel.
    var activeDisplayID: UInt32? { coordinator.activeDisplayID }
    var presentedDisplayIDs: [UInt32] { coordinator.order }

    /// `environment` has no default: `NotchEnvironment.live` is main-actor
    /// isolated, and a default argument is evaluated in the caller's context.
    /// `AppDelegate` passes `.live`; the suite passes its own.
    init(settings: SettingsStore, environment: NotchEnvironment) {
        self.settings = settings
        self.environment = environment
    }

    func install() {
        build()
        installMenuTrackingObservers()
        settings.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.settingsChanged() }
            }
            .store(in: &lifetimeCancellables)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.settings.refreshDisplays()
                self?.refreshTopology()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeSpaceChanged() }
        }
        // A dark display has no hover to watch, so the one timer that never
        // otherwise stops — the pointer sampler — stops with it. The panel
        // closes too, so waking always starts from the same, folded state.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setOpen(false)
                self.pointer.setInside(false)
                self.pointer.stop()
            }
        }
        // Displays are routinely unplugged while the Mac sleeps, and a Sidecar
        // iPad is routinely gone on the other side of it. Waking therefore
        // reconciles the topology before sampling resumes, so the pointer is
        // never routed to a surface for a display that is no longer there.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settings.refreshDisplays()
                self.refreshTopology()
                self.pointer.start()
            }
        }
    }

    /// The screenshots folder can be emptied from the menu bar; the shelf has
    /// to notice its files are gone without waiting for a relaunch.
    func reloadShelf() {
        viewModel?.shelf.load()
    }

    /// The panel belongs to the desktop it was opened on. ⌘-Tab to another one
    /// leaves the pointer wherever it happened to be — which is not a decision
    /// to keep the panel expanded over a screen the user has just arrived at.
    /// Collapsing also puts hover tracking back in step: nothing moved the
    /// mouse, so nothing else would have.
    private func activeSpaceChanged() {
        guard viewModel?.isOpen == true else { return }
        // What was typed is kept — only the panel closes.
        setOpen(false)
        pointer.setInside(false)
    }

    func teardown() {
        pointer.stop()
        viewModel?.stop()
        coordinator.teardown()
        for observer in menuTrackingObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        menuTrackingObservers.removeAll()
        menuTrackingState.reset()
        cancellables.removeAll()
        lifetimeCancellables.removeAll()
    }

    func toggle() {
        if settings.activationMode == .shortcutOnly {
            toggleFromKeyboard()
            return
        }
        guard let viewModel else { return }
        if viewModel.isOpen {
            setOpen(false)
            pointer.setInside(false)
        } else {
            activateDisplayUnderPointer()
            setOpen(true)
            pointer.setInside(true, display: coordinator.activeDisplayID)
        }
    }

    /// The global shortcut opens Impuls where the user is working, not where it
    /// happened to be built. The display under the pointer decides; failing
    /// that the display macOS considers active, then the primary one.
    func toggleFromKeyboard() {
        guard let vm = viewModel else { return }
        if vm.isOpen {
            pointer.setInside(false)
            setOpen(false)
        } else {
            activateDisplayUnderPointer()
            pointer.setInside(false)
            vm.prepareActionsForKeyboard()
            vm.keyboardNavigationActive = true
            setOpen(true)
        }
    }

    /// Notification clicks have one stable destination in 1.4.6: the Power
    /// pane. Device-level selection can be added later without changing the
    /// notification payload or exposing a hardware identifier.
    func openPower() {
        guard let vm = viewModel, vm.visibleTabs.contains(.power) else { return }
        activateDisplayUnderPointer()
        vm.select(.power, requestKeyboard: false)
        // Like a global-shortcut open, this is an intentional entrance rather
        // than pointer hover. Hold the panel open until the user dismisses it.
        vm.keyboardNavigationActive = true
        pointer.setInside(false)
        setOpen(true)
    }

    func makeBackup(settings snapshot: ImpulsSettingsSnapshot) -> ImpulsBackupDocument? {
        guard let vm = viewModel else { return nil }
        vm.notes.flush()
        vm.snippets.reload()
        return ImpulsBackupDocument(
            settings: snapshot,
            snippets: vm.snippets.items,
            notes: vm.notes.notes
        )
    }

    func restore(_ document: ImpulsBackupDocument) {
        guard let vm = viewModel else { return }
        vm.notes.replace(with: document.notes)
        vm.snippets.replace(with: document.snippets)
        settings.apply(document.settings)
    }

    // MARK: - Construction

    private func build() {
        let vm = NotchViewModel(settings: settings)
        viewModel = vm

        pointer.pointerLocation = environment.pointerLocation
        pointer.isDragging = { [weak self] displayID in
            self?.coordinator.surface(for: displayID)?.isReceivingDrag ?? false
        }
        pointer.isPanelOpen = { [weak vm] in vm?.isOpen ?? false }
        pointer.keepsOpenWithoutPointer = { [weak self, weak vm] in
            (vm?.keyboardNavigationActive ?? false) || (self?.menuTrackingState.isHoldingPanelOpen ?? false)
        }
        pointer.onChange = { [weak self] inside, displayID in
            guard let self else { return }
            if inside, let displayID {
                self.moveActivation(to: displayID)
                self.setOpen(true)
            } else {
                self.setOpen(false)
            }
        }
        // Everything outside the visible panel must reach the app underneath:
        // a `nil` from hitTest only discards the event, it does not forward it.
        pointer.onInteractiveChange = { [weak self] displayID, interactive in
            self?.coordinator.surface(for: displayID)?.setInteractive(interactive)
        }

        refreshTopology()

        // Driven by the deliberate request, not by which tab is showing: a
        // hover can land on the typing tab now, and that alone must not take
        // the keyboard away from the window underneath.
        Publishers.CombineLatest(vm.$wantsKeyboard, vm.$keyboardNavigationActive)
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self] wants in
                MainActor.assumeIsolated { self?.setKeyboard(wants) }
            }
            .store(in: &cancellables)

        // Clicking into another app drops the keyboard: there is no
        // click-outside to catch, but losing key status says the same. The tab
        // stays as it was — only the claim on the keyboard is dropped.
        //
        // Filtered to the surface that is currently active. Handing activation
        // to another display stands the old panel down, and that resignation
        // must not be read as the user clicking away from the new one.
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
            .sink { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self,
                          let window = notification.object as? NSWindow,
                          self.coordinator.activeSurface?.owns(window) == true else { return }
                    self.viewModel?.wantsKeyboard = false
                    self.viewModel?.keyboardNavigationActive = false
                }
            }
            .store(in: &cancellables)

        environment.startServices(vm)
        pointer.start()

        // A fresh surface starts collapsed. If the pointer is already sitting
        // on one, open there at once instead of waiting for a trip back to the
        // notch.
        openIfPointerIsAlreadyOnASurface()
    }

    private func makeSurface(geometry: NotchGeometry, viewModel vm: NotchViewModel) -> any NotchSurfacing {
        let surface = environment.makeSurface(geometry, vm)
        let displayID = surface.displayID

        surface.onDragEntered = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            // The file is being dragged towards this display, so this is the
            // display the shelf has to appear on.
            self.moveActivation(to: displayID)
            vm.tab = .shelf
            vm.isDropTargeted = true
            self.setOpen(true)
        }
        surface.onDragExited = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            vm.isDropTargeted = false
            // The pointer usually is not over the panel after a drag leaves.
            self.scheduleCollapseIfPointerAway()
        }
        surface.onDrop = { [weak self] urls in
            guard let self, let vm = self.viewModel else { return false }
            vm.isDropTargeted = false
            self.moveActivation(to: displayID)
            let accepted = vm.accept(urls: urls)
            self.pointer.setInside(true, display: displayID)
            self.setOpen(true)
            self.scheduleCollapseIfPointerAway()
            return accepted
        }

        // Clicking away drops the keyboard but leaves the tab where it was, so
        // a click back into the panel has to be able to ask for it again.
        surface.onPress = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            self.moveActivation(to: displayID)
            guard vm.tab.needsKeyboard else { return }
            vm.wantsKeyboard = true
        }
        surface.onKeyCommand = { [weak self] command in
            guard let self, let vm = self.viewModel else { return }
            switch command {
            case .previousModule:
                vm.moveSelection(by: -1)
            case .nextModule:
                vm.moveSelection(by: 1)
            case .close:
                self.pointer.setInside(false)
                self.setOpen(false)
            }
        }

        return surface
    }

    // MARK: - Topology

    /// Rebuilds the display topology and reconciles the live surfaces against
    /// it. Called on launch, on every screen-parameter change, on wake, and
    /// whenever a setting that affects geometry changes.
    ///
    /// Nothing is torn down that does not have to be: an unchanged display
    /// keeps its surface, its window and everything on it.
    private func refreshTopology() {
        guard let vm = viewModel else { return }

        topology = DisplayTopology.resolve(
            from: environment.descriptors(),
            preference: settings.displayPreference
        )
        let geometries = topology.displays.map { display in
            NotchGeometry(
                display: display,
                requestedExpandedSize: settings.panelSize.expandedSize(for: display)
            )
        }

        let result = coordinator.reconcile(geometries: geometries) { geometry in
            makeSurface(geometry: geometry, viewModel: vm)
        }

        for displayID in result.removed {
            pointer.forgetDisplay(displayID)
        }

        // The display Impuls was on has gone. Nothing is left to be expanded
        // over, so fold first and let the panel reappear collapsed wherever the
        // user still has a screen.
        if result.activeWasRemoved { foldImmediately() }

        ensureActiveSurface()
        applyActiveRect(open: vm.isOpen)
        refreshPointerZones(open: vm.isOpen)

        if result.activeWasRemoved {
            openIfPointerIsAlreadyOnASurface()
        }
    }

    /// Guarantees exactly one active surface whenever there is a surface at all.
    private func ensureActiveSurface() {
        if let active = coordinator.activeDisplayID, coordinator.surface(for: active) != nil { return }
        guard let target = topology.preferredActiveDisplay(
            pointerLocation: environment.pointerLocation(),
            mainDisplayID: environment.mainDisplayID()
        ) else { return }
        coordinator.activate(target.id)
    }

    /// Hands the expanded panel to another display.
    ///
    /// The keyboard is dropped on the way across rather than transferred: the
    /// panel that is losing activation must not stay key, and the surface
    /// arriving asks for the keyboard again through the ordinary path if the
    /// module it lands on needs one.
    private func moveActivation(to displayID: UInt32) {
        guard displayID != coordinator.activeDisplayID,
              coordinator.surface(for: displayID) != nil else { return }
        guard let vm = viewModel else { return }

        vm.wantsKeyboard = false
        vm.keyboardNavigationActive = false
        coordinator.activate(displayID)

        applyActiveRect(open: vm.isOpen)
        refreshPointerZones(open: vm.isOpen)
    }

    /// Folds the panel without the animation or the deferred second pass.
    ///
    /// Used only when the display the panel stood on has just gone away: there
    /// is nothing left to animate, and the stores it was driving have to be
    /// stood down all the same.
    private func foldImmediately() {
        guard let vm = viewModel else { return }
        openGeneration += 1
        closeActiveRectWork?.cancel()
        closeActiveRectWork = nil
        vm.wantsKeyboard = false
        vm.keyboardNavigationActive = false
        vm.isDropTargeted = false
        pointer.setInside(false)
        guard vm.isOpen else { return }
        vm.isOpen = false
        vm.media.setActive(false)
        vm.calendar.setActive(false)
        vm.power.setActive(false)
        vm.devices.setActive(false)
    }

    /// Picks the display the pointer is on before an entrance that has no
    /// display of its own — the shortcut, the menu bar item, a notification.
    private func activateDisplayUnderPointer() {
        guard let target = topology.preferredActiveDisplay(
            pointerLocation: environment.pointerLocation(),
            mainDisplayID: environment.mainDisplayID()
        ) else { return }
        moveActivation(to: target.id)
    }

    private func openIfPointerIsAlreadyOnASurface() {
        guard let surface = coordinator.activeSurface else { return }
        let location = environment.pointerLocation()
        guard surface.geometry.expandedHoverRect.contains(location)
            || surface.geometry.hoverRect.contains(location) else { return }
        pointer.setInside(true, display: surface.displayID)
        setOpen(true)
    }

    // MARK: - Open / close

    /// Hands the keyboard to the active panel, or gives it back. No other
    /// surface is ever offered it.
    private func setKeyboard(_ wants: Bool) {
        if wants {
            setOpen(true)
            pointer.setInside(true, display: coordinator.activeDisplayID)
        }
        for surface in coordinator.allSurfaces {
            surface.acceptsKeyboard = wants && surface.isActive
        }
        // What was typed stays: clicking away to look something up should not
        // be the same as throwing the text out. Esc and the ✕ do that.
        if !wants { scheduleCollapseIfPointerAway() }
    }

    /// The pointer decides, always. A field with something in it does not hold
    /// the panel open: it is opened by hovering, and anything that survives the
    /// pointer leaving would have to be dismissed some other way, which is a
    /// second rule to learn for a panel that has exactly one. What was typed is
    /// kept, so coming back finds it where it was left.
    private func setOpen(_ open: Bool) {
        guard let vm = viewModel else { return }
        if !open { vm.keyboardNavigationActive = false }
        guard vm.isOpen != open else { return }
        openGeneration += 1
        closeActiveRectWork?.cancel()

        if open {
            // Grow the interactive area first so the pointer never falls
            // through a region the animation has not covered yet.
            applyActiveRect(open: true)
            // Told explicitly rather than read from the view model: `isOpen` is
            // still false for one more statement, and a zone built from it here
            // would leave the expanded panel with a collapsed click target.
            refreshPointerZones(open: true)
            withAnimation(Theme.openAnimation) { vm.isOpen = true }
            vm.media.setActive(true)
            vm.calendar.setActive(true)
            vm.power.setActive(true)
            vm.devices.setActive(true)
        } else {
            // The keyboard goes first and the fold goes second — one run-loop
            // pass apart, never together. Dropped in the same pass, resigning
            // the field's first responder and structurally removing that field
            // land in one transaction, and SwiftUI applies the state but loses
            // the repaint: the panel stands on screen fully expanded with
            // `isOpen` already false, wedged until the next hover repaints it.
            // That was the translate tab "hanging open" — type, move the
            // pointer away, and the picture stayed while the state closed.
            vm.wantsKeyboard = false
            let generation = openGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.openGeneration == generation else { return }
                self.collapse()
            }
        }
    }

    /// The visual half of closing, one pass after the keyboard was let go.
    private func collapse() {
        guard let vm = viewModel, vm.isOpen else { return }
        withAnimation(Theme.openAnimation) { vm.isOpen = false }
        vm.media.setActive(false)
        vm.calendar.setActive(false)
        vm.power.setActive(false)
        vm.devices.setActive(false)
        // Shrink only once the panel has finished collapsing. Doing it
        // while it is still visibly there would leave a window in which
        // clicks land on whatever is behind the panel.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.applyActiveRect(open: false)
            self.refreshPointerZones(open: false)
        }
        closeActiveRectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func scheduleCollapseIfPointerAway() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let surface = self.coordinator.activeSurface else { return }
            // Resync either way. A pointer that is still on the panel has to be
            // recorded as inside, or hover tracking stays convinced it left and
            // the panel hangs open until the notch is touched again.
            let away = !surface.geometry.expandedHoverRect.contains(environment.pointerLocation())
            self.pointer.setInside(!away, display: away ? nil : surface.displayID)
            if away { self.setOpen(false) }
        }
    }

    // MARK: - Menu tracking

    /// SwiftUI presents a context menu in separate AppKit menu windows. Once
    /// the pointer enters one of those windows it is, correctly, outside the
    /// panel's hover rectangle. That must not be interpreted as leaving
    /// Impuls: collapsing the source panel while AppKit is still tracking its
    /// menu detaches nested submenus and can leave their windows on screen.
    private func installMenuTrackingObservers() {
        guard menuTrackingObservers.isEmpty else { return }
        let center = NotificationCenter.default
        menuTrackingObservers = [
            center.addObserver(
                forName: NSMenu.didBeginTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let menu = notification.object as? NSMenu else { return }
                    self.menuTrackingBegan(menu)
                }
            },
            center.addObserver(
                forName: NSMenu.didEndTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let menu = notification.object as? NSMenu else { return }
                    self.menuTrackingEnded(menu)
                }
            }
        ]
    }

    private func menuTrackingBegan(_ menu: NSMenu) {
        menuTrackingState.beginTracking(menu, panelIsOpen: viewModel?.isOpen == true)
        guard menuTrackingState.isHoldingPanelOpen else { return }

        // Invalidate both halves of a close that may already have been queued
        // in the same run-loop turn as the right click.
        openGeneration += 1
        closeActiveRectWork?.cancel()
        closeActiveRectWork = nil
        pointer.setInside(true, display: coordinator.activeDisplayID)
    }

    private func menuTrackingEnded(_ menu: NSMenu) {
        guard menuTrackingState.endTracking(menu) else { return }
        // Defer the geometry check until AppKit has completed dispatching the
        // selected menu action and torn down every submenu window.
        scheduleCollapseIfPointerAway()
    }

    /// The active surface takes clicks over its body; every other surface takes
    /// them over its collapsed anchor only.
    private func applyActiveRect(open: Bool) {
        for surface in coordinator.allSurfaces {
            surface.applyActiveRect(open: open && surface.isActive)
        }
    }

    /// Hands the sampler one zone per display. This is the only place the
    /// pointer layer learns about geometry, and it is called whenever the panel
    /// opens, closes, moves display, or the topology changes.
    private func refreshPointerZones(open isOpen: Bool) {
        let hoverEnabled = settings.activationMode == .hoverAndShortcut

        pointer.zones = coordinator.allSurfaces.map { surface in
            let geometry = surface.geometry
            let expanded = surface.isActive && isOpen
            let bodySize = expanded ? geometry.expandedSize : geometry.collapsedSize
            var interactive = geometry.contentScreenRect(for: bodySize)
            if expanded { interactive = interactive.insetBy(dx: -Theme.openTopRadius, dy: 0) }
            return PointerZone(
                displayID: surface.displayID,
                openRect: hoverEnabled ? geometry.hoverRect : .zero,
                // Only the expanded surface has a panel to stay inside of; the
                // others are still just their anchor.
                closeRect: expanded ? geometry.expandedHoverRect : geometry.hoverRect,
                interactiveRect: interactive,
                warmZone: geometry.warmZone
            )
        }
        pointer.openDelay = settings.openDelay.seconds
        pointer.tracksPanelExit = hoverEnabled
        // Deliberately not `start()`: the sampler is running already, and
        // restarting it here would drop it back to the idle rate every time the
        // panel opened — exactly when the fast rate is being used.
    }

    private func settingsChanged() {
        guard viewModel != nil else { return }
        // Panel size, the display preference and the activation mode all land
        // here. Reconciliation keeps every surface whose geometry is unchanged,
        // so a setting that touches none of them costs one comparison per
        // display.
        refreshTopology()
    }
}

/// Latches a panel that was already open for the complete lifetime of an
/// AppKit menu chain. Tracking menu identity instead of a Boolean keeps nested
/// menus and duplicate begin notifications from releasing the latch early.
@MainActor
struct PanelMenuTrackingState {
    private var activeMenus: Set<ObjectIdentifier> = []
    private(set) var isHoldingPanelOpen = false

    mutating func beginTracking(_ menu: NSMenu, panelIsOpen: Bool) {
        guard panelIsOpen || isHoldingPanelOpen else { return }
        activeMenus.insert(ObjectIdentifier(menu))
        isHoldingPanelOpen = true
    }

    /// Returns true exactly once, when the last tracked menu has closed and
    /// the controller should resume its ordinary hover decision.
    @discardableResult
    mutating func endTracking(_ menu: NSMenu) -> Bool {
        guard activeMenus.remove(ObjectIdentifier(menu)) != nil else { return false }
        guard activeMenus.isEmpty, isHoldingPanelOpen else { return false }
        isHoldingPanelOpen = false
        return true
    }

    mutating func reset() {
        activeMenus.removeAll()
        isHoldingPanelOpen = false
    }
}
