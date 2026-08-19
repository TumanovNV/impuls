import Foundation
import XCTest
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif
@testable import ImpulsCore

final class MusicSourceTests: XCTestCase {
    func testYandexAllowsServiceAndPassportButRejectsLookalikeHost() throws {
        XCTAssertTrue(MusicSource.yandexMusic.allowsMainFrameNavigation(
            to: try XCTUnwrap(URL(string: "https://music.yandex.ru/home"))
        ))
        XCTAssertTrue(MusicSource.yandexMusic.allowsMainFrameNavigation(
            to: try XCTUnwrap(URL(string: "https://passport.yandex.ru/auth"))
        ))
        XCTAssertFalse(MusicSource.yandexMusic.allowsMainFrameNavigation(
            to: try XCTUnwrap(URL(string: "https://yandex.ru.example.com/login"))
        ))
    }

    /// vk.com/audio hands an unauthenticated visitor to vk.ru, and YouTube Music
    /// hands one to accounts.google.com. Both used to be dead ends.
    func testSignInRedirectsStayInsideTheirProvider() throws {
        XCTAssertTrue(MusicSource.vkMusic.allowsMainFrameNavigation(
            to: try XCTUnwrap(URL(string: "https://vk.ru/?to=L2F1ZGlv"))
        ))
        XCTAssertTrue(MusicSource.vkMusic.allowsMainFrameNavigation(
            to: try XCTUnwrap(URL(string: "https://id.vk.com/auth"))
        ))
        XCTAssertTrue(MusicSource.youtubeMusic.allowsMainFrameNavigation(
            to: try XCTUnwrap(URL(string: "https://accounts.google.com/ServiceLogin"))
        ))
        XCTAssertFalse(MusicSource.youtubeMusic.allowsMainFrameNavigation(
            to: try XCTUnwrap(URL(string: "https://vk.com/audio"))
        ))
    }

    /// A captcha or consent widget is a third-party subframe by design. Holding
    /// subframes to the main-frame list is what left the sign-in pages blank.
    func testSubframesAreNotHeldToTheMainFrameList() throws {
        XCTAssertTrue(MusicSource.allowsSubframeNavigation(
            to: try XCTUnwrap(URL(string: "https://www.google.com/recaptcha/api2/anchor"))
        ))
        XCTAssertTrue(MusicSource.allowsSubframeNavigation(
            to: try XCTUnwrap(URL(string: "about:blank"))
        ))
        XCTAssertFalse(MusicSource.allowsSubframeNavigation(
            to: try XCTUnwrap(URL(string: "file:///etc/passwd"))
        ))
    }

    func testWebSourcesRequireHTTPS() throws {
        XCTAssertFalse(MusicSource.youtubeMusic.allowsMainFrameNavigation(
            to: try XCTUnwrap(URL(string: "http://music.youtube.com"))
        ))
        XCTAssertFalse(MusicSource.appleMusic.allowsMainFrameNavigation(
            to: try XCTUnwrap(URL(string: "https://music.apple.com"))
        ))
    }

    /// about:blank is navigable — the failure page and popup shells use it —
    /// but it must never be accepted as a source of playback state.
    func testBlankPageMayLoadButMayNotReportState() throws {
        let blank = try XCTUnwrap(URL(string: "about:blank"))
        XCTAssertTrue(MusicSource.yandexMusic.allowsMainFrameNavigation(to: blank))
        XCTAssertFalse(MusicSource.yandexMusic.allowsStateReport(from: blank))
    }

    func testWebSnapshotIsBoundedAndClampsPosition() throws {
        let state = try XCTUnwrap(WebMusicState.decode([
            "version": 2,
            "kind": "state",
            "page": "https://music.yandex.ru/home",
            "title": String(repeating: "Т", count: 700),
            "artist": "Исполнитель",
            "album": "Альбом",
            "duration": 180,
            "position": 500,
            "playing": true,
            "artworkKey": "https://avatars.yandex.net/get-music-content/1/200x200",
        ], source: .yandexMusic))

        XCTAssertEqual(state.title.count, 512)
        XCTAssertEqual(state.position, 180)
        XCTAssertTrue(state.isPlaying)
        XCTAssertEqual(state.artworkKey, "https://avatars.yandex.net/get-music-content/1/200x200")
    }

    func testWebSnapshotRejectsAnotherProviderEmptyTrackAndOldVersion() {
        XCTAssertNil(WebMusicState.decode([
            "version": 2,
            "kind": "state",
            "page": "https://music.youtube.com/",
            "title": "Track",
        ], source: .yandexMusic))
        XCTAssertNil(WebMusicState.decode([
            "version": 2,
            "kind": "state",
            "page": "https://music.yandex.ru/home",
            "title": "",
        ], source: .yandexMusic))
        XCTAssertNil(WebMusicState.decode([
            "version": 1,
            "kind": "state",
            "page": "https://music.yandex.ru/home",
            "title": "Track",
        ], source: .yandexMusic))
    }

    func testArtworkPayloadIsBoundedAndOriginChecked() throws {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let artwork = try XCTUnwrap(WebMusicArtwork.decode([
            "version": 2,
            "kind": "artwork",
            "page": "https://music.youtube.com/",
            "key": "https://lh3.googleusercontent.com/cover",
            "data": bytes.base64EncodedString(),
        ], source: .youtubeMusic))
        XCTAssertEqual(artwork.data, bytes)

        XCTAssertNil(WebMusicArtwork.decode([
            "version": 2,
            "kind": "artwork",
            "page": "https://music.youtube.com/",
            "key": "https://lh3.googleusercontent.com/cover",
            "data": String(repeating: "A", count: WebMusicArtwork.maximumEncodedCharacters + 4),
        ], source: .youtubeMusic))

        XCTAssertNil(WebMusicArtwork.decode([
            "version": 2,
            "kind": "artwork",
            "page": "https://music.youtube.com/",
            "key": "https://lh3.googleusercontent.com/cover",
            "data": bytes.base64EncodedString(),
        ], source: .yandexMusic))
    }

    /// The bridge's own status lines are bounded before they reach the log.
    func testDiagnosticPayloadIsBoundedAndDistinctFromState() throws {
        let diagnostic = try XCTUnwrap(WebMusicDiagnostic.decode([
            "version": 2,
            "kind": "diagnostic",
            "level": "route",
            "message": String(repeating: "x", count: 900),
        ]))
        XCTAssertEqual(diagnostic.level, "route")
        XCTAssertEqual(diagnostic.message.count, 512)

        XCTAssertNil(WebMusicDiagnostic.decode([
            "version": 2, "kind": "diagnostic", "message": "",
        ]))
        XCTAssertNil(WebMusicDiagnostic.decode([
            "version": 2,
            "kind": "state",
            "page": "https://music.yandex.ru/home",
            "message": "not a diagnostic",
        ]))
    }

    /// WKUserScript's main-frame flag controls where the bridge program is
    /// installed, not where a named message handler is visible. The native
    /// receiver must enforce the frame boundary independently.
    @MainActor
    func testBridgeAcceptsOnlyTheSelectedProviderMainFrame() throws {
        let page = try XCTUnwrap(URL(string: "https://music.yandex.ru/home"))
        XCTAssertTrue(WebMusicPlayer.acceptsBridgeMessage(
            source: .yandexMusic,
            mainPageURL: page,
            isMainFrame: true
        ))
        XCTAssertFalse(WebMusicPlayer.acceptsBridgeMessage(
            source: .yandexMusic,
            mainPageURL: page,
            isMainFrame: false
        ))
        XCTAssertFalse(WebMusicPlayer.acceptsBridgeMessage(
            source: .youtubeMusic,
            mainPageURL: page,
            isMainFrame: true
        ))
    }

    /// The bridge is embedded in Swift as a raw string, so Swift compilation
    /// alone cannot detect a malformed JavaScript edit.
    @MainActor
    func testBridgeScriptParsesAsJavaScript() throws {
        #if canImport(JavaScriptCore)
        let context = try XCTUnwrap(JSContext())
        context.setObject(
            WebMusicPlayer.bridgeScript,
            forKeyedSubscript: "impulsBridgeSource" as NSString
        )
        let function = context.evaluateScript("new Function(impulsBridgeSource)")
        XCTAssertNil(context.exception, context.exception?.toString() ?? "JavaScript syntax error")
        XCTAssertFalse(try XCTUnwrap(function).isUndefined)
        #else
        XCTFail("JavaScriptCore is required on the supported macOS platform")
        #endif
    }

    /// Spotify's web player decrypts through Widevine, which WebKit does not
    /// implement, so it must not be offered as a source at all.
    func testSpotifyIsNotOffered() {
        XCTAssertNil(MusicSource(rawValue: "spotifyWeb"))
        XCTAssertEqual(MusicSource.allCases.map(\.rawValue),
                       ["appleMusic", "yandexMusic", "vkMusic", "youtubeMusic"])
    }

    /// The Safari token is what the providers sniff for. Without it the pages
    /// render blank, which is the bug this release fixes.
    @MainActor
    func testUserAgentCarriesTheSafariToken() {
        let token = WebMusicPlayer.safariUserAgentToken
        XCTAssertTrue(token.hasPrefix("Version/"))
        XCTAssertTrue(token.hasSuffix("Safari/605.1.15"))
    }

    @MainActor
    func testMediaSourceSelectionPersistsWithoutOpeningWebPlayer() throws {
        let suite = "MusicSourceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = MediaController(defaults: defaults)
        first.selectSource(.yandexMusic)
        XCTAssertEqual(first.selectedSource, .yandexMusic)
        XCTAssertFalse(first.webPlayerWasOpened)

        let restored = MediaController(defaults: defaults)
        XCTAssertEqual(restored.selectedSource, .yandexMusic)
        XCTAssertEqual(restored.emptyReason, .webPlayerNotOpen)
        XCTAssertFalse(restored.webPlayerWasOpened)
    }

    /// A stored source that no longer exists must fall back, not crash or leave
    /// the pane pointing at a player Impuls cannot drive.
    @MainActor
    func testRemovedSourceFallsBackToAppleMusic() throws {
        let suite = "MusicSourceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("spotifyWeb", forKey: MediaController.selectedSourceKey)
        let controller = MediaController(defaults: defaults)
        XCTAssertEqual(controller.selectedSource, .appleMusic)
        XCTAssertEqual(controller.emptyReason, .appleMusicNotRunning)
    }

    // MARK: - Durations the app did not produce

    /// `duration` arrives from the provider's page through the web bridge, so
    /// its magnitude is not the app's to trust. `Int(_:)` is a trap rather than
    /// an overflow outside `Int`'s range, and the media pane formats the value
    /// on every draw — including from `accessibilityValue`, so VoiceOver reached
    /// the same conversion.
    func testFormatTimeIsTotalForADurationReportedByAWebPage() {
        XCTAssertEqual(formatTime(.nan), "--:--")
        XCTAssertEqual(formatTime(.infinity), "--:--")
        XCTAssertEqual(formatTime(-.infinity), "--:--")
        XCTAssertEqual(formatTime(-1), "--:--")
        XCTAssertEqual(formatTime(1e30), "--:--")
        XCTAssertEqual(formatTime(.greatestFiniteMagnitude), "--:--")

        // Real durations keep formatting exactly as before.
        XCTAssertEqual(formatTime(0), "0:00")
        XCTAssertEqual(formatTime(9), "0:09")
        XCTAssertEqual(formatTime(61), "1:01")
        XCTAssertEqual(formatTime(241), "4:01")
        XCTAssertEqual(formatTime(3_600), "60:00")
    }

    /// The same value reaches AppleScript as a spliced-in integer. The guard has
    /// to hold before the conversion, not after.
    func testSeekingToAnUnrepresentablePositionIsDroppedRatherThanConverted() {
        // Apple Music is not running under test, so `command` is a no-op; what
        // is being proven is that the conversion in front of it cannot trap.
        PlayerBridge.seek(.music, to: .infinity)
        PlayerBridge.seek(.music, to: .nan)
        PlayerBridge.seek(.music, to: 1e30)
        PlayerBridge.seek(.music, to: -1)
        PlayerBridge.seek(.music, to: 241)
    }
}
