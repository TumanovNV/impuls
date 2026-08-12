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
private final class FakeSurface: NotchSurfacing {
    let displayID: UInt32
    private(set) var geometry: NotchGeometry
    private(set) var isActive = false
    var isReceivingDrag = false
    var acceptsKeyboard = false
    private(set) var isInteractive = false
    private(set) var isTornDown = false
    private(set) var lastAppliedRectWasOpen: Bool?
    private(set) var geometryUpdates = 0

    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?
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
        isActive = active
        if !active { acceptsKeyboard = false }
    }

    func setInteractive(_ interactive: Bool) { isInteractive = interactive }

    @discardableResult
    func applyActiveRect(open: Bool) -> CGRect {
        lastAppliedRectWasOpen = open
        return geometry.contentScreenRect(for: open ? geometry.expandedSize : geometry.collapsedSize)
    }

    func teardown() { isTornDown = true }
}

private final class SilentAlertDelivery: LowBatteryNotificationDelivering, @unchecked Sendable {
    var onNotificationOpened: (@MainActor @Sendable (String?) -> Void)?
    func authorizationStatus() async -> LowBatteryNotificationAuthorization { .denied }
    func requestAuthorization() async -> LowBatteryNotificationAuthorization { .denied }
    func deliver(_ notification: LowBatteryNotification) async throws {}
}

private final class MemoryAlertStore: LowBatteryAlertStateStoring {
    var data: Data?
    func load() -> Data? { data }
    func save(_ data: Data) { self.data = data }
}

/// One Impuls, one set of displays, one pointer — all of them settable.
@MainActor
private final class Harness {
    let settings: SettingsStore
    private(set) var controller: NotchController!
    private(set) var surfaces: [UInt32: FakeSurface] = [:]
    /// Every surface ever built, including ones since torn down, so a test can
    /// prove a disconnected display's surface was released rather than leaked.
    private(set) var builtSurfaces: [FakeSurface] = []
    private(set) var viewModelsBuilt = 0
    private(set) var servicesStarted = 0

    var displays: [DisplayDescriptor]
    var pointer: CGPoint
    var mainDisplayID: UInt32?

    private let suite: String
    private let defaults: UserDefaults

    init(displays: [DisplayDescriptor], pointer: CGPoint = .zero, mainDisplayID: UInt32? = nil) {
        self.displays = displays
        self.pointer = pointer
        self.mainDisplayID = mainDisplayID
        suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        settings = SettingsStore(
            defaults: defaults,
            lowBatteryAlerts: LowBatteryAlertService(
                engine: LowBatteryAlertEngine(store: MemoryAlertStore(), now: Date()),
                delivery: SilentAlertDelivery()
            )
        )
        // Settings reads the display list itself, for its picker. Point it at
        // the same synthetic arrangement, or `refreshDisplays` would compare a
        // chosen display against whatever is really plugged into the machine
        // running the suite and clear the choice.
        settings.displaySource = { [unowned self] in self.displays }
        settings.refreshDisplays()

        let environment = NotchEnvironment(
            descriptors: { [unowned self] in self.displays },
            mainDisplayID: { [unowned self] in self.mainDisplayID },
            pointerLocation: { [unowned self] in self.pointer },
            makeSurface: { [unowned self] geometry, _ in
                self.viewModelsBuilt = max(self.viewModelsBuilt, 1)
                let surface = FakeSurface(geometry: geometry)
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

    func install() { controller.install() }

    func tearDown() {
        controller.teardown()
        defaults.removePersistentDomain(forName: suite)
    }

    /// Re-runs the topology reconciliation the way a screen-parameter
    /// notification does, after `displays` has been changed.
    func reconnectDisplays() {
        settings.refreshDisplays()
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func surface(_ id: UInt32) -> FakeSurface { surfaces[id]! }
    var vm: NotchViewModel { controller.viewModel! }
}

// MARK: - Fixtures

private enum Layout {
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

    // MARK: Shared view model lifecycle

    func testOneViewModelAndOneSetOfServicesSurviveEveryTopologyChange() {
        let harness = Harness(displays: [Layout.macBook], pointer: Layout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        let viewModel = harness.vm
        let clipboard = ObjectIdentifier(viewModel.clipboard)
        let power = ObjectIdentifier(viewModel.power)
        let devices = ObjectIdentifier(viewModel.devices)
        let media = ObjectIdentifier(viewModel.media)
        let calendar = ObjectIdentifier(viewModel.calendar)

        // Plug in a monitor, then a Sidecar iPad, then pull them both out.
        harness.displays = [Layout.macBook, Layout.monitor]
        harness.reconnectDisplays()
        harness.displays = [Layout.macBook, Layout.monitor, Layout.sidecar]
        harness.reconnectDisplays()
        harness.displays = [Layout.macBook, Layout.sidecar]
        harness.reconnectDisplays()
        harness.displays = [Layout.macBook]
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
        let harness = Harness(displays: [Layout.macBook], pointer: Layout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        let original = harness.surface(1)

        harness.displays = [Layout.macBook, Layout.monitor]
        harness.reconnectDisplays()

        XCTAssertTrue(harness.surface(1) === original, "the display that did not move keeps its window")
        XCTAssertEqual(original.geometryUpdates, 0, "and is not even re-laid-out")
        XCTAssertFalse(original.isTornDown)
        XCTAssertEqual(harness.controller.presentedDisplayIDs, [1, 2])
    }

    func testADisconnectedDisplayIsTornDownAndForgotten() {
        let harness = Harness(displays: [Layout.macBook, Layout.sidecar], pointer: Layout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        let sidecar = harness.surface(3)

        harness.displays = [Layout.macBook]
        harness.reconnectDisplays()

        XCTAssertTrue(sidecar.isTornDown, "an unplugged display's window is released, not left on screen")
        XCTAssertEqual(harness.controller.presentedDisplayIDs, [1])
        XCTAssertNotEqual(harness.controller.activeDisplayID, 3)
    }

    // MARK: Active display A → B

    func testHoveringTheSecondDisplayMovesTheWholePanelToIt() {
        let harness = Harness(displays: [Layout.macBook, Layout.monitor], pointer: Layout.onMacBook)
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
        harness.pointer = Layout.onMonitor
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
        let harness = Harness(displays: [Layout.macBook, Layout.monitor], pointer: Layout.onMonitor)
        defer { harness.tearDown() }
        harness.install()

        harness.controller.toggleFromKeyboard()

        XCTAssertEqual(harness.controller.activeDisplayID, 2, "issue #34: not the notched display")
        XCTAssertTrue(harness.vm.isOpen)
        XCTAssertTrue(harness.surface(2).isActive)
        XCTAssertFalse(harness.surface(1).isActive)
    }

    func testTheShortcutFallsBackToTheMainDisplayWhenThePointerIsNowhere() {
        let harness = Harness(
            displays: [Layout.macBook, Layout.monitor],
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
        let harness = Harness(displays: [Layout.macBook, Layout.sidecar], pointer: Layout.onSidecar)
        defer { harness.tearDown() }
        harness.install()

        harness.controller.toggleFromKeyboard()
        harness.vm.select(.translate)
        // Deliberately the translator and not the notes: `NoteStore` writes to
        // the real Application Support folder, and a test has no business
        // reaching the user's notes. What is being asserted — that state
        // survives a display vanishing — is the same either way.
        harness.vm.translator.input = "survives the iPad going away"
        XCTAssertEqual(harness.controller.activeDisplayID, 3)
        XCTAssertTrue(harness.vm.isOpen)

        // Sidecar is disconnected while the panel is expanded on it.
        harness.displays = [Layout.macBook]
        harness.pointer = Layout.onMacBook
        harness.reconnectDisplays()

        XCTAssertFalse(harness.vm.isOpen, "the panel folds rather than pointing at a display that is gone")
        XCTAssertFalse(harness.vm.wantsKeyboard)
        XCTAssertFalse(harness.vm.keyboardNavigationActive)
        XCTAssertEqual(harness.controller.activeDisplayID, 1, "Impuls stays usable on what is left")
        XCTAssertEqual(harness.vm.translator.input, "survives the iPad going away", "nothing typed is lost")
        XCTAssertEqual(harness.vm.tab, .translate, "and the module is where it was")
    }

    func testOnlyTheActiveSurfaceIsEverOfferedTheKeyboard() {
        let harness = Harness(displays: [Layout.macBook, Layout.monitor, Layout.sidecar], pointer: Layout.onMacBook)
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
        let harness = Harness(displays: [Layout.macBook, Layout.monitor], pointer: Layout.onMacBook)
        defer { harness.tearDown() }
        harness.install()
        XCTAssertEqual(harness.controller.activeDisplayID, 1)

        let file = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }

        // The drag enters the monitor's anchor, not the MacBook's notch.
        harness.pointer = Layout.onMonitor
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
        let harness = Harness(displays: [Layout.macBook, Layout.monitor], pointer: Layout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        let file = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }

        harness.surface(1).onDragEntered?()
        XCTAssertEqual(harness.surfaces.values.filter(\.isActive).count, 1)
        XCTAssertEqual(harness.controller.activeDisplayID, 1)

        // The drag leaves the MacBook and arrives on the monitor.
        harness.surface(1).onDragExited?()
        harness.pointer = Layout.onMonitor
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

    // MARK: Notification → Power

    func testALowBatteryNotificationOpensPowerOnTheDisplayInUse() {
        let harness = Harness(displays: [Layout.macBook, Layout.monitor], pointer: Layout.onMonitor)
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
        let harness = Harness(displays: [Layout.macBook, Layout.monitor], pointer: Layout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.controller.openPower()

        XCTAssertEqual(harness.controller.activeDisplayID, 1)
        XCTAssertEqual(harness.vm.tab, .power)
    }

    func testANotificationIsIgnoredWhenThePowerModuleIsOff() {
        let harness = Harness(displays: [Layout.macBook, Layout.monitor], pointer: Layout.onMonitor)
        defer { harness.tearDown() }
        harness.install()
        harness.settings.setModule(.power, enabled: false)

        harness.controller.openPower()

        XCTAssertFalse(harness.vm.isOpen)
        XCTAssertNotEqual(harness.vm.tab, .power)
    }

    // MARK: Preference

    func testChoosingOneDisplayLeavesImpulsOnlyThere() {
        let harness = Harness(displays: [Layout.macBook, Layout.monitor, Layout.sidecar], pointer: Layout.onMacBook)
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
        harness.pointer = Layout.onMacBook
        harness.controller.toggleFromKeyboard()
        XCTAssertEqual(harness.controller.activeDisplayID, 2)
    }

    func testMirroredDisplaysProduceOneSurfaceInTheLiveController() {
        let mirror = DisplayFixtures.plain(
            id: 9,
            name: "Mirror",
            origin: .zero,
            size: Layout.macBook.frame.size,
            mirrorSourceID: 1
        )
        let harness = Harness(displays: [Layout.macBook, mirror], pointer: Layout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        XCTAssertEqual(harness.controller.presentedDisplayIDs, [1])
        XCTAssertNil(harness.surfaces[9])
    }

    // MARK: Panel size

    func testAutomaticGivesEachDisplayItsOwnPresetInOneRunningApp() {
        let harness = Harness(displays: [Layout.macBook, Layout.monitor], pointer: Layout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.settings.panelSize = .automatic
        harness.reconnectDisplays()

        XCTAssertEqual(harness.surface(1).geometry.expandedSize, AdaptivePanelLayout.standard)
        XCTAssertEqual(harness.surface(2).geometry.expandedSize, AdaptivePanelLayout.large)
    }

    private func makeTemporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("impuls-multidisplay-\(UUID().uuidString).txt")
        try Data("drop me".utf8).write(to: url)
        return url
    }
}
