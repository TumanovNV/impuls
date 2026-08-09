import ApplicationServices
import XCTest
@testable import ImpulsCore

final class PlayerBridgeTests: XCTestCase {
    func testParsesAppleMusicStateWithCyrillicMetadata() throws {
        let raw = [
            "playing",
            "Мотылёк",
            "Макс Корж",
            "Жить в кайф",
            "241000",
            "37500",
            "",
        ].joined(separator: "\u{1}")

        let state = try XCTUnwrap(PlayerBridge.parse(raw, app: .music))

        XCTAssertTrue(state.isPlaying)
        XCTAssertEqual(state.title, "Мотылёк")
        XCTAssertEqual(state.artist, "Макс Корж")
        XCTAssertEqual(state.album, "Жить в кайф")
        XCTAssertEqual(state.duration, 241)
        XCTAssertEqual(state.position, 37.5)
    }

    func testMissingOptionalMetadataDoesNotDiscardTrack() throws {
        let raw = ["paused", "Track", "", "", "0", "0", ""].joined(separator: "\u{1}")

        let state = try XCTUnwrap(PlayerBridge.parse(raw, app: .music))

        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.title, "Track")
        XCTAssertEqual(state.artist, "")
        XCTAssertEqual(state.album, "")
        XCTAssertEqual(state.duration, 0)
        XCTAssertEqual(state.position, 0)
    }

    func testEmptyTitleIsNotPresentedAsAPlayingTrack() {
        let raw = ["playing", "", "Artist", "Album", "1000", "500", ""].joined(separator: "\u{1}")
        XCTAssertNil(PlayerBridge.parse(raw, app: .music))
    }

    func testMapsAutomationAuthorizationStatuses() {
        XCTAssertEqual(PlayerBridge.automationAuthorization(for: noErr), .allowed)
        XCTAssertEqual(
            PlayerBridge.automationAuthorization(for: OSStatus(errAEEventWouldRequireUserConsent)),
            .notDetermined
        )
        XCTAssertEqual(
            PlayerBridge.automationAuthorization(for: OSStatus(errAEEventNotPermitted)),
            .denied
        )
        XCTAssertEqual(PlayerBridge.automationAuthorization(for: OSStatus(-1)), .restricted)
    }
}
