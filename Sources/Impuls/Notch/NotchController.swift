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
    /// The clock hover dwell is measured against. See `PointerWatcher.now`.
    var now: () -> Date
    /// Motion accessibility is injected so transition timing and completion
    /// can be tested without changing the developer's system preference.
    var reducesMotion: () -> Bool
    /// The keyboard must resign one main-loop turn before its field is removed.
    /// Tests hold and drain this queue manually instead of sleeping.
    var deferToNextMainTurn: (@escaping @MainActor () -> Void) -> Void
    /// Visual completion uses the same motion plan as the reveal path. Tests
    /// run delayed work explicitly, so stale-completion races are deterministic.
    var scheduleAfter: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    /// Where the file-backed stores keep their data. The live value is the real
    /// `~/Library/Application Support/Impuls`; a test points it at a temporary
    /// directory so building a view model here cannot reach the user's notes.
    var storage: StorageEnvironment
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
            now: { Date() },
            reducesMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
            deferToNextMainTurn: { operation in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { operation() }
                }
            },
            scheduleAfter: { delay, operation in
                let work = DispatchWorkItem {
                    MainActor.assumeIsolated { operation() }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            },
            storage: .live,
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
    private var topologyRefreshWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var lifetimeCancellables = Set<AnyCancellable>()
    private var menuTrackingObservers: [NSObjectProtocol] = []
    /// The screen, Space and sleep observers, kept so `teardown` can take them
    /// back out.
    ///
    /// They used to be registered and the tokens dropped, on the reasoning that
    /// the controller lives as long as the app. It does — but a test builds one
    /// per case, and a torn-down controller left registered still answered the
    /// next test's screen-parameter notification, reconciling a topology it no
    /// longer had any surfaces for. The app never noticed; the suite would have,
    /// eventually, as something that failed only in a full run.
    private var systemObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var menuTrackingState = PanelMenuTrackingState()
    /// Monotonic stamp for the deferred half of closing: any newer open or
    /// close outdates the one still in flight.
    private var openGeneration = 0
    /// Invalidates delayed "pointer still away?" checks. Opening for any
    /// reason is a new intent even when the panel is already visually open.
    private var collapseIntentGeneration = 0
    /// The semantic target changes immediately even when the visual close has
    /// to wait one turn for first-responder cleanup. Re-entry compares against
    /// this value rather than stale `vm.isOpen`, so it cancels the queued close.
    private var requestedOpen = false
    /// The visible close keeps its expanded hit region until the motion plan's
    /// completion. Topology changes consult this phase rather than `vm.isOpen`.
    private var isClosing = false
    /// Foreground store work has one owner and is idempotent across a cancelled
    /// close/re-entry sequence.
    private var servicesAreActive = false
    /// A deterministic proof that a cancelled transition never starts a second
    /// foreground refresh batch. Production does not otherwise consume it.
    private(set) var foregroundServiceActivationCount = 0
    private var isRefreshingDisplays = false
    /// Whether Impuls holds the keyboard at all, as opposed to which display
    /// holds it.
    ///
    /// Kept as state rather than read back from the view model because the
    /// publisher that drives it fires from `willSet`: inside that callback the
    /// property being described still reports its previous value, so recomputing
    /// the answer there would always be one assignment behind.
    private var keyboardIsClaimed = false

    /// Whether this open session has seen a deliberate action from the user.
    ///
    /// Cleared when the signal is delivered, so one folded session produces at
    /// most one idle notification however many times the panel was touched.
    private var sessionHadMeaningfulUse = false

    /// The app's single signal that somebody deliberately reached for Impuls.
    ///
    /// Deliberately narrow. Five entrances qualify — the global shortcut, a
    /// click on the collapsed tab, the two Menu Bar workspace commands and a
    /// click on a notification — plus a click landing on the panel body, which
    /// is what separates "the user came here to do something" from "the pointer
    /// passed the notch". Hover alone does **not** qualify: the sampler opens
    /// the panel from proximity, and proximity is not intent.
    ///
    /// Background work, timers, update checks, Menu Bar redraws and launch are
    /// not use of any kind and never reach this.
    var onMeaningfulUse: (() -> Void)?

    /// Called once after a session that contained deliberate use has finished
    /// folding — Impuls back to its collapsed anchor, nothing in flight.
    ///
    /// This is the only moment the app offers anything of its own accord.
    var onReturnedToIdle: (() -> Void)?

    /// Read by the suite to assert that exactly one display owns the panel.
    var activeDisplayID: UInt32? { coordinator.activeDisplayID }
    var presentedDisplayIDs: [UInt32] { coordinator.order }
    /// The one sampler, so a test can move the pointer and take a sample
    /// instead of imitating what a sample would have done.
    var pointerSampler: PointerWatcher { pointer }

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
        Publishers.CombineLatest(settings.$panelSize, settings.$selectedDisplayID)
            .dropFirst()
            .removeDuplicates { lhs, rhs in lhs.0 == rhs.0 && lhs.1 == rhs.1 }
            .sink { [weak self] _ in self?.scheduleTopologyRefresh() }
            .store(in: &lifetimeCancellables)
        Publishers.CombineLatest(settings.$activationMode, settings.$openDelay)
            .dropFirst()
            .removeDuplicates { lhs, rhs in lhs.0 == rhs.0 && lhs.1 == rhs.1 }
            .sink { [weak self] _ in
                // `@Published` emits from willSet. Read Settings on the next
                // turn, after both stored values have committed, or the zones
                // would remain one selection behind until another refresh.
                self?.environment.deferToNextMainTurn { [weak self] in
                    guard let self, let vm = self.viewModel else { return }
                    self.refreshPointerZones(open: self.keepsExpandedHitRegion(vm))
                }
            }
            .store(in: &lifetimeCancellables)
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshDisplaysAndTopology()
            }
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeSpaceChanged() }
        }
        observe(
            NSWorkspace.shared.notificationCenter,
            NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.accessibilityDisplayOptionsChanged() }
        }
        // A dark display has no hover to watch, so the one timer that never
        // otherwise stops — the pointer sampler — stops with it. The panel
        // closes too, so waking always starts from the same, folded state.
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification) { [weak self] _ in
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
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshDisplaysAndTopology()
                self.pointer.start()
            }
        }
    }

    /// Registers for a system notification and keeps the token.
    ///
    /// `addObserver(forName:)` returns an object the centre retains until it is
    /// handed back; a `[weak self]` closure keeps the controller from leaking
    /// but not the registration itself.
    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        using block: @escaping @Sendable (Notification) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main, using: block)
        systemObservers.append((center: center, token: token))
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
        openGeneration += 1
        collapseIntentGeneration += 1
        requestedOpen = false
        isClosing = false
        topologyRefreshWork?.cancel()
        topologyRefreshWork = nil
        pointer.stop()
        viewModel?.stop()
        servicesAreActive = false
        keyboardIsClaimed = false
        // Teardown is not a quiet transition. Dropping the flag here keeps a
        // torn-down controller from reporting an idle moment into an app that
        // is on its way out.
        sessionHadMeaningfulUse = false
        coordinator.teardown()
        for observer in menuTrackingObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        menuTrackingObservers.removeAll()
        for observer in systemObservers {
            observer.center.removeObserver(observer.token)
        }
        systemObservers.removeAll()
        menuTrackingState.reset()
        cancellables.removeAll()
        lifetimeCancellables.removeAll()
    }

    /// Records one deliberate entrance. The single funnel for `onMeaningfulUse`,
    /// so the signal cannot quietly acquire a sixth or seventh source.
    private func noteDeliberateUse() {
        sessionHadMeaningfulUse = true
        onMeaningfulUse?()
    }

    func toggle() {
        if settings.activationMode == .shortcutOnly {
            toggleFromKeyboard()
            return
        }
        guard viewModel != nil else { return }
        if requestedOpen {
            setOpen(false)
            pointer.setInside(false)
        } else {
            noteDeliberateUse()
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
        if requestedOpen {
            pointer.setInside(false)
            setOpen(false)
        } else {
            noteDeliberateUse()
            activateDisplayUnderPointer()
            pointer.setInside(false)
            vm.prepareActionsForKeyboard()
            vm.keyboardNavigationActive = true
            setOpen(true)
        }
    }

    /// Opens the current panel without interpreting a Menu Bar command as a
    /// request to close an already-visible workspace.
    func open() {
        guard let vm = viewModel else { return }
        noteDeliberateUse()
        activateDisplayUnderPointer()
        vm.keyboardNavigationActive = true
        pointer.setInside(false)
        setOpen(true)
    }

    /// Notification clicks have one stable destination in 1.4.6: the Power
    /// pane. Device-level selection can be added later without changing the
    /// notification payload or exposing a hardware identifier.
    func openPower() {
        guard let vm = viewModel, vm.visibleTabs.contains(.power) else { return }
        noteDeliberateUse()
        activateDisplayUnderPointer()
        vm.select(.power, requestKeyboard: false)
        // Like a global-shortcut open, this is an intentional entrance rather
        // than pointer hover. Hold the panel open until the user dismisses it.
        vm.keyboardNavigationActive = true
        pointer.setInside(false)
        setOpen(true)
    }

    /// A deliberate Menu Bar quick action. It follows the same single-surface
    /// path as a notification and never creates a second view model or window.
    func open(tab: NotchViewModel.Tab) {
        guard let vm = viewModel, vm.visibleTabs.contains(tab) else { return }
        noteDeliberateUse()
        activateDisplayUnderPointer()
        vm.select(tab, requestKeyboard: tab.needsKeyboard)
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
        let vm = NotchViewModel(settings: settings, storage: environment.storage)
        viewModel = vm

        pointer.pointerLocation = environment.pointerLocation
        pointer.now = environment.now
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
        surface.onDragEnded = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            vm.isDropTargeted = false
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
            // A click inside the panel is the hover user's expression of
            // intent. Counting it is what keeps somebody who works entirely by
            // hover from being invisible to the support prompt, without letting
            // a pointer that merely crossed the notch count as use.
            self.noteDeliberateUse()
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
        // A surface that has just been created, or has just become the active
        // one because the previous display was unplugged, must agree with the
        // rest of the app about the keyboard before it is on screen.
        applyKeyboardOwnership()
        let keepsExpandedHitRegion = keepsExpandedHitRegion(vm)
        applyActiveRect(open: keepsExpandedHitRegion)
        refreshPointerZones(open: keepsExpandedHitRegion)

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

        // Activation and keyboard ownership move together, and in that order.
        // `activate` stands the old surface down — which drops its `acceptsKeyboard`
        // and resigns its window's key status — before the new one is raised, so
        // there is no instant at which two surfaces are active or two windows
        // are willing to take keys.
        coordinator.activate(displayID)
        // Whatever Impuls held, it still holds, now on the display in front of
        // the user. Nothing is re-acquired: a claim the app did not have before
        // the move it does not gain by moving, so hovering onto another display
        // while a text module merely happens to be showing never takes the
        // keyboard from the app underneath.
        applyKeyboardOwnership()

        // Closed surfaces all have the same kind of collapsed target. The open
        // command that follows a hover applies the expanded presentation once;
        // doing a collapsed O(N) pass here first was duplicate work in the same
        // semantic transition.
        if vm.isExpanded {
            // A handoff is a new presentation generation. Any activation
            // deadline captured for the old display must not publish into the
            // middle of the new display's morph.
            openGeneration += 1
            applyActiveRect(open: true)
            refreshPointerZones(open: true)
            coordinator.activeSurface?.setMotionPlan(currentPanelMotionPlan())
            coordinator.activeSurface?.prepareForExpansion()
            let generation = openGeneration
            // The handoff owns the replacement commit too. Reusing the open
            // commit is important when A was only preparing: A's captured
            // display check will cancel its callback, and B must still expand
            // and schedule the one foreground activation batch.
            scheduleExpansionCommit(for: generation, viewModel: vm)
        }
    }

    /// Folds the panel without the animation or the deferred second pass.
    ///
    /// Used only when the display the panel stood on has just gone away: there
    /// is nothing left to animate, and the stores it was driving have to be
    /// stood down all the same.
    private func foldImmediately() {
        guard let vm = viewModel else { return }
        openGeneration += 1
        collapseIntentGeneration += 1
        requestedOpen = false
        isClosing = false
        vm.wantsKeyboard = false
        vm.keyboardNavigationActive = false
        vm.isDropTargeted = false
        // The display that held the keyboard has gone with it. Stated rather
        // than inferred: the two flags above may already have been false, in
        // which case their publisher says nothing at all.
        keyboardIsClaimed = false
        // The display went away mid-session. That is a disappearance, not the
        // user finishing something, so the session is dropped without reporting
        // an idle moment.
        sessionHadMeaningfulUse = false
        applyKeyboardOwnership()
        pointer.setInside(false)
        coordinator.activeSurface?.setExpanded(false)
        guard vm.isOpen else { return }
        vm.isOpen = false
        deactivateServices(vm)
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
        keyboardIsClaimed = wants
        if wants {
            setOpen(true)
            pointer.setInside(true, display: coordinator.activeDisplayID)
        }
        applyKeyboardOwnership()
        // What was typed stays: clicking away to look something up should not
        // be the same as throwing the text out. Esc and the ✕ do that.
        if !wants { scheduleCollapseIfPointerAway() }
    }

    /// Gives the keyboard to whichever surface is active, and to no other.
    ///
    /// Called from both directions — when the claim changes, and when the
    /// display holding it changes — because those are two separate events and
    /// either one alone leaves the window and the claim disagreeing. Moving
    /// display without this is what left a translation on the second monitor
    /// with no caret in it: the panel travelled, the keyboard did not.
    ///
    /// Assigning `false` before `true` is not merely tidy. `NotchPanel` resigns
    /// key by ordering out and straight back in, so a surface that still
    /// believed it accepted keys while another took them would leave two
    /// windows fighting over key status across two displays.
    private func applyKeyboardOwnership() {
        for surface in coordinator.allSurfaces where !surface.isActive {
            surface.acceptsKeyboard = false
        }
        coordinator.activeSurface?.acceptsKeyboard = keyboardIsClaimed
    }

    /// The pointer decides, always. A field with something in it does not hold
    /// the panel open: it is opened by hovering, and anything that survives the
    /// pointer leaving would have to be dismissed some other way, which is a
    /// second rule to learn for a panel that has exactly one. What was typed is
    /// kept, so coming back finds it where it was left.
    private func setOpen(_ open: Bool) {
        guard let vm = viewModel else { return }
        if open {
            collapseIntentGeneration += 1
            coordinator.activeSurface?.setMotionPlan(currentPanelMotionPlan())
            guard !requestedOpen || !vm.isOpen else { return }
            requestedOpen = true
            openGeneration += 1
            let generation = openGeneration
            isClosing = false
            // Re-entry while the keyboard-resignation turn is pending reaches
            // here with `vm.isOpen == true`. Advancing the generation is the
            // cancellation; the stale close can no longer fold under the mouse.
            guard !vm.isOpen else {
                // An established open already owns its foreground services.
                // Re-entry still has to commit the active surface when a
                // display handoff happened during the keyboard-release turn:
                // `moveActivation` prepared the new host with the previous
                // generation, which this command has just invalidated.
                if coordinator.activeSurface?.isExpanded != true || !servicesAreActive {
                    scheduleExpansionCommit(for: generation, viewModel: vm)
                }
                return
            }
            // Grow the interactive area first so the pointer never falls
            // through a region the animation has not covered yet.
            applyActiveRect(open: true)
            // Told explicitly rather than read from the view model: `isOpen` is
            // still false for one more statement, and a zone built from it here
            // would leave the expanded panel with a collapsed click target.
            refreshPointerZones(open: true)
            vm.isOpen = true
            // A newly active host first commits its collapsed shell. Expansion
            // begins on the next main turn, with one atomic surface-state send.
            coordinator.activeSurface?.prepareForExpansion()
            scheduleExpansionCommit(for: generation, viewModel: vm)
        } else {
            guard requestedOpen || vm.isOpen else { return }
            requestedOpen = false
            openGeneration += 1
            let generation = openGeneration
            if vm.keyboardNavigationActive { vm.keyboardNavigationActive = false }
            // The keyboard goes first and the fold goes second — one run-loop
            // pass apart, never together. Dropped in the same pass, resigning
            // the field's first responder and structurally removing that field
            // land in one transaction, and SwiftUI applies the state but loses
            // the repaint: the panel stands on screen fully expanded with
            // `isOpen` already false, wedged until the next hover repaints it.
            // That was the translate tab "hanging open" — type, move the
            // pointer away, and the picture stayed while the state closed.
            if vm.wantsKeyboard { vm.wantsKeyboard = false }
            environment.deferToNextMainTurn { [weak self] in
                guard let self,
                      self.openGeneration == generation,
                      !self.requestedOpen else { return }
                self.collapse(generation: generation)
            }
        }
    }

    private func scheduleExpansionCommit(for generation: Int, viewModel vm: NotchViewModel) {
        let displayID = coordinator.activeDisplayID
        environment.deferToNextMainTurn { [weak self, weak vm] in
            guard let self, let vm,
                  self.openGeneration == generation,
                  self.requestedOpen,
                  vm.isOpen,
                  self.coordinator.activeDisplayID == displayID else { return }
            self.coordinator.activeSurface?.commitPreparedLayout()
            self.coordinator.activeSurface?.setExpanded(true)
            // Cached pane state draws the transition. Foreground refreshes
            // start only after the final visual frame.
            self.scheduleServiceActivation(for: generation, viewModel: vm)
        }
    }

    private func scheduleServiceActivation(for generation: Int, viewModel vm: NotchViewModel) {
        let displayID = coordinator.activeDisplayID
        let activate = { [weak self, weak vm] in
            guard let self, let vm,
                  self.openGeneration == generation,
                  self.requestedOpen,
                  vm.isOpen,
                  self.coordinator.activeDisplayID == displayID,
                  self.coordinator.activeSurface?.isExpanded == true,
                  !self.servicesAreActive else { return }
            self.servicesAreActive = true
            self.foregroundServiceActivationCount += 1
            vm.media.setActive(true)
            vm.calendar.setActive(true)
            vm.power.setActive(true)
            vm.devices.setActive(true)
        }
        let duration = coordinator.activeSurface?.motionPlan.openDuration
            ?? currentPanelMotionPlan().openDuration
        if duration == 0 {
            // Even an instant visual state gets one commit before stores begin
            // publishing; there is simply no travel duration to wait out.
            environment.deferToNextMainTurn(activate)
        } else {
            // Cached pane state is enough for the morph. IOKit, calendar,
            // media and device refreshes start only after its final frame.
            environment.scheduleAfter(duration, activate)
        }
    }

    /// The visual half of closing, one pass after the keyboard was let go.
    private func collapse(generation: Int) {
        guard let vm = viewModel,
              openGeneration == generation,
              !requestedOpen,
              vm.isOpen else { return }
        isClosing = true
        coordinator.activeSurface?.setMotionPlan(currentPanelMotionPlan())
        coordinator.activeSurface?.beginClosing()
        vm.isOpen = false
        deactivateServices(vm)
        // Shrink only once the panel has finished collapsing. Doing it
        // while it is still visibly there would leave a window in which
        // clicks land on whatever is behind the panel.
        let finishInteraction = { [weak self] in
            guard let self,
                  self.openGeneration == generation,
                  !self.requestedOpen,
                  self.viewModel?.isOpen == false else { return }
            self.isClosing = false
            self.applyActiveRect(open: false)
            self.refreshPointerZones(open: false)
            // The panel is folded and its hit region has shrunk back to the
            // anchor: Impuls is out of the user's way. Anything the app wants to
            // say for itself belongs here and nowhere else in this file.
            self.notifyReturnedToIdle()
        }
        let plan = coordinator.activeSurface?.motionPlan ?? currentPanelMotionPlan()
        let delay = plan.closeDuration
        if delay == 0 {
            finishInteraction()
        } else {
            environment.scheduleAfter(delay, finishInteraction)
        }

        let finishContent = { [weak self] in
            guard let self,
                  self.openGeneration == generation,
                  !self.requestedOpen,
                  self.viewModel?.isOpen == false else { return }
            self.coordinator.activeSurface?.finishClosing()
        }
        if plan.contentCloseDuration == 0 {
            finishContent()
        } else {
            environment.scheduleAfter(plan.contentCloseDuration, finishContent)
        }
    }

    /// Reports one quiet transition, and only for a session the user actually
    /// worked in. A panel that opened on hover and folded again untouched says
    /// nothing: there was no interaction to have finished.
    private func notifyReturnedToIdle() {
        guard sessionHadMeaningfulUse else { return }
        sessionHadMeaningfulUse = false
        onReturnedToIdle?()
    }

    private func deactivateServices(_ vm: NotchViewModel) {
        guard servicesAreActive else { return }
        servicesAreActive = false
        vm.media.setActive(false)
        vm.calendar.setActive(false)
        vm.power.setActive(false)
        vm.devices.setActive(false)
    }

    private func currentPanelMotionPlan() -> Theme.PanelMotionPlan {
        .make(reducesMotion: environment.reducesMotion())
    }

    /// Reduce Motion can change while the panel is already visible. One
    /// controller-owned plan is published to the active SwiftUI surface and
    /// used for controller completion timing, so the mask, hit region and
    /// service deadline cannot sample different accessibility states.
    private func accessibilityDisplayOptionsChanged() {
        let plan = currentPanelMotionPlan()
        // The workspace notification also reports contrast/transparency
        // changes. Those are handled reactively by SwiftUI/AppKit and must not
        // cancel an unrelated panel transition.
        guard coordinator.activeSurface?.motionPlan.reducesMotion != plan.reducesMotion else { return }
        for surface in coordinator.allSurfaces { surface.setMotionPlan(plan) }
        guard let vm = viewModel else { return }

        if isClosing {
            // The mask is replaced at its closed endpoint by the motion-plan
            // identity. Retire interaction and outgoing accessibility content
            // in the same turn instead of leaving an old-duration completion.
            openGeneration += 1
            isClosing = false
            coordinator.activeSurface?.finishClosing()
            applyActiveRect(open: false)
            refreshPointerZones(open: false)
        } else if requestedOpen, vm.isOpen, !servicesAreActive {
            // An in-flight spatial opening snaps to its endpoint when Reduce
            // Motion is enabled. Replace its delayed foreground deadline too.
            openGeneration += 1
            let generation = openGeneration
            if coordinator.activeSurface?.isExpanded == true {
                scheduleServiceActivation(for: generation, viewModel: vm)
            } else {
                scheduleExpansionCommit(for: generation, viewModel: vm)
            }
        }
    }

    private func keepsExpandedHitRegion(_ vm: NotchViewModel) -> Bool {
        vm.isOpen || isClosing
    }

    private func scheduleCollapseIfPointerAway() {
        let generation = collapseIntentGeneration
        environment.scheduleAfter(0.6) { [weak self] in
            guard let self, let vm = self.viewModel,
                  generation == self.collapseIntentGeneration,
                  let surface = self.coordinator.activeSurface else { return }
            guard !vm.keyboardNavigationActive,
                  !vm.isDropTargeted,
                  !self.menuTrackingState.isHoldingPanelOpen,
                  !surface.isReceivingDrag else { return }
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

        pointer.setInside(true, display: coordinator.activeDisplayID)
        // Invalidate both halves of a close that may already have been queued
        // in the same run-loop turn as the right click. Going through the
        // command also recovers cleanly if tracking began just after collapse.
        setOpen(true)
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

    private func refreshDisplaysAndTopology() {
        isRefreshingDisplays = true
        settings.refreshDisplays()
        isRefreshingDisplays = false
        topologyRefreshWork?.cancel()
        topologyRefreshWork = nil
        refreshTopology()
    }

    private func scheduleTopologyRefresh() {
        guard viewModel != nil, !isRefreshingDisplays else { return }
        topologyRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.topologyRefreshWork = nil
            self.refreshTopology()
        }
        topologyRefreshWork = work
        DispatchQueue.main.async(execute: work)
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
