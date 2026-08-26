import XCTest
@testable import ImpulsCore

@MainActor
final class PermissionCenterTests: XCTestCase {
    /// Every situation a target application can be in, mapped without invoking
    /// Automation, installing anything, or depending on what is running.
    ///
    /// The case that mattered: an installed but closed Spotify used to fall
    /// into the `restricted` catch-all, so Settings showed "Restricted" with no
    /// Allow button and no way back — for an app the user only had to open.
    func testEveryTargetAppSituationMapsToItsOwnRowState() {
        XCTAssertEqual(PermissionCenter.automationState(for: .allowed), .allowed)
        XCTAssertEqual(PermissionCenter.automationState(for: .denied), .denied)
        XCTAssertEqual(PermissionCenter.automationState(for: .notDetermined), .notRequested)
        XCTAssertEqual(PermissionCenter.automationState(for: .restricted), .restricted)
        XCTAssertEqual(PermissionCenter.automationState(for: .undeterminedAppNotRunning), .appNotRunning)
        XCTAssertEqual(PermissionCenter.missingAppState, .notInstalled)

        // The three states that are not a TCC verdict must stay distinct from
        // the three that are, or the row lies about what the user can do.
        let states: [PermissionCenter.State] = [.allowed, .denied, .notRequested, .restricted, .appNotRunning, .notInstalled]
        XCTAssertEqual(Set(states).count, states.count, "each situation needs its own row state")
        XCTAssertNotEqual(PermissionCenter.automationState(for: .undeterminedAppNotRunning), .restricted)
    }

    /// A closed app must not be described as blocked by policy, and the two
    /// non-verdict states must read differently to the user.
    func testClosedAndMissingAppsAreNotDescribedAsRestricted() {
        XCTAssertNotEqual(PermissionCenter.State.appNotRunning.title, PermissionCenter.State.restricted.title)
        XCTAssertNotEqual(PermissionCenter.State.notInstalled.title, PermissionCenter.State.restricted.title)
        XCTAssertNotEqual(PermissionCenter.State.appNotRunning.title, PermissionCenter.State.notInstalled.title)
        for state in [PermissionCenter.State.appNotRunning, .notInstalled] {
            XCTAssertFalse(state.title.isEmpty)
        }
    }

    func testNativeAutomationStatesRemainIndependentPerTargetApp() {
        let center = PermissionCenter()

        center.updateAutomation(.allowed, for: .music)
        center.updateAutomation(.denied, for: .spotify)

        XCTAssertEqual(center.appleMusicAutomation, .allowed)
        XCTAssertEqual(center.spotifyAutomation, .denied)

        center.updateAutomation(.notDetermined, for: .spotify)
        XCTAssertEqual(center.appleMusicAutomation, .allowed)
        XCTAssertEqual(center.spotifyAutomation, .notRequested)

        // Closing Spotify must not disturb Apple Music's own grant.
        center.updateAutomation(.undeterminedAppNotRunning, for: .spotify)
        XCTAssertEqual(center.appleMusicAutomation, .allowed)
        XCTAssertEqual(center.spotifyAutomation, .appNotRunning)
    }
}
