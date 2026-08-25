import AppKit
import WebKit
import XCTest
@testable import ImpulsCore

/// What happens when the web content process dies (IMP-12 / P0-1).
///
/// The delegate method is called directly. A real crash cannot be induced in a
/// unit test, and inducing one is not what needs pinning — what needs pinning
/// is that the handler clears state honestly, reports once, reloads nothing,
/// and cannot be driven by a web view this player no longer owns.
///
/// No page is ever loaded here: `WebMusicPlayer` builds its web view lazily and
/// these tests never call `show(source:)` against a real service, so nothing
/// touches the network.
@MainActor
final class WebPlayerProcessTerminationTests: XCTestCase {
    /// Records what the player reported, in order.
    private final class Recorder {
        var states: [(MusicSource, WebMusicState?)] = []
        var failures: [(MusicSource, String)] = []
        var loading: [(MusicSource, Bool)] = []
    }

    private func makePlayer() -> (WebMusicPlayer, Recorder) {
        let player = WebMusicPlayer()
        let recorder = Recorder()
        player.onState = { recorder.states.append(($0, $1)) }
        player.onFailure = { recorder.failures.append(($0, $1)) }
        player.onLoading = { recorder.loading.append(($0, $1)) }
        return (player, recorder)
    }

    /// Puts the player in the state a running session would have — a web view
    /// and a selected source — without loading anything.
    private func primed(_ source: MusicSource = .yandexMusic) throws -> (WebMusicPlayer, Recorder, WKWebView) {
        let (player, recorder) = makePlayer()
        let webView = player.prepareWithoutLoading(source: source)
        recorder.states.removeAll()
        return (player, recorder, webView)
    }

    // MARK: - 1. The active service

    func testTerminationClearsStateAndSurfacesAFailure() throws {
        let (player, recorder, webView) = try primed()

        player.webViewWebContentProcessDidTerminate(webView)

        XCTAssertEqual(recorder.states.count, 1)
        XCTAssertEqual(recorder.states.first?.0, .yandexMusic)
        XCTAssertNil(recorder.states.first?.1, "a dead page has no state")
        XCTAssertNil(player.currentState, "and the player must not keep the last track")

        XCTAssertEqual(recorder.failures.count, 1)
        XCTAssertEqual(recorder.failures.first?.0, .yandexMusic)
        XCTAssertEqual(recorder.failures.first?.1, WebMusicPlayer.processTerminatedMessage)
        XCTAssertFalse(recorder.failures.first?.1.isEmpty ?? true)

        XCTAssertEqual(recorder.loading.last?.1, false, "no spinner left running")
    }

    /// Capabilities are not cleared by a second path — they travel with the
    /// state, so the `nil` above is what resets them downstream.
    func testTerminationClearsCapabilitiesThroughTheStatePipeline() throws {
        let (player, recorder, webView) = try primed()

        player.webViewWebContentProcessDidTerminate(webView)

        let reported = try XCTUnwrap(recorder.states.first)
        XCTAssertNil(reported.1, "capabilities reset because the state itself is nil")
    }

    // MARK: - 2. No automatic reload

    func testTerminationDoesNotReloadOrNavigate() throws {
        let (player, _, webView) = try primed()

        player.webViewWebContentProcessDidTerminate(webView)

        XCTAssertNil(webView.url, "nothing was loaded")
        XCTAssertFalse(webView.isLoading, "and nothing was started — a crash must not become a retry loop")
    }

    // MARK: - 3. Repeated calls

    func testTheHandlerIsSafeToCallRepeatedly() throws {
        let (player, recorder, webView) = try primed()

        player.webViewWebContentProcessDidTerminate(webView)
        player.webViewWebContentProcessDidTerminate(webView)
        player.webViewWebContentProcessDidTerminate(webView)

        XCTAssertEqual(recorder.states.count, 3, "each call reports, and each report is the same honest nil")
        XCTAssertTrue(recorder.states.allSatisfy { $0.1 == nil })
        XCTAssertEqual(recorder.failures.count, 3)
        XCTAssertNil(player.currentState)
    }

    // MARK: - 4. Teardown after termination

    func testTeardownAfterTerminationStaysIdempotent() throws {
        let (player, _, webView) = try primed()

        player.webViewWebContentProcessDidTerminate(webView)
        player.teardown()
        player.teardown()

        XCTAssertFalse(player.hasWebView)
        XCTAssertNil(player.source)
        XCTAssertNil(player.currentState)
    }

    // MARK: - 5. Recovery

    /// The player must remain usable: `show(source:)` rebuilds through
    /// `webView ?? makeWebView()`, so the next explicit user action works.
    func testThePlayerRemainsUsableAfterTermination() throws {
        let (player, _, webView) = try primed()

        player.webViewWebContentProcessDidTerminate(webView)

        XCTAssertTrue(player.hasWebView, "the view object survives; only its content process died")
        XCTAssertEqual(player.source, .yandexMusic, "the selection is not forgotten")

        player.teardown()
        XCTAssertFalse(player.hasWebView)
        // And after a teardown the object is still constructible into a working
        // player rather than left broken.
        player.prepareWithoutLoading(source: .youtubeMusic)
        XCTAssertTrue(player.hasWebView)
        XCTAssertEqual(player.source, .youtubeMusic)
        player.teardown()
    }

    // MARK: - Recovery after termination
    //
    // `show(source:)` calls `showAction(...)` and does exactly what it returns,
    // so these test the production decision. Asserting on a real `WKWebView`
    // instead would mean loading a provider page over the network.

    private let providerURL = URL(string: "https://music.yandex.ru/home")!
    private let errorPageURL = URL(string: "about:blank")!

    /// 1. Nothing changed for a healthy page: still a snapshot, not a reload.
    func testAHealthySameSourcePageStillOnlyAsksForASnapshot() {
        XCTAssertEqual(
            WebMusicPlayer.showAction(
                sourceChanged: false,
                currentURL: providerURL,
                source: .yandexMusic,
                needsRecovery: false
            ),
            .snapshot
        )
    }

    /// 2. The gap this closes. A dead page keeps its provider URL, so without
    /// the flag this would ask a process that no longer exists for a snapshot
    /// and wait forever.
    func testATerminatedSameSourcePageIsRecoveredByNavigationRatherThanASnapshot() {
        XCTAssertEqual(
            WebMusicPlayer.showAction(
                sourceChanged: false,
                currentURL: providerURL,
                source: .yandexMusic,
                needsRecovery: true
            ),
            .recoveryReload,
            "a snapshot here is the dead end the user cannot escape"
        )
    }

    /// A crash on the local failure page has no provider URL to reload, so the
    /// recovery is a fresh load of the provider's home.
    func testRecoveryFromANonProviderURLLoadsTheProviderHome() {
        XCTAssertEqual(
            WebMusicPlayer.showAction(
                sourceChanged: false,
                currentURL: errorPageURL,
                source: .yandexMusic,
                needsRecovery: true
            ),
            .load
        )
        XCTAssertEqual(
            WebMusicPlayer.showAction(
                sourceChanged: false,
                currentURL: nil,
                source: .yandexMusic,
                needsRecovery: true
            ),
            .load
        )
    }

    /// 6. The flag belongs to the dead page, not to the next thing the user
    /// asks for: switching service after a crash is an ordinary load.
    func testASourceChangeAfterTerminationLoadsTheNewServiceNormally() {
        XCTAssertEqual(
            WebMusicPlayer.showAction(
                sourceChanged: true,
                currentURL: providerURL,
                source: .youtubeMusic,
                needsRecovery: true
            ),
            .load,
            "recovery state must not follow the user to another service"
        )
    }

    /// 3 + 4. One recovery, then back to ordinary behaviour. Driven through
    /// the real `show(source:)`, so the flag's lifecycle is what is tested.
    func testRecoveryHappensOnceAndThenNormalBehaviourResumes() throws {
        let (player, _, webView) = try primed()
        player.webViewWebContentProcessDidTerminate(webView)

        XCTAssertTrue(player.needsRecoveryLoadForTesting, "the crash raised it")

        player.show(source: .yandexMusic)
        XCTAssertFalse(player.needsRecoveryLoadForTesting, "and the explicit show consumed it")

        // A second show finds a healthy flag and takes the ordinary path.
        XCTAssertEqual(
            WebMusicPlayer.showAction(
                sourceChanged: false,
                currentURL: providerURL,
                source: .yandexMusic,
                needsRecovery: player.needsRecoveryLoadForTesting
            ),
            .snapshot
        )
        player.teardown()
    }

    /// 5. The callback reports; it does not navigate.
    func testTheTerminationCallbackItselfNavigatesNothing() throws {
        let (player, recorder, webView) = try primed()

        player.webViewWebContentProcessDidTerminate(webView)

        XCTAssertNil(webView.url)
        XCTAssertFalse(webView.isLoading, "recovery waits for the user, it does not start itself")
        XCTAssertTrue(player.needsRecoveryLoadForTesting)
        XCTAssertEqual(recorder.loading.last?.1, false)
    }

    /// 7. Teardown clears a pending recovery — a rebuilt player starts clean.
    func testTeardownClearsAPendingRecovery() throws {
        let (player, _, webView) = try primed()
        player.webViewWebContentProcessDidTerminate(webView)
        XCTAssertTrue(player.needsRecoveryLoadForTesting)

        player.teardown()

        XCTAssertFalse(player.needsRecoveryLoadForTesting)
    }

    /// 8. Repeated crashes leave the flag raised once, not stacked.
    func testRepeatedTerminationsLeaveOneRecoveryPending() throws {
        let (player, _, webView) = try primed()

        player.webViewWebContentProcessDidTerminate(webView)
        player.webViewWebContentProcessDidTerminate(webView)

        XCTAssertTrue(player.needsRecoveryLoadForTesting)
        player.show(source: .yandexMusic)
        XCTAssertFalse(player.needsRecoveryLoadForTesting, "one explicit show clears it")
        player.teardown()
    }

    // MARK: - 6. A view this player no longer owns

    func testTerminationOfAForeignWebViewIsIgnored() throws {
        let (player, recorder, _) = try primed()
        let foreign = WKWebView(frame: .zero)

        player.webViewWebContentProcessDidTerminate(foreign)

        XCTAssertTrue(recorder.states.isEmpty, "a view this player does not own cannot clear its state")
        XCTAssertTrue(recorder.failures.isEmpty)
    }

    /// After teardown the player owns nothing, so a late callback from the
    /// released view must not resurrect a failure for a service the user may
    /// already have switched away from.
    func testALateTerminationAfterTeardownIsIgnored() throws {
        let (player, recorder, webView) = try primed()

        player.teardown()
        recorder.states.removeAll()
        recorder.failures.removeAll()

        player.webViewWebContentProcessDidTerminate(webView)

        XCTAssertTrue(recorder.states.isEmpty)
        XCTAssertTrue(recorder.failures.isEmpty)
    }

    /// End to end: the failure and the clear both carry the source the player
    /// was showing, so `MediaController`'s `selectedSource == source` guard is
    /// what decides whether a switched-away service may act. Pinned here
    /// because the two halves only protect the user together.
    func testTheReportCarriesTheSourceSoTheControllerCanRejectIt() throws {
        let (player, recorder, webView) = try primed(.vkMusic)

        player.webViewWebContentProcessDidTerminate(webView)

        XCTAssertEqual(recorder.states.first?.0, .vkMusic)
        XCTAssertEqual(recorder.failures.first?.0, .vkMusic)
    }
}
