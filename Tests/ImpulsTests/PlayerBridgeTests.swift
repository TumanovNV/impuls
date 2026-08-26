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
        XCTAssertTrue(state.positionIsKnown)
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

    func testParsesAppleMusicDistributedNotificationAsFallback() throws {
        let state = try XCTUnwrap(PlayerBridge.parseNotification([
            "Player State": "Playing",
            "Name": "Мотылёк",
            "Artist": "Макс Корж",
            "Album": "Жить в кайф",
            "Total Time": NSNumber(value: 241_000),
            "Player Position": NSNumber(value: 37.5),
        ]))

        XCTAssertTrue(state.isPlaying)
        XCTAssertEqual(state.title, "Мотылёк")
        XCTAssertEqual(state.duration, 241)
        XCTAssertEqual(state.position, 37.5)
        XCTAssertTrue(state.positionIsKnown)
    }

    func testNotificationWithoutTitleIsNotPresentedAsTrack() {
        XCTAssertNil(PlayerBridge.parseNotification([
            "Player State": "Playing",
            "Artist": "Artist",
        ]))
    }

    func testEmptyTitleIsNotPresentedAsAPlayingTrack() {
        let raw = ["playing", "", "Artist", "Album", "1000", "500", ""].joined(separator: "\u{1}")
        XCTAssertNil(PlayerBridge.parse(raw, app: .music))
    }

    func testParsesSpotifyStateWithProviderSpecificMilliseconds() throws {
        let raw = ["playing", "Djurens vaggvisa", "Humlan Djojj", "Somna med Humlan Djojj", "140046", "24694", ""].joined(separator: "\u{1}")
        let state = try XCTUnwrap(PlayerBridge.parse(raw, app: .spotify))
        XCTAssertTrue(state.isPlaying)
        XCTAssertEqual(state.duration, 140.046, accuracy: 0.0001)
        XCTAssertEqual(state.position, 24.694, accuracy: 0.0001)
    }

    func testSpotifyPausedStateAndMalformedNumbersAreSafe() throws {
        let raw = ["paused", "Track", "Artist", "Album", "140046", "24694", ""].joined(separator: "\u{1}")
        XCTAssertFalse(try XCTUnwrap(PlayerBridge.parse(raw, app: .spotify)).isPlaying)
        for value in ["-1", "nan", "inf"] {
            XCTAssertNil(PlayerBridge.parse(["playing", "Track", "Artist", "Album", value, "0", ""].joined(separator: "\u{1}"), app: .spotify))
        }
    }

    func testSpotifyScriptAndTransportUseOnlyDeclaredCommands() {
        let script = PlayerBridge.stateScript(for: .spotify)
        XCTAssertTrue(script.contains("tell application id \"com.spotify.client\""))
        XCTAssertTrue(script.contains("set playerStateText to (player state as text)"))
        XCTAssertTrue(script.contains("duration of currentSpotifyTrack"))
        XCTAssertTrue(script.contains("set trackDurationMilliseconds to (duration of currentSpotifyTrack) as integer"))
        XCTAssertTrue(script.contains("set positionMilliseconds to ((player position) * 1000) as integer"))
        XCTAssertFalse(script.contains("set st to player state"))
        XCTAssertFalse(script.contains("round ((player position) * 1000)"))
        XCTAssertFalse(script.contains("track ID"))
        XCTAssertFalse(script.contains("play count"))
        XCTAssertEqual(PlayerBridge.transportCommand(.playPause, on: .spotify), "playpause")
        XCTAssertEqual(PlayerBridge.transportCommand(.next, on: .spotify), "next track")
        XCTAssertEqual(PlayerBridge.transportCommand(.previous, on: .spotify), "previous track")
        XCTAssertEqual(PlayerBridge.transportCommand(.previous, on: .music), "back track")
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
