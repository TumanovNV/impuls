import AppKit
import XCTest
@testable import ImpulsCore

/// Hover, driven through `PointerWatcher` itself.
///
/// These exist because a test called "hovering the second display" was in fact
/// calling `surface.onPress` — the click path — and therefore went green while
/// hover carried a keyboard-handoff bug. Nothing here imitates a sample: the
/// pointer is moved, `tick()` is called, and whatever the production state
/// machine decides is what the assertions see.
///
/// The harness lives in `MultiDisplayControllerTests.swift`; the pointer sampler
/// is stopped there and stepped by hand against an injected clock, so a dwell
/// costs no wall-clock time.
@MainActor
final class MultiDisplayHoverTests: XCTestCase {

    // MARK: - The blocker this file was written for

    /// The reported scenario: typing in Translate on the MacBook, then hovering
    /// the external monitor's anchor. The panel moved and the text survived, but
    /// the keyboard did not follow it — `moveActivation` cleared the claim and
    /// nothing restored it, so the caret was gone on the display in front of
    /// the user.
    func testHoverFromFocusedTranslateOnDisplayAToDisplayBTransfersKeyboardOwnership() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        // Open on the MacBook by hovering its notch, then start typing.
        harness.movePointer(to: harness.anchor(of: 1))
        XCTAssertTrue(harness.vm.isOpen)
        XCTAssertEqual(harness.controller.activeDisplayID, 1)

        harness.vm.select(.translate)
        harness.vm.translator.input = "hello"
        let viewModel = harness.vm
        let clipboard = ObjectIdentifier(viewModel.clipboard)
        let power = ObjectIdentifier(viewModel.power)

        XCTAssertTrue(harness.vm.wantsKeyboard, "selecting a typing module claims the keyboard")
        XCTAssertTrue(harness.surface(1).acceptsKeyboard)
        XCTAssertFalse(harness.surface(2).acceptsKeyboard)

        // The pointer leaves the MacBook panel and lands on the monitor's anchor.
        harness.movePointer(to: harness.anchor(of: 2))

        XCTAssertEqual(harness.controller.activeDisplayID, 2)
        XCTAssertFalse(harness.surface(1).isActive)
        XCTAssertTrue(harness.surface(2).isActive)
        XCTAssertFalse(harness.surface(1).acceptsKeyboard, "the display it came from gives the keyboard up")
        XCTAssertTrue(harness.surface(2).acceptsKeyboard, "and the display in front of the user takes it")
        XCTAssertTrue(harness.vm.wantsKeyboard, "the claim itself was never dropped")
        XCTAssertEqual(harness.vm.tab, .translate)
        XCTAssertEqual(harness.vm.translator.input, "hello")

        XCTAssertEqual(harness.activeSurfaceCount, 1)
        XCTAssertEqual(harness.keyboardOwningSurfaceCount, 1)
        XCTAssertEqual(harness.observedMaximumActive, 1, "never two expanded panels, not even between two statements")
        XCTAssertEqual(harness.observedMaximumKeyboard, 1, "never two windows willing to take keys")

        XCTAssertTrue(harness.vm === viewModel, "one view model")
        XCTAssertEqual(ObjectIdentifier(harness.vm.clipboard), clipboard, "one clipboard watcher")
        XCTAssertEqual(ObjectIdentifier(harness.vm.power), power, "one PowerMonitor")
        XCTAssertEqual(harness.servicesStarted, 1)
    }

    /// The other half of the rule, and the one that would be a privacy problem
    /// rather than an inconvenience: a module that *could* type is not a licence
    /// to take the keyboard from whatever the user is actually working in.
    func testHoverWithoutAKeyboardClaimDoesNotStealTheKeyboardOnArrival() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 1))
        // Reaching Translate the way the rail does — a dwell, not a click —
        // shows the module without asking for the keyboard.
        harness.vm.select(.translate, requestKeyboard: false)

        XCTAssertEqual(harness.vm.tab, .translate)
        XCTAssertFalse(harness.vm.wantsKeyboard)
        XCTAssertEqual(harness.keyboardOwningSurfaceCount, 0)

        harness.movePointer(to: harness.anchor(of: 2))

        XCTAssertEqual(harness.controller.activeDisplayID, 2)
        XCTAssertTrue(harness.surface(2).isActive)
        XCTAssertFalse(harness.vm.wantsKeyboard, "arriving on another display is not a request to type")
        XCTAssertEqual(harness.keyboardOwningSurfaceCount, 0, "no surface takes keys from the app underneath")
        XCTAssertEqual(harness.observedMaximumKeyboard, 0)
    }

    /// Notes, so the rule is shown to be about the claim and not about Translate.
    func testHoverTransfersTheKeyboardForNotesToo() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 1))
        harness.vm.select(.notes)
        XCTAssertTrue(harness.vm.wantsKeyboard)
        XCTAssertTrue(harness.surface(1).acceptsKeyboard)

        harness.movePointer(to: harness.anchor(of: 2))

        XCTAssertEqual(harness.vm.tab, .notes)
        XCTAssertTrue(harness.vm.wantsKeyboard)
        XCTAssertTrue(harness.surface(2).acceptsKeyboard)
        XCTAssertFalse(harness.surface(1).acceptsKeyboard)
        XCTAssertEqual(harness.keyboardOwningSurfaceCount, 1)
    }

    func testHoverTransfersTheKeyboardForSnippetsToo() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 1))
        harness.vm.select(.snippets)
        XCTAssertTrue(harness.surface(1).acceptsKeyboard)

        harness.movePointer(to: harness.anchor(of: 2))

        XCTAssertEqual(harness.vm.tab, .snippets)
        XCTAssertTrue(harness.surface(2).acceptsKeyboard)
        XCTAssertEqual(harness.keyboardOwningSurfaceCount, 1)
    }

    /// A panel opened from the global shortcut is held open without the pointer,
    /// so hover cannot move it; the press path can. Keyboard navigation has to
    /// survive that move, on the new display and only there.
    func testKeyboardNavigationSurvivesTheMoveToAnotherDisplay() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.controller.toggleFromKeyboard()
        XCTAssertTrue(harness.vm.keyboardNavigationActive)
        XCTAssertTrue(harness.surface(1).acceptsKeyboard)

        harness.pointer = DisplayLayout.onMonitor
        harness.surface(2).onPress?()

        XCTAssertEqual(harness.controller.activeDisplayID, 2)
        XCTAssertTrue(harness.vm.keyboardNavigationActive, "arrow keys and Esc still work after the move")
        XCTAssertTrue(harness.surface(2).acceptsKeyboard)
        XCTAssertFalse(harness.surface(1).acceptsKeyboard)
        XCTAssertEqual(harness.keyboardOwningSurfaceCount, 1)
        XCTAssertEqual(harness.observedMaximumKeyboard, 1)
    }

    // MARK: - The A → B state machine

    /// Leaving one display's expanded panel for another's anchor is one move,
    /// not a close and then a separate open. The user should not have to hover
    /// twice.
    func testMovingFromTheExpandedPanelOnAToTheAnchorOnBIsASingleTransition() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 1))
        // Into the body of the panel it just opened: still display A, so this
        // decides nothing.
        harness.movePointer(to: harness.panelCentre(of: 1))
        XCTAssertTrue(harness.vm.isOpen)
        XCTAssertEqual(harness.controller.activeDisplayID, 1)
        let transitionsAfterOpening = harness.pointerTransitions.count

        harness.movePointer(to: harness.anchor(of: 2))

        let moves = harness.pointerTransitions.dropFirst(transitionsAfterOpening)
        XCTAssertEqual(moves.count, 1, "one decision, not a close followed by an open")
        XCTAssertEqual(moves.first?.inside, true)
        XCTAssertEqual(moves.first?.display, 2)
        XCTAssertTrue(harness.vm.isOpen, "the panel never folded on the way across")
        XCTAssertEqual(harness.surface(1).activationLog, [true, false], "activated once, then stood down once")
        XCTAssertEqual(harness.surface(2).activationLog, [true], "and the display arrived at is raised once")
        XCTAssertEqual(harness.observedMaximumActive, 1)
    }

    /// The dwell belongs to the display being arrived at. A pointer that has
    /// been sitting in A's panel for a long time does not get to skip B's.
    func testTheDwellOnBIsNotInheritedFromTimeSpentOnA() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 1))
        harness.movePointer(to: harness.panelCentre(of: 1))
        // A long, uneventful stay on A.
        harness.clock = harness.clock.addingTimeInterval(30)
        harness.sample()
        XCTAssertEqual(harness.controller.activeDisplayID, 1)

        // Arriving on B: the first sample only starts B's clock.
        harness.pointer = harness.anchor(of: 2)
        harness.sample()
        XCTAssertEqual(harness.controller.activeDisplayID, 1, "the move waits out B's own dwell")

        harness.clock = harness.clock.addingTimeInterval(harness.settings.openDelay.seconds + 0.001)
        harness.sample()
        XCTAssertEqual(harness.controller.activeDisplayID, 2)
    }

    /// A pointer thrown across the top of two displays passes through both
    /// anchors in a few milliseconds. Neither may open, and the panel must not
    /// flicker between them.
    func testAPointerSweptAcrossBothDisplaysOpensNeither() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.sweepPointer(through: [
            harness.anchor(of: 1),
            CGPoint(x: 1_400, y: 960),
            harness.anchor(of: 2),
            CGPoint(x: 3_500, y: 1_430),
        ])

        XCTAssertFalse(harness.vm.isOpen)
        XCTAssertEqual(harness.pointerTransitions.count, 0, "a passing pointer decides nothing")
        XCTAssertEqual(harness.observedMaximumActive, 1, "activation never moved, so it never doubled")
    }

    /// Rapid indecision between two anchors resolves to whichever one the
    /// pointer finally rests on, with one activation.
    func testRapidMovementBetweenAnchorsResolvesToWhereThePointerSettles() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.sweepPointer(through: [
            harness.anchor(of: 1),
            harness.anchor(of: 2),
            harness.anchor(of: 1),
            harness.anchor(of: 2),
        ])
        XCTAssertFalse(harness.vm.isOpen, "nothing was rested on yet")

        harness.movePointer(to: harness.anchor(of: 2))

        XCTAssertTrue(harness.vm.isOpen)
        XCTAssertEqual(harness.controller.activeDisplayID, 2)
        XCTAssertEqual(harness.pointerTransitions.count, 1)
        XCTAssertEqual(harness.observedMaximumActive, 1)
    }

    func testRepeatedSamplesInsideOnePanelEmitExactlyOneOpen() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 1))
        let transitions = harness.pointerTransitions.count
        let centre = harness.panelCentre(of: 1)
        for offset in stride(from: CGFloat(-6), through: 6, by: 1) {
            harness.pointer = CGPoint(x: centre.x + offset, y: centre.y)
            harness.clock = harness.clock.addingTimeInterval(0.02)
            harness.sample()
        }

        XCTAssertEqual(transitions, 1)
        XCTAssertEqual(harness.pointerTransitions.count, transitions)
        XCTAssertTrue(harness.vm.isOpen)
        XCTAssertEqual(harness.surface(1).activationLog, [true])
    }

    func testLiveContentPreparesBeforeExpansionAndUnmountsAfterClose() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 1))
        XCTAssertTrue(harness.surface(1).hasMountedContent)
        XCTAssertFalse(harness.surface(1).isExpanded)

        harness.drainNextTurn()
        XCTAssertTrue(harness.surface(1).isExpanded)
        XCTAssertEqual(harness.surface(1).preparedLayoutCommitCount, 1)

        harness.surface(1).onKeyCommand?(.close)
        harness.drainNextTurn()
        XCTAssertFalse(harness.surface(1).isExpanded)
        XCTAssertTrue(harness.surface(1).hasMountedContent, "outgoing content stays mounted only for its fade")

        harness.drainDelayed(at: 0.16)
        XCTAssertFalse(harness.surface(1).hasMountedContent)
    }

    func testAQuickBoundaryCorrectionDoesNotFlickerClosed() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 1))
        harness.drainNextTurn()
        let closeRect = harness.surface(1).geometry.expandedHoverRect
        let inside = CGPoint(x: closeRect.maxX - 0.5, y: closeRect.midY)
        harness.pointer = inside
        harness.sample()

        harness.pointer = CGPoint(x: closeRect.maxX + 1, y: closeRect.midY)
        harness.sample()
        harness.clock = harness.clock.addingTimeInterval(harness.controller.pointerSampler.closeDelay / 2)
        harness.pointer = inside
        harness.sample()
        harness.clock = harness.clock.addingTimeInterval(harness.controller.pointerSampler.closeDelay)
        harness.sample()

        XCTAssertEqual(harness.pointerTransitions.count, 1, "the brief boundary crossing never becomes a close")
        XCTAssertTrue(harness.vm.isOpen)
        XCTAssertTrue(harness.surface(1).isExpanded)
    }

    func testRapidAtoBtoARetiresEveryOldSurfacePresentation() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 1))
        harness.drainNextTurn()
        harness.movePointer(to: harness.anchor(of: 2))
        harness.movePointer(to: harness.anchor(of: 1))
        harness.drainNextTurn()
        harness.drainDelayed()

        XCTAssertTrue(harness.vm.isOpen)
        XCTAssertEqual(harness.controller.activeDisplayID, 1)
        XCTAssertTrue(harness.surface(1).isExpanded)
        XCTAssertFalse(harness.surface(2).isExpanded)
        XCTAssertEqual(harness.surface(1).activationLog, [true, false, true])
        XCTAssertEqual(harness.surface(2).activationLog, [true, false])
        XCTAssertEqual(harness.expandedSurfaceCount, 1)
        XCTAssertEqual(harness.observedMaximumExpanded, 1)
        XCTAssertEqual(harness.observedMaximumActive, 1)
        XCTAssertFalse(harness.scheduledDelays.contains(0.16), "the cancelled close never schedules a visual completion")
    }

    func testReenterBeforeDeferredCollapseCancelsTheStaleClose() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 1))
        harness.drainNextTurn()
        harness.vm.select(.translate)
        harness.vm.translator.input = "still here"
        let rectApplications = harness.surface(1).appliedRectLog.count

        harness.surface(1).onKeyCommand?(.close)
        XCTAssertTrue(harness.vm.isOpen, "keyboard release gets its own run-loop turn")
        harness.movePointer(to: harness.anchor(of: 1))
        harness.drainNextTurn()

        XCTAssertTrue(harness.vm.isOpen)
        XCTAssertTrue(harness.surface(1).isExpanded)
        XCTAssertEqual(harness.vm.tab, .translate)
        XCTAssertEqual(harness.vm.translator.input, "still here")
        XCTAssertEqual(harness.surface(1).appliedRectLog.count, rectApplications)
        XCTAssertFalse(harness.scheduledDelays.contains(0.16), "the cancelled close never schedules a visual completion")
        XCTAssertEqual(harness.observedMaximumExpanded, 1)
    }

    func testAStaleCloseCompletionCannotShrinkAReopenedPanel() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 1))
        harness.drainNextTurn()
        harness.surface(1).onKeyCommand?(.close)
        harness.drainNextTurn()

        XCTAssertFalse(harness.vm.isOpen)
        XCTAssertTrue(harness.scheduledDelays.contains(0.16))
        harness.movePointer(to: harness.anchor(of: 1))
        harness.drainNextTurn()
        XCTAssertTrue(harness.surface(1).lastAppliedRectWasOpen == true)

        harness.drainDelayed()

        XCTAssertTrue(harness.vm.isOpen)
        XCTAssertTrue(harness.surface(1).isExpanded)
        XCTAssertEqual(harness.surface(1).lastAppliedRectWasOpen, true)
        XCTAssertEqual(harness.expandedSurfaceCount, 1)
    }

    func testTopologyRefreshDuringCloseKeepsTheVisiblePanelInteractiveUntilCompletion() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 1))
        harness.drainNextTurn()
        harness.surface(1).onKeyCommand?(.close)
        harness.drainNextTurn()
        XCTAssertFalse(harness.vm.isOpen)
        XCTAssertEqual(harness.surface(1).lastAppliedRectWasOpen, true)

        harness.reconnectDisplays()
        XCTAssertEqual(
            harness.surface(1).lastAppliedRectWasOpen,
            true,
            "the still-visible closing panel must not become click-through after topology work"
        )

        harness.drainDelayed(at: 0.16)
        XCTAssertEqual(harness.surface(1).lastAppliedRectWasOpen, false)
    }

    func testForegroundServicesActivateOnceAcrossEstablishedCloseReentry() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 1))
        harness.drainNextTurn()
        harness.drainDelayed(at: 0.22)
        XCTAssertEqual(harness.controller.foregroundServiceActivationCount, 1)

        harness.surface(1).onKeyCommand?(.close)
        harness.movePointer(to: harness.anchor(of: 1))
        harness.drainNextTurn()
        harness.drainDelayed(at: 0.22)

        XCTAssertEqual(harness.controller.foregroundServiceActivationCount, 1)
        XCTAssertTrue(harness.vm.isOpen)
    }

    func testPendingCloseHandoffCommitsTheNewDisplayAfterReentry() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 1))
        harness.drainNextTurn()
        harness.drainDelayed(at: 0.22)
        XCTAssertEqual(harness.controller.foregroundServiceActivationCount, 1)

        harness.surface(1).onKeyCommand?(.close)
        XCTAssertTrue(harness.vm.isOpen, "the keyboard-release turn has not collapsed A yet")
        harness.movePointer(to: harness.anchor(of: 2))
        XCTAssertTrue(harness.surface(2).hasMountedContent)
        XCTAssertFalse(harness.surface(2).isExpanded)

        harness.drainNextTurn()

        XCTAssertEqual(harness.controller.activeDisplayID, 2)
        XCTAssertFalse(harness.surface(1).isActive)
        XCTAssertFalse(harness.surface(1).hasMountedContent)
        XCTAssertTrue(harness.surface(2).isActive)
        XCTAssertTrue(harness.surface(2).isExpanded)
        XCTAssertTrue(harness.vm.isOpen)
        XCTAssertEqual(harness.controller.foregroundServiceActivationCount, 1)
        XCTAssertEqual(harness.expandedSurfaceCount, 1)
        XCTAssertEqual(harness.observedMaximumExpanded, 1)
    }

    func testInitialPreparingHandoffStillStartsForegroundServicesOnce() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 1))
        XCTAssertTrue(harness.surface(1).hasMountedContent)
        XCTAssertFalse(harness.surface(1).isExpanded)

        harness.movePointer(to: harness.anchor(of: 2))
        XCTAssertFalse(harness.surface(1).isActive)
        XCTAssertTrue(harness.surface(2).hasMountedContent)
        XCTAssertFalse(harness.surface(2).isExpanded)

        harness.drainNextTurn()
        harness.drainDelayed(at: 0.22)

        XCTAssertEqual(harness.controller.activeDisplayID, 2)
        XCTAssertTrue(harness.surface(2).isExpanded)
        XCTAssertEqual(harness.controller.foregroundServiceActivationCount, 1)
        XCTAssertEqual(harness.expandedSurfaceCount, 1)
        XCTAssertEqual(harness.observedMaximumExpanded, 1)
    }

    func testHandoffInvalidatesTheOldDisplayServiceDeadline() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 1))
        harness.drainNextTurn()
        harness.movePointer(to: harness.anchor(of: 2))
        harness.drainNextTurn()

        harness.drainFirstDelayed(at: 0.22)
        XCTAssertEqual(
            harness.controller.foregroundServiceActivationCount,
            0,
            "A's old deadline must not publish during B's transition"
        )
        harness.drainFirstDelayed(at: 0.22)
        XCTAssertEqual(harness.controller.foregroundServiceActivationCount, 1)
        XCTAssertTrue(harness.surface(2).isExpanded)
    }

    func testRuntimeReduceMotionUpdatesTheLivePlanAndCloseTiming() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 1))
        harness.drainNextTurn()
        XCTAssertFalse(harness.surface(1).motionPlan.reducesMotion)

        harness.reducesMotion = true
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        XCTAssertTrue(harness.surface(1).motionPlan.reducesMotion)

        harness.surface(1).onKeyCommand?(.close)
        harness.drainNextTurn()
        XCTAssertFalse(harness.scheduledDelays.contains(0.16))
        XCTAssertEqual(harness.surface(1).lastAppliedRectWasOpen, false)
    }

    func testForegroundServicesActivateOnceWhenFirstOpenIsCancelledThenReentered() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 1))
        harness.drainNextTurn()
        harness.surface(1).onKeyCommand?(.close)
        harness.drainNextTurn()
        harness.movePointer(to: harness.anchor(of: 1))
        harness.drainNextTurn()
        harness.drainDelayed(at: 0.22)

        XCTAssertEqual(harness.controller.foregroundServiceActivationCount, 1)
        XCTAssertTrue(harness.vm.isOpen)
        XCTAssertTrue(harness.surface(1).isExpanded)
    }

    func testReduceMotionShrinksTheHitRegionWithTheImmediateVisualClose() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook], pointer: DisplayLayout.onMacBook)
        harness.reducesMotion = true
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 1))
        harness.drainNextTurn()
        harness.surface(1).onKeyCommand?(.close)
        harness.drainNextTurn()

        XCTAssertFalse(harness.vm.isOpen)
        XCTAssertFalse(harness.surface(1).isExpanded)
        XCTAssertEqual(harness.surface(1).lastAppliedRectWasOpen, false)
        XCTAssertFalse(harness.scheduledDelays.contains(0.16), "no visual-close hit shield remains under Reduce Motion")
    }

    func testDisconnectInvalidatesOpeningAndClosingWork() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.sidecar], pointer: DisplayLayout.onSidecar)
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 3))
        let removed = harness.surface(3)
        harness.surface(3).onKeyCommand?(.close)
        harness.displays = [DisplayLayout.macBook]
        harness.pointer = DisplayLayout.onMacBook
        harness.reconnectDisplays()
        harness.drainNextTurn()
        harness.drainDelayed()

        XCTAssertTrue(removed.isTornDown)
        XCTAssertFalse(removed.isActive)
        XCTAssertFalse(removed.isExpanded)
        XCTAssertFalse(harness.vm.isOpen)
        XCTAssertEqual(harness.controller.activeDisplayID, 1)
        XCTAssertEqual(harness.expandedSurfaceCount, 0)
        XCTAssertEqual(harness.keyboardOwningSurfaceCount, 0)
    }

    /// Hover on a display Impuls is not allowed on does nothing at all.
    func testHoverOnADisplayExcludedByThePreferenceDoesNothing() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()
        harness.settings.selectedDisplayID = 2
        harness.reconnectDisplays()
        XCTAssertEqual(harness.controller.presentedDisplayIDs, [2])

        // The MacBook's notch is still where it was, but Impuls is not there.
        harness.movePointer(to: CGPoint(x: 756, y: 982))

        XCTAssertFalse(harness.vm.isOpen)
        XCTAssertEqual(harness.pointerTransitions.count, 0)
    }

    // MARK: - Hot plug against a hover in flight

    /// The display being hovered is unplugged between the sample that started
    /// the dwell and the one that would have finished it.
    func testADisplayUnpluggedMidHoverDoesNotOpenAPanelOnIt() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.sidecar], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.pointer = harness.anchor(of: 3)
        harness.sample()
        XCTAssertFalse(harness.vm.isOpen, "the dwell has only just started")

        harness.displays = [DisplayLayout.macBook]
        harness.pointer = DisplayLayout.onMacBook
        harness.reconnectDisplays()

        harness.clock = harness.clock.addingTimeInterval(1)
        harness.sample()

        XCTAssertFalse(harness.vm.isOpen)
        XCTAssertEqual(harness.controller.presentedDisplayIDs, [1])
        XCTAssertTrue(harness.surface(3).isTornDown, "the window of the display that left is released")
        XCTAssertFalse(harness.surface(3).isActive)
        XCTAssertEqual(harness.controller.activeDisplayID, 1)
    }

    /// The display the panel is expanded on is unplugged. The keyboard goes
    /// with it, and no surface inherits it silently.
    func testUnpluggingTheDisplayHoldingTheKeyboardReleasesIt() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.sidecar], pointer: DisplayLayout.onSidecar)
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 3))
        harness.vm.select(.translate)
        harness.vm.translator.input = "half a sentence"
        XCTAssertTrue(harness.surface(3).acceptsKeyboard)

        let sidecar = harness.surface(3)
        harness.displays = [DisplayLayout.macBook]
        harness.pointer = DisplayLayout.onMacBook
        harness.reconnectDisplays()

        XCTAssertTrue(sidecar.isTornDown)
        XCTAssertFalse(sidecar.acceptsKeyboard)
        XCTAssertFalse(harness.vm.wantsKeyboard)
        XCTAssertEqual(harness.keyboardOwningSurfaceCount, 0, "the MacBook does not inherit a caret nobody asked it for")
        XCTAssertFalse(harness.vm.isOpen)
        XCTAssertEqual(harness.vm.translator.input, "half a sentence", "and the text is still there")
        XCTAssertEqual(harness.observedMaximumKeyboard, 1)
    }

    // MARK: - The invariants, under a long mixed sequence

    /// Everything the user can do to Impuls across three displays, in one run,
    /// with both invariants checked inside every state change rather than at
    /// the end: at most one surface expanded, at most one window willing to
    /// take keys.
    ///
    /// The structural guarantee behind it is that exactly one line in the app
    /// can grant the keyboard — `applyKeyboardOwnership`, to
    /// `coordinator.activeSurface` and nothing else — and the only two paths
    /// that change which surface is active both call it immediately. This test
    /// is what proves the paths agree with that claim in practice.
    func testTheOneActiveAndOneKeyboardInvariantsSurviveALongMixedSequence() throws {
        let harness = DisplayHarness(
            displays: [DisplayLayout.macBook, DisplayLayout.monitor, DisplayLayout.sidecar],
            pointer: DisplayLayout.onMacBook
        )
        defer { harness.tearDown() }
        harness.install()

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("impuls-invariants-\(UUID().uuidString).txt")
        try Data("drop".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        // Hover open on the MacBook and start typing.
        harness.movePointer(to: harness.anchor(of: 1))
        harness.vm.select(.translate)

        // Hover across to the monitor, then on to the iPad.
        harness.movePointer(to: harness.anchor(of: 2))
        harness.movePointer(to: harness.anchor(of: 3))
        XCTAssertEqual(harness.controller.activeDisplayID, 3)

        // A press back on the monitor.
        harness.pointer = DisplayLayout.onMonitor
        harness.surface(2).onPress?()

        // A drop on the MacBook.
        harness.pointer = DisplayLayout.onMacBook
        harness.surface(1).onDragEntered?()
        _ = harness.surface(1).onDrop?([file])

        // A notification while the pointer is on the iPad.
        harness.pointer = DisplayLayout.onSidecar
        harness.controller.openPower()

        // The iPad is unplugged while the panel is on it.
        harness.displays = [DisplayLayout.macBook, DisplayLayout.monitor]
        harness.pointer = DisplayLayout.onMonitor
        harness.reconnectDisplays()

        // And comes back.
        harness.displays = [DisplayLayout.macBook, DisplayLayout.monitor, DisplayLayout.sidecar]
        harness.reconnectDisplays()

        // Escape from the active panel.
        harness.controller.activeDisplayID.map { harness.surface($0).onKeyCommand?(.close) }

        XCTAssertEqual(harness.observedMaximumActive, 1, "two panels were expanded at once at some point")
        XCTAssertEqual(harness.observedMaximumKeyboard, 1, "two windows were willing to take keys at some point")
        XCTAssertLessThanOrEqual(harness.activeSurfaceCount, 1)
        XCTAssertLessThanOrEqual(harness.keyboardOwningSurfaceCount, 1)
        XCTAssertEqual(harness.servicesStarted, 1, "one set of services through all of that")
        XCTAssertEqual(harness.viewModelsBuilt, 1)
    }

    // MARK: - Leaving

    func testLeavingTheExpandedPanelForEmptyDesktopClosesIt() {
        let harness = DisplayHarness(displays: [DisplayLayout.macBook, DisplayLayout.monitor], pointer: DisplayLayout.onMacBook)
        defer { harness.tearDown() }
        harness.install()

        harness.movePointer(to: harness.anchor(of: 1))
        harness.movePointer(to: harness.panelCentre(of: 1))
        XCTAssertTrue(harness.vm.isOpen)

        harness.pointer = harness.emptyDesktop(of: 1)
        harness.sample()
        harness.clock = harness.clock.addingTimeInterval(harness.controller.pointerSampler.closeDelay + 0.001)
        harness.sample()

        XCTAssertEqual(harness.pointerTransitions.last?.inside, false)
        XCTAssertNil(harness.pointerTransitions.last?.display ?? nil)
        XCTAssertEqual(harness.observedMaximumActive, 1)
    }
}
