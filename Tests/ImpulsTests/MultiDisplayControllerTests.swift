import AppKit
import XCTest
@testable import ImpulsCore

// MARK: - Doubles

/// A display surface with no window in it.
///
/// The live `NotchDisplaySurface` is an `NSPanel`, an `NSHostingView` and a
/// SwiftUI hierarchy; none of that can be driven from a command-line test, and
/// none of it is what these tests are about. What they are about is routing —
/// which display ends up with the panel — and that is entirely in the
/// controller and the coordinator.
@MainActor
final class FakeDisplaySurface: NotchSurfacing {
    let displayID: UInt32
    private(set) var geometry: NotchGeometry
    private(set) var isActive = false
    private(set) var isExpanded = false
    private(set) var hasMountedContent = false
    private(set) var motionPlan = Theme.PanelMotionPlan.make(reducesMotion: false)
    private(set) var preparedLayoutCommitCount = 0
    var isReceivingDrag = false
    var acceptsKeyboard = false {
        didSet {
            guard acceptsKeyboard != oldValue else { return }
            onStateChange?()
        }
    }
    private(set) var isInteractive = false
    private(set) var isTornDown = false
    private(set) var lastAppliedRectWasOpen: Bool?
    private(set) var appliedRectLog: [Bool] = []
    private(set) var geometryUpdates = 0
    /// Every activation change, in order, so a test can prove the panel moved
    /// once rather than flickering between two displays.
    private(set) var activationLog: [Bool] = []
    /// Set by the harness to a closure that fails the test if more than one
    /// surface is ever active or key at the same instant — checked inside the
    /// mutation, not after it, so a momentary overlap between two statements
    /// cannot slip past.
    var onStateChange: (() -> Void)?

    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onDrop: (([URL]) -> Bool)?
    var onPress: (() -> Void)?
    var onKeyCommand: ((NotchPanel.KeyCommand) -> Void)?

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        displayID = geometry.display.id
    }

    func owns(_ window: NSWindow) -> Bool { false }

    func update(geometry: NotchGeometry) {
        guard self.geometry != geometry else { return }
        self.geometry = geometry
        geometryUpdates += 1
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        if !active { isExpanded = false }
        if !active { hasMountedContent = false }
        isActive = active
        activationLog.append(active)
        if !active { acceptsKeyboard = false }
        onStateChange?()
    }

    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        hasMountedContent = expanded
        onStateChange?()
    }

    func prepareForExpansion() { hasMountedContent = true }

    func commitPreparedLayout() {
        guard hasMountedContent, !isExpanded else { return }
        preparedLayoutCommitCount += 1
    }

    func setMotionPlan(_ plan: Theme.PanelMotionPlan) { motionPlan = plan }

    func beginClosing() {
        guard hasMountedContent else { return }
        isExpanded = false
        onStateChange?()
    }

    func finishClosing() { hasMountedContent = false }

    func setInteractive(_ interactive: Bool) { isInteractive = interactive }

    @discardableResult
    func applyActiveRect(open: Bool) -> CGRect {
        lastAppliedRectWasOpen = open
        appliedRectLog.append(open)
        return geometry.contentScreenRect(for: open ? geometry.expandedSize : geometry.collapsedSize)
    }

    /// Mirrors `NotchDisplaySurface.teardown` exactly. A double that forgets to
    /// stand itself down would let a test pass while the real surface leaked an
    /// active, key-accepting window for a display that is no longer attached.
    func teardown() {
        setActive(false)
        isExpanded = false
        hasMountedContent = false
        acceptsKeyboard = false
        isTornDown = true
    }
}

final class SilentDisplayAlertDelivery: LowBatteryNotificationDelivering, @unchecked Sendable {
    var onNotificationOpened: (@MainActor @Sendable (String?) -> Void)?
    func authorizationStatus() async -> LowBatteryNotificationAuthorization { .denied }
    func requestAuthorization() async -> LowBatteryNotificationAuthorization { .denied }
    func deliver(_ notification: LowBatteryNotification) async throws {}
}

final class MemoryDisplayAlertStore: LowBatteryAlertStateStoring {
    var data: Data?
    func load() -> Data? { data }
    func save(_ data: Data) { self.data = data }
}

/// One Impuls, one set of displays, one pointer — all of them settable.
@MainActor
final class DisplayHarness {
    let settings: SettingsStore
    private(set) var controller: NotchController!
    private(set) var surfaces: [UInt32: FakeDisplaySurface] = [:]
    /// Every surface ever built, including ones since torn down, so a test can
    /// prove a disconnected display's surface was released rather than leaked.
    private(set) var builtSurfaces: [FakeDisplaySurface] = []
    private(set) var viewModelsBuilt = 0
    private(set) var servicesStarted = 0
    private(set) var descriptorReads = 0

    var reducesMotion = false
    private var nextTurnOperations: [@MainActor () -> Void] = []
    private var delayedOperations: [(delay: TimeInterval, operation: @MainActor () -> Void)] = []

    var displays: [DisplayDescriptor]
    var pointer: CGPoint
    var mainDisplayID: UInt32?
    /// The clock the sampler measures dwell against. Moved by hand, so a hover
    /// costs no wall-clock time and never depends on timer scheduling.
    var clock = Date(timeIntervalSince1970: 1_000_000)
    /// Every `(inside, display)` the sampler decided, in order. A hover that
    /// crosses from one display to another has to be one transition, not a
    /// close followed by an open.
    private(set) var pointerTransitions: [(inside: Bool, display: UInt32?)] = []
    /// The high-water marks of the two invariants, sampled inside every state
    /// change rather than after it.
    private(set) var observedMaximumActive = 0
    private(set) var observedMaximumExpanded = 0
    private(set) var observedMaximumKeyboard = 0

    private let suite: String
    private let defaults: UserDefaults

    /// This harness's own `Application Support/Impuls`, one per instance and
    /// deleted with it.
    ///
    /// Not a stub and not a switched-off flush: the stores here write, debounce
    /// and flush exactly as they do in the app, into a directory nobody else
    /// owns. It exists because `NotchViewModel` builds every store, so a test
    /// about displays used to inherit the real notes file and rewrite it on
    /// `stop()`.
    let storageFolder: URL
    var notesFile: URL { storageFolder.appendingPathComponent("notes.json") }
    var snippetsFile: URL { storageFolder.appendingPathComponent("snippets.json") }

    init(displays: [DisplayDescriptor], pointer: CGPoint = .zero, mainDisplayID: UInt32? = nil) {
        self.displays = displays
        self.pointer = pointer
        self.mainDisplayID = mainDisplayID
        suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        storageFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("impuls-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: storageFolder,
            withIntermediateDirectories: true
        )
        settings = SettingsStore(
            defaults: defaults,
            lowBatteryAlerts: LowBatteryAlertService(
                engine: LowBatteryAlertEngine(store: MemoryDisplayAlertStore(), now: Date()),
                delivery: SilentDisplayAlertDelivery()
            )
        )
        // Settings reads the display list itself, for its picker. Point it at
        // the same synthetic arrangement, or `refreshDisplays` would compare a
        // chosen display against whatever is really plugged into the machine
        // running the suite and clear the choice.
        settings.displaySource = { [unowned self] in self.displays }
        settings.refreshDisplays()

        let environment = NotchEnvironment(
            descriptors: { [unowned self] in
                self.descriptorReads += 1
                return self.displays
            },
            mainDisplayID: { [unowned self] in self.mainDisplayID },
            pointerLocation: { [unowned self] in self.pointer },
            now: { [unowned self] in self.clock },
            reducesMotion: { [unowned self] in self.reducesMotion },
            deferToNextMainTurn: { [unowned self] operation in
                self.nextTurnOperations.append(operation)
            },
            scheduleAfter: { [unowned self] delay, operation in
                self.delayedOperations.append((delay, operation))
            },
            storage: StorageEnvironment(
                notes: storageFolder.appendingPathComponent("notes.json"),
                snippets: storageFolder.appendingPathComponent("snippets.json"),
                // See `StorageEnvironment.makeClipboardHistory`: a temporary
                // archive would still share the one keychain key with the user's
                // real history, and switching persistence off deletes it.
                makeClipboardHistory: { nil }
            ),
            makeSurface: { [unowned self] geometry, _ in
                self.viewModelsBuilt = max(self.viewModelsBuilt, 1)
                let surface = FakeDisplaySurface(geometry: geometry)
                // The two invariants the whole design rests on, checked at every
                // mutation rather than at the end of a test: at most one surface
                // active, at most one willing to take keys. A momentary overlap
                // between two statements would be caught here.
                surface.onStateChange = { [unowned self] in
                    self.observedMaximumActive = max(self.observedMaximumActive, self.activeSurfaceCount)
                    self.observedMaximumExpanded = max(self.observedMaximumExpanded, self.expandedSurfaceCount)
                    self.observedMaximumKeyboard = max(
                        self.observedMaximumKeyboard,
                        self.keyboardOwningSurfaceCount
                    )
                }
                self.surfaces[surface.displayID] = surface
                self.builtSurfaces.append(surface)
                return surface
            },
            // Deliberately does not start the clipboard watcher, the media
            // poller or the calendar: this is a test about displays.
            startServices: { [unowned self] _ in self.servicesStarted += 1 }
        )
        controller = NotchController(settings: settings, environment: environment)
    }

    func install() {
        controller.install()
        // The sampler's own timer is stopped and every sample is taken by hand
        // below. Nothing about the routing changes — `tick()` is the same method
        // the timer calls — but the test stops depending on when a run loop
        // happens to fire.
        controller.pointerSampler.stop()
        let previous = controller.pointerSampler.onChange
        controller.pointerSampler.onChange = { [unowned self] inside, display in
            self.pointerTransitions.append((inside: inside, display: display))
            previous?(inside, display)
        }
    }

    /// `teardown()` reaches `NotchViewModel.stop()`, which flushes the notes
    /// synchronously. That is allowed to happen — it is the production path —
    /// because by now it writes into this harness's own directory, which is
    /// removed immediately afterwards.
    func tearDown() {
        controller.teardown()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: storageFolder)
    }

    // MARK: Driving the real pointer sampler

    /// Takes one sample at the current position and clock.
    func sample() { controller.pointerSampler.tick() }

    /// Drains exactly one queued main-loop turn. Work scheduled by that work
    /// remains queued for the next explicit drain, matching DispatchQueue.main.
    func drainNextTurn() {
        let operations = nextTurnOperations
        nextTurnOperations.removeAll()
        operations.forEach { $0() }
    }

    func drainDelayed() {
        let operations = delayedOperations
        delayedOperations.removeAll()
        operations.forEach { $0.operation() }
    }

    /// Runs only work for one semantic deadline. Service activation (0.22),
    /// visual close completion (0.16) and pointer-away checks (0.6) share the
    /// production scheduler but are distinct events in transition tests.
    func drainDelayed(at delay: TimeInterval) {
        let matching = delayedOperations.filter { $0.delay == delay }
        delayedOperations.removeAll { $0.delay == delay }
        matching.forEach { $0.operation() }
    }

    func drainFirstDelayed(at delay: TimeInterval) {
        guard let index = delayedOperations.firstIndex(where: { $0.delay == delay }) else { return }
        let operation = delayedOperations.remove(at: index).operation
        operation()
    }

    var scheduledDelays: [TimeInterval] { delayedOperations.map(\.delay) }

    /// Moves the pointer and lets the sampler resolve it: one sample to notice
    /// the new position, the clock advanced past the dwell, one more to commit.
    /// This is the production path — `PointerWatcher.hit`, the dwell, `onChange`,
    /// `moveActivation` — and not an imitation of it.
    func movePointer(to point: CGPoint, dwell: TimeInterval = 1) {
        pointer = point
        sample()
        clock = clock.addingTimeInterval(dwell)
        sample()
    }

    /// A pointer that crosses a region without stopping: sampled twice with
    /// less time between the samples than any dwell threshold.
    func sweepPointer(through points: [CGPoint], step: TimeInterval = 0.005) {
        for point in points {
            pointer = point
            sample()
            clock = clock.addingTimeInterval(step)
        }
    }

    /// A point inside the collapsed hover target of a display.
    func anchor(of displayID: UInt32) -> CGPoint {
        let rect = surface(displayID).geometry.hoverRect
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    /// A point inside the expanded panel of a display.
    func panelCentre(of displayID: UInt32) -> CGPoint {
        let rect = surface(displayID).geometry.expandedHoverRect
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    /// Somewhere on a display but nowhere near Impuls.
    func emptyDesktop(of displayID: UInt32) -> CGPoint {
        let frame = surfaces[displayID]!.geometry.display.frame
        return CGPoint(x: frame.midX, y: frame.minY + 40)
    }

    var activeSurfaceCount: Int { surfaces.values.filter(\.isActive).count }
    var expandedSurfaceCount: Int { surfaces.values.filter(\.isExpanded).count }
    var keyboardOwningSurfaceCount: Int { surfaces.values.filter(\.acceptsKeyboard).count }

    /// Re-runs the topology reconciliation the way a screen-parameter
    /// notification does, after `displays` has been changed.
    func reconnectDisplays() {
        settings.refreshDisplays()
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func surface(_ id: UInt32) -> FakeDisplaySurface { surfaces[id]! }
    var vm: NotchViewModel { controller.viewModel! }
}

// MARK: - Fixtures

enum DisplayLayout {
    /// MacBook on the left, a 4K monitor to its right.
    static let macBook = DisplayFixtures.macBook()
    static let monitor = DisplayFixtures.plain(
        id: 2,
        name: "Monitor",
        origin: CGPoint(x: 1512, y: 0),
        size: CGSize(width: 2560, height: 1440)
    )
    static let sidecar = DisplayFixtures.plain(
        id: 3,
        name: "iPad",
        origin: CGPoint(x: -1180, y: 0),
        size: CGSize(width: 1180, height: 820)
    )

    static let onMacBook = CGPoint(x: 700, y: 500)
    static let onMonitor = CGPoint(x: 3000, y: 900)
    static let onSidecar = CGPoint(x: -600, y: 400)
}

// MARK: - Tests

@MainActor
final class MultiDisplayControllerTests: XCTestCase {

    func testActivationModeRefreshUsesTheCommittedSetting() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        XCTAssertFalse(harness.controller.pointerSampler.zones[0].openRect.isEmpty)
        harness.settings.activationMode = .shortcutOnly
        harness.drainNextTurn()

        XCTAssertTrue(harness.controller.pointerSampler.zones[0].openRect.isEmpty)
        XCTAssertFalse(harness.controller.pointerSampler.tracksPanelExit)

        harness.settings.activationMode = .hoverAndShortcut
        harness.drainNextTurn()
        XCTAssertFalse(harness.controller.pointerSampler.zones[0].openRect.isEmpty)
        XCTAssertTrue(harness.controller.pointerSampler.tracksPanelExit)
    }

    func testOpenDelayRefreshUsesTheCommittedSetting() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.settings.openDelay = .deliberate
        harness.drainNextTurn()

        XCTAssertEqual(harness.controller.pointerSampler.openDelay, 0.30)
    }

    func testSecondShortcutDuringDeferredCloseReopensInsteadOfClosingAgain() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.controller.toggleFromKeyboard()
        harness.drainNextTurn()
        XCTAssertTrue(harness.vm.isOpen)

        harness.controller.toggleFromKeyboard()
        XCTAssertTrue(harness.vm.isOpen, "visual close waits one keyboard-release turn")
        harness.controller.toggleFromKeyboard()
        harness.drainNextTurn()

        XCTAssertTrue(harness.vm.isOpen)
        XCTAssertTrue(harness.surface(1).isExpanded)
        XCTAssertTrue(harness.vm.keyboardNavigationActive)
        XCTAssertFalse(harness.scheduledDelays.contains(0.16))
    }

    // MARK: Shared view model lifecycle

    func testOneViewModelAndOneSetOfServicesSurviveEveryTopologyChange() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        let viewModel = harness.vm
        let clipboard = ObjectIdentifier(viewModel.clipboard)
        let power = ObjectIdentifier(viewModel.power)
        let devices = ObjectIdentifier(viewModel.devices)
        let media = ObjectIdentifier(viewModel.media)
        let calendar = ObjectIdentifier(viewModel.calendar)

        // Plug in a monitor, then a Sidecar iPad, then pull them both out.
        harness.displays = [DisplayLayout.macBook, DisplayLayout.monitor]
        harness.reconnectDisplays()
        harness.displays = [DisplayLayout.macBook, DisplayLayout.monitor, DisplayLayout.sidecar]
        harness.reconnectDisplays()
        harness.displays = [DisplayLayout.macBook, DisplayLayout.sidecar]
        harness.reconnectDisplays()
        harness.displays = [DisplayLayout.macBook]
        harness.reconnectDisplays()

        XCTAssertTrue(harness.vm === viewModel, "the view model is built once for the life of the app")
        XCTAssertEqual(ObjectIdentifier(harness.vm.clipboard), clipboard, "one clipboard watcher")
        XCTAssertEqual(ObjectIdentifier(harness.vm.power), power, "one PowerMonitor")
        XCTAssertEqual(ObjectIdentifier(harness.vm.devices), devices, "one Apple device centre")
        XCTAssertEqual(ObjectIdentifier(harness.vm.media), media)
        XCTAssertEqual(ObjectIdentifier(harness.vm.calendar), calendar)
        XCTAssertEqual(harness.servicesStarted, 1, "services are started once, not once per display change")
    }

    func testAnUnchangedDisplayKeepsItsSurfaceAcrossAHotPlug() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        let original = harness.surface(1)

        harness.displays = [DisplayLayout.macBook, DisplayLayout.monitor]
        harness.reconnectDisplays()

        XCTAssertTrue(harness.surface(1) === original, "the display that did not move keeps its window")
        XCTAssertEqual(original.geometryUpdates, 0, "and is not even re-laid-out")
        XCTAssertFalse(original.isTornDown)
        XCTAssertEqual(harness.controller.presentedDisplayIDs, [1, 2])
    }

    func testADisconnectedDisplayIsTornDownAndForgotten() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.sidecar], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        let sidecar = harness.surface(3)

        harness.displays = [DisplayLayout.macBook]
        harness.reconnectDisplays()

        XCTAssertTrue(sidecar.isTornDown, "an unplugged display's window is released, not left on screen")
        XCTAssertEqual(harness.controller.presentedDisplayIDs, [1])
        XCTAssertNotEqual(harness.controller.activeDisplayID, 3)
    }

    // MARK: Active display A → B

    /// The click path, named for what it actually exercises.
    ///
    /// It used to be called `testHoveringTheSecondDisplayMovesTheWholePanelToIt`
    /// while calling `onPress`, which is the press path — so it went green while
    /// hover, the thing it claimed to cover, carried a keyboard-handoff bug all
    /// the way to review. The hover tests below drive `PointerWatcher` itself.
    func testPressingTheAnchorOnTheSecondDisplayMovesTheWholePanelToIt() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        // Open on the MacBook, on a module that types.
        harness.controller.toggleFromKeyboard()
        XCTAssertEqual(harness.controller.activeDisplayID, 1)
        XCTAssertTrue(harness.vm.isOpen)
        harness.vm.select(.translate)
        harness.vm.translator.input = "мультидисплей"
        XCTAssertTrue(harness.surface(1).isActive)
        XCTAssertTrue(harness.surface(1).acceptsKeyboard)

        // The pointer arrives at the monitor's anchor.
        harness.pointer = DisplayLayout.onMonitor
        harness.surface(2).onPress?()

        XCTAssertEqual(harness.controller.activeDisplayID, 2)
        XCTAssertTrue(harness.surface(2).isActive)
        XCTAssertFalse(harness.surface(1).isActive, "the panel it came from is folded")
        XCTAssertFalse(harness.surface(1).acceptsKeyboard, "and no longer takes keys")
        XCTAssertEqual(
            harness.surfaces.values.filter(\.isActive).count,
            1,
            "exactly one expanded panel exists at any moment"
        )
        XCTAssertEqual(harness.vm.tab, .translate, "the same module travels")
        XCTAssertEqual(harness.vm.translator.input, "мультидисплей", "and so does what was typed")
    }

    func testTheShortcutOpensOnTheDisplayThePointerIsOn() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMonitor)
        defer { harness.tearDown() }
        harness.install()

        harness.controller.toggleFromKeyboard()

        XCTAssertEqual(harness.controller.activeDisplayID, 2, "issue #34: not the notched display")
        XCTAssertTrue(harness.vm.isOpen)
        XCTAssertTrue(harness.surface(2).isActive)
        XCTAssertFalse(harness.surface(1).isActive)
    }

    func testTheShortcutFallsBackToTheMainDisplayWhenThePointerIsNowhere() {
        let harness = DisplayHarness(
            displays: [DisplayLayout.macBook, DisplayLayout.monitor],
            // Between the two displays, on neither of them.
            pointer: CGPoint(x: 1_000_000, y: 1_000_000),
            mainDisplayID: 2
        )
        defer { harness.tearDown() }
        harness.install()

        harness.controller.toggleFromKeyboard()

        XCTAssertEqual(harness.controller.activeDisplayID, 2)
    }

    func testTheActiveDisplayDisappearingFoldsThePanelAndKeepsEverythingElse() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.sidecar], pointer: DisplayLayout.onSidecar)
        defer { harness.tearDown() }
        harness.install()

        harness.controller.toggleFromKeyboard()
        harness.vm.select(.translate)
        // The translator rather than the notes only because it holds the state
        // without touching a file at all. The notes would now be safe too — the
        // harness gives every store a temporary directory — but the cheapest
        // thing that proves the point is still the right one.
        harness.vm.translator.input = "survives the iPad going away"
        XCTAssertEqual(harness.controller.activeDisplayID, 3)
        XCTAssertTrue(harness.vm.isOpen)

        // Sidecar is disconnected while the panel is expanded on it.
        harness.displays = [DisplayLayout.macBook]
        harness.pointer = DisplayLayout.onMacBook
        harness.reconnectDisplays()

        XCTAssertFalse(harness.vm.isOpen, "the panel folds rather than pointing at a display that is gone")
        XCTAssertFalse(harness.vm.wantsKeyboard)
        XCTAssertFalse(harness.vm.keyboardNavigationActive)
        XCTAssertEqual(harness.controller.activeDisplayID, 1, "Impuls stays usable on what is left")
        XCTAssertEqual(harness.vm.translator.input, "survives the iPad going away", "nothing typed is lost")
        XCTAssertEqual(harness.vm.tab, .translate, "and the module is where it was")
    }

    func testOnlyTheActiveSurfaceIsEverOfferedTheKeyboard() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor, DisplayLayout.sidecar], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.controller.toggleFromKeyboard()
        harness.vm.select(.translate)

        for id in [UInt32(1), 2, 3] {
            XCTAssertEqual(
                harness.surface(id).acceptsKeyboard,
                harness.controller.activeDisplayID == id,
                "display \(id)"
            )
        }
        XCTAssertEqual(harness.surfaces.values.filter(\.acceptsKeyboard).count, 1)
    }

    // MARK: Drag and drop

    func testDroppingAFileOnTheSecondDisplayOpensTheShelfThere() throws {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()
        XCTAssertEqual(harness.controller.activeDisplayID, 1)

        let file = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }

        // The drag enters the monitor's anchor, not the MacBook's notch.
        harness.pointer = DisplayLayout.onMonitor
        harness.surface(2).isReceivingDrag = true
        harness.surface(2).onDragEntered?()

        XCTAssertEqual(harness.controller.activeDisplayID, 2)
        XCTAssertEqual(harness.vm.tab, .shelf)
        XCTAssertTrue(harness.vm.isDropTargeted)

        let accepted = harness.surface(2).onDrop?([file]) ?? false

        XCTAssertTrue(accepted)
        XCTAssertEqual(harness.controller.activeDisplayID, 2, "the shelf stays on the display it was dropped on")
        XCTAssertFalse(harness.vm.isDropTargeted)
        XCTAssertEqual(harness.vm.shelf.items.count, 1, "one shelf, one copy of the file")
    }

    func testOnlyOneDisplayIsADropTargetAtATime() throws {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        let file = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }

        harness.surface(1).onDragEntered?()
        XCTAssertEqual(harness.surfaces.values.filter(\.isActive).count, 1)
        XCTAssertEqual(harness.controller.activeDisplayID, 1)

        // The drag leaves the MacBook and arrives on the monitor.
        harness.surface(1).onDragExited?()
        harness.pointer = DisplayLayout.onMonitor
        harness.surface(2).onDragEntered?()

        XCTAssertEqual(harness.controller.activeDisplayID, 2)
        XCTAssertEqual(
            harness.surfaces.values.filter(\.isActive).count,
            1,
            "a file cannot be dropped into two Impuls panels"
        )

        _ = harness.surface(2).onDrop?([file])
        XCTAssertEqual(harness.vm.shelf.items.count, 1, "and it lands exactly once")
    }

    func testDragEnterCancelsAPendingCloseAndAcceptsTheURLOnce() throws {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()
        let file = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }

        harness.movePointer(to: harness.anchor(of: 1))
        harness.drainNextTurn()
        harness.surface(1).onKeyCommand?(.close)

        harness.surface(1).isReceivingDrag = true
        harness.surface(1).onDragEntered?()
        let accepted = harness.surface(1).onDrop?([file]) ?? false
        harness.drainNextTurn()

        XCTAssertTrue(accepted)
        XCTAssertEqual(harness.vm.shelf.items.map(\.url), [file])
        XCTAssertEqual(harness.vm.tab, .shelf)
        XCTAssertTrue(harness.vm.isOpen)
        XCTAssertTrue(harness.surface(1).isExpanded)
        XCTAssertFalse(harness.scheduledDelays.contains(0.16), "the stale close never retires the live drop target")
        XCTAssertEqual(harness.expandedSurfaceCount, 1)
    }

    func testCancelledDragClearsTheDropTargetAndMayCloseNormally() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.surface(1).isReceivingDrag = true
        harness.surface(1).onDragEntered?()
        harness.drainNextTurn()
        XCTAssertTrue(harness.vm.isDropTargeted)

        harness.pointer = harness.emptyDesktop(of: 1)
        harness.surface(1).isReceivingDrag = false
        harness.surface(1).onDragEnded?()
        XCTAssertFalse(harness.vm.isDropTargeted)
        harness.drainDelayed(at: 0.6)
        harness.drainNextTurn()
        harness.drainDelayed(at: 0.16)

        XCTAssertFalse(harness.vm.isOpen)
        XCTAssertFalse(harness.surface(1).isExpanded)
    }

    // MARK: Notification → Power

    func testALowBatteryNotificationOpensPowerOnTheDisplayInUse() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMonitor)
        defer { harness.tearDown() }
        harness.install()
        XCTAssertTrue(harness.vm.visibleTabs.contains(.power))

        // The user is working on the monitor when the alert is clicked.
        harness.controller.openPower()

        XCTAssertEqual(harness.controller.activeDisplayID, 2, "the Power pane opens where the user is")
        XCTAssertEqual(harness.vm.tab, .power)
        XCTAssertTrue(harness.vm.isOpen)
        XCTAssertTrue(harness.vm.keyboardNavigationActive, "an intentional entrance, held open until dismissed")
        XCTAssertTrue(harness.surface(2).isActive)
        XCTAssertFalse(harness.surface(1).isActive)
    }

    func testANotificationWhileWorkingOnTheMacBookStillOpensThere() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.controller.openPower()

        XCTAssertEqual(harness.controller.activeDisplayID, 1)
        XCTAssertEqual(harness.vm.tab, .power)
    }

    func testPowerOpenCancelsADeferredCloseInsteadOfBeingClosedByIt() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 1))
        harness.drainNextTurn()
        harness.surface(1).onKeyCommand?(.close)

        harness.controller.openPower()
        harness.drainNextTurn()

        XCTAssertTrue(harness.vm.isOpen)
        XCTAssertTrue(harness.surface(1).isExpanded)
        XCTAssertEqual(harness.vm.tab, .power)
        XCTAssertTrue(harness.vm.keyboardNavigationActive)
        XCTAssertFalse(harness.scheduledDelays.contains(0.16), "the stale close never reaches visual completion")
        XCTAssertEqual(harness.expandedSurfaceCount, 1)
    }

    func testAStalePointerAwayCheckCannotCloseANewerPowerIntent() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.surface(1).isReceivingDrag = true
        harness.surface(1).onDragEntered?()
        harness.drainNextTurn()
        harness.surface(1).isReceivingDrag = false
        harness.surface(1).onDragExited?()
        harness.pointer = harness.emptyDesktop(of: 1)

        harness.controller.openPower()
        harness.drainDelayed(at: 0.6)
        harness.drainNextTurn()

        XCTAssertTrue(harness.vm.isOpen)
        XCTAssertTrue(harness.surface(1).isExpanded)
        XCTAssertEqual(harness.vm.tab, .power)
    }

    func testANotificationIsIgnoredWhenThePowerModuleIsOff() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMonitor)
        defer { harness.tearDown() }
        harness.install()
        harness.settings.setModule(.power, enabled: false)

        harness.controller.openPower()

        XCTAssertFalse(harness.vm.isOpen)
        XCTAssertNotEqual(harness.vm.tab, .power)
    }

    // MARK: Preference

    func testChoosingOneDisplayLeavesImpulsOnlyThere() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor, DisplayLayout.sidecar], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()
        XCTAssertEqual(harness.controller.presentedDisplayIDs.count, 3)

        harness.settings.selectedDisplayID = 2
        harness.reconnectDisplays()

        XCTAssertEqual(harness.controller.presentedDisplayIDs, [2])
        XCTAssertEqual(harness.controller.activeDisplayID, 2)
        XCTAssertTrue(harness.surface(1).isTornDown)
        XCTAssertTrue(harness.surface(3).isTornDown)

        // Even with the pointer on the MacBook, the shortcut honours the choice.
        harness.pointer = DisplayLayout.onMacBook
        harness.controller.toggleFromKeyboard()
        XCTAssertEqual(harness.controller.activeDisplayID, 2)
    }

    func testMirroredDisplaysProduceOneSurfaceInTheLiveController() {
        let mirror = DisplayFixtures.plain(
            id: 9,
            name: "Mirror",
            origin: .zero,
            size: DisplayLayout.macBook.frame.size,
            mirrorSourceID: 1
        )
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, mirror], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        XCTAssertEqual(harness.controller.presentedDisplayIDs, [1])
        XCTAssertNil(harness.surfaces[9])
    }

    // MARK: Panel size

    func testAutomaticGivesEachDisplayItsOwnPresetInOneRunningApp() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.settings.panelSize = .automatic
        harness.reconnectDisplays()

        XCTAssertEqual(harness.surface(1).geometry.expandedSize, AdaptivePanelLayout.standard)
        XCTAssertEqual(harness.surface(2).geometry.expandedSize, AdaptivePanelLayout.large)
    }

    func testRuntimeSettingsPublicationsDoNotReconcileDisplayTopology() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()
        let reads = harness.descriptorReads

        harness.settings.reportHotKeyRegistration(succeeded: false)
        harness.settings.updateAppleDeviceState(devices: [], diagnostics: [])
        harness.settings.refreshDisplays()

        XCTAssertEqual(
            harness.descriptorReads,
            reads,
            "runtime keyboard/device/display-list publications are not geometry invalidations"
        )
        XCTAssertEqual(harness.surfaces.values.map(\.geometryUpdates).reduce(0, +), 0)
    }

    private func makeTemporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("impuls-multidisplay-\(UUID().uuidString).txt")
        try Data("drop me".utf8).write(to: url)
        return url
    }
}
