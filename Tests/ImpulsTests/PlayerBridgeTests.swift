import AppKit
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

    // MARK: - The scripts have to be valid AppleScript, not merely well-spelled

    /// `String.contains` cannot tell a valid script from an invalid one. The
    /// defect this guards against — `set st to player state as text` — is a
    /// *compile* error (`-2741`), because `st`, `nd`, `rd` and `th` are
    /// AppleScript's reserved ordinal-suffix tokens (`1st word of …`).
    ///
    /// Compilation is safe to assert here, but for a narrower reason than
    /// "compiling is harmless". `compileAndReturnError` has to obtain the
    /// target's terminology: for a bundle that ships an `.sdef` it reads it
    /// from disk, but for an `aete`-only target it **launches the application**
    /// to ask — `com.apple.TextEdit` starts up on compile alone. Both native
    /// providers declare `OSAScriptingDefinition`, so neither is launched, no
    /// Apple Event is sent, no Automation grant is needed and playback is
    /// untouched. `assertCompiles` asserts that precondition rather than
    /// trusting it, so a future provider without an `.sdef` fails the test
    /// instead of silently opening the user's app.
    ///
    /// `executeAndReturnError` is what would read state, and it is never called
    /// here.
    private func assertCompiles(
        _ source: String,
        _ label: String,
        bundleID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertTerminologyComesFromDisk(bundleID, label, file: file, line: line)
        guard let script = NSAppleScript(source: source) else {
            return XCTFail("\(label): NSAppleScript could not be constructed", file: file, line: line)
        }
        var error: NSDictionary?
        let compiled = script.compileAndReturnError(&error)
        let number = error?[NSAppleScript.errorNumber] as? Int
        let message = error?[NSAppleScript.errorMessage] as? String
        XCTAssertTrue(
            compiled,
            "\(label) does not compile: \(number.map(String.init) ?? "?") \(message ?? "")",
            file: file,
            line: line
        )
    }

    /// Compiling may only read terminology from disk. A target without an
    /// `.sdef` would be launched by the compile itself, which a unit test must
    /// never do to the user's applications.
    private func assertTerminologyComesFromDisk(
        _ bundleID: String,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url) else {
            return XCTFail("\(label): \(bundleID) could not be located", file: file, line: line)
        }
        XCTAssertNotNil(
            bundle.object(forInfoDictionaryKey: "OSAScriptingDefinition"),
            "\(label): \(bundleID) ships no .sdef, so compiling it would launch the app",
            file: file,
            line: line
        )
    }

    func testAppleMusicStateScriptCompiles() throws {
        try XCTSkipUnless(PlayerApp.music.isInstalled, "Apple Music is not installed on this machine")
        assertCompiles(
            PlayerBridge.stateScript(for: .music),
            "Apple Music state script",
            bundleID: PlayerApp.music.bundleID
        )
    }

    /// Spotify is a third-party app, so CI runners do not have it. The check is
    /// skipped rather than failed there — a real Mac with Spotify installed is
    /// where this one earns its keep.
    func testSpotifyStateScriptCompiles() throws {
        try XCTSkipUnless(PlayerApp.spotify.isInstalled, "Spotify is not installed on this machine")
        assertCompiles(
            PlayerBridge.stateScript(for: .spotify),
            "Spotify state script",
            bundleID: PlayerApp.spotify.bundleID
        )
    }

    /// The structural half of the guard: it needs no installed app, so it runs
    /// everywhere the compile checks may skip, and it fails on the identifier
    /// itself rather than on a downstream symptom.
    func testNoStateScriptBindsAReservedOrdinalIdentifier() {
        for app in PlayerApp.allCases {
            let script = PlayerBridge.stateScript(for: app)
            for reserved in ["st", "nd", "rd", "th"] {
                XCTAssertFalse(
                    script.contains("set \(reserved) to"),
                    "\(app.displayName) script binds `\(reserved)`, which AppleScript reserves as an ordinal suffix"
                )
            }
        }
    }

    /// A closed app is not a permissions problem. The pane renders any access
    /// issue as "Allow Automation access to read …" with an Open Settings
    /// button, so letting `undeterminedAppNotRunning` through would put a
    /// permissions dialog in front of a user who merely quit the player.
    func testAnAppThatQuitMidQueryIsNotReportedAsAPermissionsProblem() {
        XCTAssertFalse(PlayerBridge.isActionableAccessIssue(.undeterminedAppNotRunning))
        XCTAssertFalse(PlayerBridge.isActionableAccessIssue(.allowed))

        for actionable in [AutomationAuthorization.denied, .notDetermined, .restricted] {
            XCTAssertTrue(
                PlayerBridge.isActionableAccessIssue(actionable),
                "\(actionable) is a real verdict the user can act on"
            )
        }
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

        // `procNotFound` is what a closed target answers. It is not a TCC
        // verdict, so it must not be reported as one — least of all as
        // `restricted`, which claims a policy block the user cannot lift.
        XCTAssertEqual(
            PlayerBridge.automationAuthorization(for: OSStatus(procNotFound)),
            .undeterminedAppNotRunning
        )
        XCTAssertNotEqual(PlayerBridge.automationAuthorization(for: OSStatus(procNotFound)), .restricted)
        XCTAssertNotEqual(PlayerBridge.automationAuthorization(for: OSStatus(procNotFound)), .allowed)
        XCTAssertNotEqual(PlayerBridge.automationAuthorization(for: OSStatus(procNotFound)), .denied)
    }
}
