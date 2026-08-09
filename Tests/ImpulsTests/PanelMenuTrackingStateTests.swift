import AppKit
import XCTest
@testable import ImpulsCore

@MainActor
final class PanelMenuTrackingStateTests: XCTestCase {
    func testMenuOpenedFromExpandedPanelHoldsItOpenUntilTrackingEnds() {
        let menu = NSMenu()
        var state = PanelMenuTrackingState()

        state.beginTracking(menu, panelIsOpen: true)

        XCTAssertTrue(state.isHoldingPanelOpen)
        XCTAssertTrue(state.endTracking(menu))
        XCTAssertFalse(state.isHoldingPanelOpen)
    }

    func testMenuDoesNotOpenOrHoldAnAlreadyClosedPanel() {
        let menu = NSMenu()
        var state = PanelMenuTrackingState()

        state.beginTracking(menu, panelIsOpen: false)

        XCTAssertFalse(state.isHoldingPanelOpen)
        XCTAssertFalse(state.endTracking(menu))
    }

    func testNestedMenusDoNotReleaseHoldUntilEntireChainCloses() {
        let parent = NSMenu()
        let submenu = NSMenu()
        var state = PanelMenuTrackingState()

        state.beginTracking(parent, panelIsOpen: true)
        state.beginTracking(submenu, panelIsOpen: false)

        XCTAssertFalse(state.endTracking(parent))
        XCTAssertTrue(state.isHoldingPanelOpen)
        XCTAssertTrue(state.endTracking(submenu))
        XCTAssertFalse(state.isHoldingPanelOpen)
    }

    func testDuplicateBeginNotificationDoesNotRequireDuplicateEnd() {
        let menu = NSMenu()
        var state = PanelMenuTrackingState()

        state.beginTracking(menu, panelIsOpen: true)
        state.beginTracking(menu, panelIsOpen: true)

        XCTAssertTrue(state.endTracking(menu))
        XCTAssertFalse(state.isHoldingPanelOpen)
    }

    func testUnknownEndNotificationCannotReleaseAnotherMenu() {
        let tracked = NSMenu()
        let other = NSMenu()
        var state = PanelMenuTrackingState()

        state.beginTracking(tracked, panelIsOpen: true)

        XCTAssertFalse(state.endTracking(other))
        XCTAssertTrue(state.isHoldingPanelOpen)
        XCTAssertTrue(state.endTracking(tracked))
    }
}
