import AppKit
import XCTest
@testable import ImpulsCore

/// The half of the feature that lives in the panel controller: what counts as
/// deliberate use, and when Impuls is quiet enough to say anything.
///
/// Uses the same `DisplayHarness` as the multi-display suite, so these drive the
/// real controller, the real pointer sampler and the real transition scheduling
/// rather than an imitation of them.
@MainActor
final class ProjectSupportPromptLifecycleTests: XCTestCase {
    /// Counts both signals from a harness, in order.
    private final class Recorder {
        private(set) var uses = 0
        private(set) var idleTransitions = 0
        @MainActor
        func attach(to controller: NotchController) {
            controller.onMeaningfulUse = { [unowned self] in self.uses += 1 }
            controller.onReturnedToIdle = { [unowned self] in self.idleTransitions += 1 }
        }
    }

    private func makeHarness() -> (DisplayHarness, Recorder) {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook], pointer: DisplayLayout.onMacBook)
        let recorder = Recorder()
        recorder.attach(to: harness.controller)
        harness.install()
        return (harness, recorder)
    }

    /// Opens with the shortcut, closes with it, and runs the transition to its
    /// end — the production sequence for one deliberate session.
    private func runDeliberateSession(_ harness: DisplayHarness) {
        harness.controller.toggleFromKeyboard()
        harness.drainNextTurn()
        harness.controller.toggleFromKeyboard()
        harness.drainNextTurn()
        harness.drainDelayed()
    }

    // MARK: - What counts

    func testGlobalShortcutIsDeliberateUse() {
        let (harness, recorder) = makeHarness()
        defer { harness.tearDown() }

        harness.controller.toggleFromKeyboard()
        XCTAssertEqual(recorder.uses, 1)

        // Closing is not a second use.
        harness.drainNextTurn()
        harness.controller.toggleFromKeyboard()
        XCTAssertEqual(recorder.uses, 1)
    }

    func testMenuBarWorkspaceCommandsAreDeliberateUse() {
        let (harness, recorder) = makeHarness()
        defer { harness.tearDown() }

        harness.controller.open()
        XCTAssertEqual(recorder.uses, 1)

        harness.controller.open(tab: .notes)
        XCTAssertEqual(recorder.uses, 2)
    }

    func testNotificationDrivenPowerOpenIsDeliberateUse() {
        let (harness, recorder) = makeHarness()
        defer { harness.tearDown() }

        // A click on a low-battery notification is still the user clicking.
        harness.controller.openPower()
        XCTAssertEqual(recorder.uses, 1)
    }

    func testClickingTheCollapsedTabIsDeliberateUse() {
        let (harness, recorder) = makeHarness()
        defer { harness.tearDown() }

        harness.controller.toggle()
        XCTAssertEqual(recorder.uses, 1)

        // The toggle that closes it is not use.
        harness.drainNextTurn()
        harness.controller.toggle()
        XCTAssertEqual(recorder.uses, 1)
    }

    func testClickingInsideThePanelIsDeliberateUse() {
        let (harness, recorder) = makeHarness()
        defer { harness.tearDown() }

        harness.surface(DisplayLayout.macBook.id).onPress?()
        XCTAssertEqual(recorder.uses, 1, "the hover user's click is how they express intent")
    }

    func testHoverAloneIsNotUse() {
        let (harness, recorder) = makeHarness()
        defer { harness.tearDown() }

        // The real sampler, the real dwell, the real open. The panel is on
        // screen and nothing has been asked for.
        harness.movePointer(to: harness.anchor(of: DisplayLayout.macBook.id))
        harness.drainNextTurn()
        XCTAssertTrue(harness.vm.isOpen, "hover did open the panel")
        XCTAssertEqual(recorder.uses, 0, "proximity is not intent")

        harness.movePointer(to: harness.emptyDesktop(of: DisplayLayout.macBook.id))
        harness.drainNextTurn()
        harness.drainDelayed()
        XCTAssertEqual(recorder.uses, 0)
        XCTAssertEqual(recorder.idleTransitions, 0, "nothing happened, so nothing finished")
    }

    func testHoverFollowedByAClickCounts() {
        let (harness, recorder) = makeHarness()
        defer { harness.tearDown() }

        harness.movePointer(to: harness.anchor(of: DisplayLayout.macBook.id))
        harness.drainNextTurn()
        XCTAssertEqual(recorder.uses, 0)

        harness.surface(DisplayLayout.macBook.id).onPress?()
        XCTAssertEqual(recorder.uses, 1)
    }

    // MARK: - When Impuls may speak

    func testIdleIsReportedOnceAfterADeliberateSessionFolds() {
        let (harness, recorder) = makeHarness()
        defer { harness.tearDown() }

        harness.controller.toggleFromKeyboard()
        harness.drainNextTurn()
        XCTAssertEqual(recorder.idleTransitions, 0, "not while the panel is open")

        harness.controller.toggleFromKeyboard()
        harness.drainNextTurn()
        XCTAssertEqual(recorder.idleTransitions, 0, "not while it is still visibly closing")

        harness.drainDelayed()
        XCTAssertEqual(recorder.idleTransitions, 1)

        // Draining again must not produce a second one.
        harness.drainDelayed()
        XCTAssertEqual(recorder.idleTransitions, 1)
    }

    func testManyActionsInOneSessionStillReportOneIdleTransition() {
        let (harness, recorder) = makeHarness()
        defer { harness.tearDown() }

        harness.controller.toggleFromKeyboard()
        harness.drainNextTurn()
        harness.surface(DisplayLayout.macBook.id).onPress?()
        harness.surface(DisplayLayout.macBook.id).onPress?()
        harness.controller.open(tab: .notes)
        harness.drainNextTurn()

        harness.controller.toggleFromKeyboard()
        harness.drainNextTurn()
        harness.drainDelayed()

        XCTAssertGreaterThan(recorder.uses, 1)
        XCTAssertEqual(recorder.idleTransitions, 1, "one fold, one quiet moment")
    }

    func testEachSessionReportsItsOwnIdleTransition() {
        let (harness, recorder) = makeHarness()
        defer { harness.tearDown() }

        runDeliberateSession(harness)
        XCTAssertEqual(recorder.idleTransitions, 1)

        runDeliberateSession(harness)
        XCTAssertEqual(recorder.idleTransitions, 2)
    }

    func testTeardownDoesNotReportAQuietMoment() {
        let (harness, recorder) = makeHarness()
        defer { harness.tearDown() }

        harness.controller.toggleFromKeyboard()
        harness.drainNextTurn()
        XCTAssertEqual(recorder.uses, 1)

        harness.controller.teardown()
        harness.drainNextTurn()
        harness.drainDelayed()

        XCTAssertEqual(recorder.idleTransitions, 0, "quitting is not a moment to ask for a favour")
    }

    // MARK: - Wired to the policy

    func testTheControllerSignalsDriveTheServiceEndToEnd() throws {
        let suite = "ProjectSupportPromptLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // A clock the test owns, so thirty days cost nothing.
        var clock = Date(timeIntervalSince1970: 1_699_920_000)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let service = ProjectSupportPromptService(
            defaults: defaults,
            calendar: utc,
            now: { clock }
        )

        let harness = DisplayHarness(displays: [DisplayLayout.macBook], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        var idleTransitions = 0
        harness.controller.onMeaningfulUse = { service.recordMeaningfulUse() }
        harness.controller.onReturnedToIdle = { idleTransitions += 1 }
        harness.install()

        // Twenty qualifying days of real sessions, one per day.
        for day in 0..<20 {
            clock = Date(timeIntervalSince1970: 1_699_920_000).addingTimeInterval(TimeInterval(day) * 86_400)
            runDeliberateSession(harness)
        }

        XCTAssertEqual(idleTransitions, 20)
        XCTAssertEqual(service.record.activeDayCount, 20)
        XCTAssertEqual(service.record.meaningfulUseCount, 20)

        clock = Date(timeIntervalSince1970: 1_699_920_000).addingTimeInterval(40 * 86_400)
        XCTAssertTrue(service.isEligible)
    }

    func testHoverOnlyUseNeverBecomesEligible() throws {
        let suite = "ProjectSupportPromptLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var clock = Date(timeIntervalSince1970: 1_699_920_000)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let service = ProjectSupportPromptService(defaults: defaults, calendar: utc, now: { clock })

        let harness = DisplayHarness(displays: [DisplayLayout.macBook], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.controller.onMeaningfulUse = { service.recordMeaningfulUse() }
        harness.install()

        let anchor = harness.anchor(of: DisplayLayout.macBook.id)
        let away = harness.emptyDesktop(of: DisplayLayout.macBook.id)
        for day in 0..<40 {
            clock = Date(timeIntervalSince1970: 1_699_920_000).addingTimeInterval(TimeInterval(day) * 86_400)
            harness.movePointer(to: anchor)
            harness.drainNextTurn()
            harness.movePointer(to: away)
            harness.drainNextTurn()
            harness.drainDelayed()
        }

        clock = Date(timeIntervalSince1970: 1_699_920_000).addingTimeInterval(90 * 86_400)
        XCTAssertEqual(service.record.meaningfulUseCount, 0)
        XCTAssertFalse(service.isEligible, "a panel nobody touched is not evidence of anything")
    }
}
