import Foundation
import XCTest
@testable import ImpulsCore

final class MusicSourceTests: XCTestCase {
    func testYandexAllowsServiceAndPassportButRejectsLookalikeHost() throws {
        XCTAssertTrue(MusicSource.yandexMusic.allowsTopLevelNavigation(
            to: try XCTUnwrap(URL(string: "https://music.yandex.ru/home"))
        ))
        XCTAssertTrue(MusicSource.yandexMusic.allowsTopLevelNavigation(
            to: try XCTUnwrap(URL(string: "https://passport.yandex.ru/auth"))
        ))
        XCTAssertFalse(MusicSource.yandexMusic.allowsTopLevelNavigation(
            to: try XCTUnwrap(URL(string: "https://yandex.ru.example.com/login"))
        ))
    }

    func testWebSourcesRequireHTTPS() throws {
        XCTAssertFalse(MusicSource.spotifyWeb.allowsTopLevelNavigation(
            to: try XCTUnwrap(URL(string: "http://open.spotify.com"))
        ))
        XCTAssertFalse(MusicSource.appleMusic.allowsTopLevelNavigation(
            to: try XCTUnwrap(URL(string: "https://music.apple.com"))
        ))
    }

    func testWebSnapshotIsBoundedAndClampsPosition() throws {
        let state = try XCTUnwrap(WebMusicState.decode([
            "version": 1,
            "page": "https://music.yandex.ru/home",
            "title": String(repeating: "Т", count: 700),
            "artist": "Исполнитель",
            "album": "Альбом",
            "duration": 180,
            "position": 500,
            "playing": true,
        ], source: .yandexMusic))

        XCTAssertEqual(state.title.count, 512)
        XCTAssertEqual(state.position, 180)
        XCTAssertTrue(state.isPlaying)
    }

    func testWebSnapshotRejectsAnotherProviderAndEmptyTrack() {
        XCTAssertNil(WebMusicState.decode([
            "version": 1,
            "page": "https://open.spotify.com",
            "title": "Track",
        ], source: .yandexMusic))
        XCTAssertNil(WebMusicState.decode([
            "version": 1,
            "page": "https://music.yandex.ru/home",
            "title": "",
        ], source: .yandexMusic))
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
}
