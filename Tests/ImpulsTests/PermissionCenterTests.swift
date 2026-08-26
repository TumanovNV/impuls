import XCTest
@testable import ImpulsCore

@MainActor
final class PermissionCenterTests: XCTestCase {
    func testNativeAutomationStatesRemainIndependentPerTargetApp() {
        let center = PermissionCenter()

        center.updateAutomation(.allowed, for: .music)
        center.updateAutomation(.denied, for: .spotify)

        XCTAssertEqual(center.appleMusicAutomation, .allowed)
        XCTAssertEqual(center.spotifyAutomation, .denied)

        center.updateAutomation(.notDetermined, for: .spotify)
        XCTAssertEqual(center.appleMusicAutomation, .allowed)
        XCTAssertEqual(center.spotifyAutomation, .notRequested)
    }
}
