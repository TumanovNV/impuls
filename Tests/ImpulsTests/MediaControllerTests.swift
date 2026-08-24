import AppKit
import XCTest
@testable import ImpulsCore

/// Records every call `MediaController` makes and lets a test drive
/// `currentState`'s completion on its own schedule, which is what the
/// stale-refresh tests below need: a fetch has to still be "in flight" after
/// a newer state has already landed.
@MainActor
private final class FakeNativeMusicBridging: NativeMusicBridging {
    private(set) var pendingCurrentState: [(PlayerScanResult) -> Void] = []
    private(set) var playPauseCallCount = 0
    private(set) var nextCallCount = 0
    private(set) var previousCallCount = 0
    private(set) var seeks: [TimeInterval] = []
    var automationAuthorizationResult: AutomationAuthorization = .allowed

    func currentState(completion: @escaping (PlayerScanResult) -> Void) {
        pendingCurrentState.append(completion)
    }

    /// Completes the oldest still-pending fetch, matching the order real
    /// AppleScript calls would return in without assuming they return in the
    /// order they were issued.
    func completeOldestPending(with result: PlayerScanResult) {
        guard !pendingCurrentState.isEmpty else {
            XCTFail("no pending currentState fetch to complete")
            return
        }
        pendingCurrentState.removeFirst()(result)
    }

    func playPause() { playPauseCallCount += 1 }
    func next() { nextCallCount += 1 }
    func previous() { previousCallCount += 1 }
    func seek(to seconds: TimeInterval) { seeks.append(seconds) }

    func artwork(for state: PlayerState, completion: @escaping (NSImage?) -> Void) {
        completion(nil)
    }

    func automationAuthorization(prompt: Bool, completion: @escaping (AutomationAuthorization) -> Void) {
        completion(automationAuthorizationResult)
    }
}

/// A web player double that never touches WebKit or the network. `show`
/// synchronously simulates the page reporting state, since the production
/// bridge is itself asynchronous JS→Swift messaging that a unit test cannot
/// wait on deterministically.
@MainActor
private final class FakeWebMusicPlayer: WebMusicPlaying {
    var onState: ((MusicSource, WebMusicState?) -> Void)?
    var onArtwork: ((MusicSource, String, NSImage?) -> Void)?
    var onLoading: ((MusicSource, Bool) -> Void)?
    var onFailure: ((MusicSource, String) -> Void)?
    private(set) var source: MusicSource?
    var currentState: WebMusicState?

    private(set) var showCallCount = 0
    private(set) var commandsSent: [WebMusicCommand] = []
    private(set) var seeks: [TimeInterval] = []
    private(set) var requestSnapshotCallCount = 0
    private(set) var deactivateCallCount = 0
    private(set) var teardownCallCount = 0

    /// When set, `show(source:)` reports this state immediately, as if the
    /// page had already loaded and pushed its first snapshot.
    var stateToReportOnShow: WebMusicState?

    func show(source: MusicSource) {
        showCallCount += 1
        self.source = source
        if let state = stateToReportOnShow {
            currentState = state
            onState?(source, state)
        }
    }

    func command(_ command: WebMusicCommand) { commandsSent.append(command) }
    func seek(to seconds: TimeInterval) { seeks.append(seconds) }
    func requestSnapshot() { requestSnapshotCallCount += 1 }
    func deactivate() { deactivateCallCount += 1 }
    func teardown() {
        teardownCallCount += 1
        source = nil
        currentState = nil
    }
}

@MainActor
final class MediaControllerTests: XCTestCase {
    private func freshDefaults() -> (UserDefaults, String) {
        let suite = "MediaControllerTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func appleMusicState(title: String, position: TimeInterval = 0, duration: TimeInterval = 200) -> PlayerState {
        PlayerState(
            app: .music,
            isPlaying: true,
            title: title,
            artist: "Artist",
            album: "Album",
            duration: duration,
            position: position,
            positionIsKnown: true,
            artworkURL: nil
        )
    }

    // MARK: - Stale-refresh suppression

    /// The exact race this fix targets: a scripting fetch for track A is
    /// still in flight when a distributed notification adopts track B. The
    /// production observer calls `adopt(_:)` directly from the notification
    /// handler (see `MediaController.start()`), which is reproduced here by
    /// calling it through the same seam. Track A's late answer must not
    /// revert the UI.
    func testLateAppleMusicFetchForAnOldTrackDoesNotOverwriteANewerAdoptedTrack() throws {
        let bridge = FakeNativeMusicBridging()
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MediaController(defaults: defaults, nativeBridge: bridge)

        controller.start()
        XCTAssertEqual(bridge.pendingCurrentState.count, 1, "start() on Apple Music issues one fetch")

        // A distributed notification for a newer track lands and is adopted
        // synchronously, exactly as `start()`'s observer does.
        controller.adopt(appleMusicState(title: "Newer Track"))
        XCTAssertEqual(controller.track?.title, "Newer Track")
        let generationAfterNotification = controller.stateGeneration

        // The original fetch — issued before that notification — now
        // resolves with what was current when it was issued.
        bridge.completeOldestPending(with: PlayerScanResult(
            state: appleMusicState(title: "Older Track"),
            accessIssue: nil,
            hasRunningPlayer: true,
            readFailed: false
        ))

        XCTAssertEqual(controller.track?.title, "Newer Track", "a stale fetch must not resurrect an old track")
        XCTAssertEqual(controller.stateGeneration, generationAfterNotification, "a discarded stale result must not bump the generation again")
    }

    /// The same fetch, still in flight, resolving with the *current* track
    /// must keep working — the guard only rejects genuinely stale answers.
    func testAppleMusicFetchMatchingTheCurrentGenerationIsStillAdopted() throws {
        let bridge = FakeNativeMusicBridging()
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MediaController(defaults: defaults, nativeBridge: bridge)

        controller.start()
        bridge.completeOldestPending(with: PlayerScanResult(
            state: appleMusicState(title: "Now Playing"),
            accessIssue: nil,
            hasRunningPlayer: true,
            readFailed: false
        ))

        XCTAssertEqual(controller.track?.title, "Now Playing")
    }

    // MARK: - Capabilities

    func testAppleMusicTrackReportsFullCapabilitiesOnceLoaded() throws {
        let bridge = FakeNativeMusicBridging()
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MediaController(defaults: defaults, nativeBridge: bridge)

        controller.adopt(appleMusicState(title: "Track"))

        XCTAssertEqual(controller.capabilities, MediaCapabilities(
            canPlayPause: true, canNext: true, canPrevious: true, canSeek: true
        ))
    }

    func testWebCapabilitiesMirrorExactlyWhatThePageReported() throws {
        let bridge = FakeNativeMusicBridging()
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(MusicSource.yandexMusic.rawValue, forKey: MediaController.selectedSourceKey)
        var webPlayer: FakeWebMusicPlayer?
        let controller = MediaController(defaults: defaults, nativeBridge: bridge, webPlayerFactory: {
            let player = FakeWebMusicPlayer()
            webPlayer = player
            return player
        })

        webPlayer = nil
        controller.openSelectedSource()
        let player = try XCTUnwrap(webPlayer)
        player.stateToReportOnShow = nil
        player.onState?(.yandexMusic, WebMusicState(
            title: "Track", artist: "Artist", album: "Album",
            duration: 200, position: 0, isPlaying: true, artworkKey: "",
            canNext: true, canPrevious: false, canPlayPause: true, canSeek: false
        ))

        XCTAssertEqual(controller.capabilities, MediaCapabilities(
            canPlayPause: true, canNext: true, canPrevious: false, canSeek: false
        ))

        // A control the page never proved must actually be gated, not merely
        // reported as false for the UI's benefit.
        controller.previous()
        XCTAssertTrue(player.commandsSent.isEmpty)
        controller.next()
        XCTAssertEqual(player.commandsSent, [.next])
    }

    func testClearingResetsCapabilitiesToAllFalse() throws {
        let bridge = FakeNativeMusicBridging()
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MediaController(defaults: defaults, nativeBridge: bridge)

        controller.adopt(appleMusicState(title: "Track"))
        XCTAssertTrue(controller.capabilities.canPlayPause)

        controller.selectSource(.yandexMusic)

        XCTAssertEqual(controller.capabilities, MediaCapabilities())
    }

    func testTogglePlayPauseIsANoOpWhenNotYetProvenCapable() throws {
        let bridge = FakeNativeMusicBridging()
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MediaController(defaults: defaults, nativeBridge: bridge)

        // No track adopted: capabilities default to all-false.
        controller.togglePlayPause()
        controller.next()
        controller.previous()

        XCTAssertEqual(bridge.playPauseCallCount, 0)
        XCTAssertEqual(bridge.nextCallCount, 0)
        XCTAssertEqual(bridge.previousCallCount, 0)
    }

    // MARK: - Lifecycle

    /// `stop()` must tear the web player down and release it so a later
    /// `openSelectedSource()` builds a fresh one rather than reusing —
    /// or worse, leaving two — background bridges alive.
    func testStopTearsDownTheWebPlayerAndReopenBuildsExactlyOneReplacement() throws {
        let bridge = FakeNativeMusicBridging()
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(MusicSource.yandexMusic.rawValue, forKey: MediaController.selectedSourceKey)
        var built: [FakeWebMusicPlayer] = []
        let controller = MediaController(defaults: defaults, nativeBridge: bridge, webPlayerFactory: {
            let player = FakeWebMusicPlayer()
            built.append(player)
            return player
        })

        controller.openSelectedSource()
        XCTAssertEqual(built.count, 1)

        controller.stop()
        XCTAssertEqual(built[0].teardownCallCount, 1)

        controller.openSelectedSource()
        XCTAssertEqual(built.count, 2, "reopening after stop() must build a fresh player, not reuse the torn-down one")
        XCTAssertEqual(built[1].teardownCallCount, 0)
    }

    /// Opening the same already-open source twice must not construct a
    /// second web player behind the first one's back.
    func testReopeningTheSameSourceDoesNotDuplicateTheWebPlayer() throws {
        let bridge = FakeNativeMusicBridging()
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(MusicSource.yandexMusic.rawValue, forKey: MediaController.selectedSourceKey)
        var built: [FakeWebMusicPlayer] = []
        let controller = MediaController(defaults: defaults, nativeBridge: bridge, webPlayerFactory: {
            let player = FakeWebMusicPlayer()
            built.append(player)
            return player
        })

        controller.openSelectedSource()
        controller.openSelectedSource()

        XCTAssertEqual(built.count, 1)
    }

    // MARK: - No network from read-only state

    /// Constructing the controller and reading its published state must
    /// never build a web player — only an explicit `openSelectedSource()`
    /// may.
    func testConstructionAndSourceSelectionNeverBuildAWebPlayer() throws {
        let bridge = FakeNativeMusicBridging()
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var built = 0
        let controller = MediaController(defaults: defaults, nativeBridge: bridge, webPlayerFactory: {
            built += 1
            return FakeWebMusicPlayer()
        })

        _ = controller.selectedSource
        _ = controller.track
        controller.selectSource(.yandexMusic)
        controller.selectSource(.vkMusic)
        controller.start()

        XCTAssertEqual(built, 0, "selecting a web source must stay local until Open Web Player is pressed")
    }
}
