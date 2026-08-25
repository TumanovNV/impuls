import AppKit
import WebKit

struct WebMusicState: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var position: TimeInterval
    var isPlaying: Bool
    /// Identity of the cover the page is currently showing. Impuls never
    /// downloads it — the page hands the bytes over on request.
    var artworkKey: String
    /// What the page's own transport route lookup found — the exact same
    /// lookup `command(_:)` uses to act, not a separate guess. Absent from an
    /// older/mismatched payload defaults to `false`: an unproven capability is
    /// not offered.
    var canNext: Bool
    var canPrevious: Bool
    var canPlayPause: Bool
    var canSeek: Bool

    var key: String { "web|\(title)|\(artist)|\(album)" }

    static func decode(_ body: Any, source: MusicSource) -> WebMusicState? {
        guard let payload = body as? [String: Any],
              (payload["version"] as? NSNumber)?.intValue == 2,
              payload["kind"] as? String == "state",
              let page = payload["page"] as? String,
              let pageURL = URL(string: page),
              source.allowsStateReport(from: pageURL) else { return nil }

        let title = bounded(payload["title"] as? String, maximum: 512)
        guard !title.isEmpty else { return nil }

        let duration = finiteNonnegative(payload["duration"])
        let rawPosition = finiteNonnegative(payload["position"])
        return WebMusicState(
            title: title,
            artist: bounded(payload["artist"] as? String, maximum: 512),
            album: bounded(payload["album"] as? String, maximum: 512),
            duration: duration,
            position: duration > 0 ? min(rawPosition, duration) : rawPosition,
            isPlaying: (payload["playing"] as? NSNumber)?.boolValue ?? false,
            artworkKey: bounded(payload["artworkKey"] as? String, maximum: 2_048),
            canNext: (payload["canNext"] as? NSNumber)?.boolValue ?? false,
            canPrevious: (payload["canPrevious"] as? NSNumber)?.boolValue ?? false,
            canPlayPause: (payload["canPlayPause"] as? NSNumber)?.boolValue ?? false,
            canSeek: (payload["canSeek"] as? NSNumber)?.boolValue ?? false
        )
    }

    private static func bounded(_ value: String?, maximum: Int) -> String {
        guard let value else { return "" }
        return String(value.prefix(maximum)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func finiteNonnegative(_ value: Any?) -> Double {
        guard let number = value as? NSNumber else { return 0 }
        let result = number.doubleValue
        return result.isFinite ? max(0, result) : 0
    }
}

/// Cover bytes handed over by the page after Impuls asks for them.
struct WebMusicArtwork: Equatable {
    /// Base64 payload accepted from the page, before any image parsing.
    static let maximumEncodedCharacters = 6 * 1_024 * 1_024

    var key: String
    var data: Data

    static func decode(_ body: Any, source: MusicSource) -> WebMusicArtwork? {
        guard let payload = body as? [String: Any],
              (payload["version"] as? NSNumber)?.intValue == 2,
              payload["kind"] as? String == "artwork",
              let page = payload["page"] as? String,
              let pageURL = URL(string: page),
              source.allowsStateReport(from: pageURL),
              let key = payload["key"] as? String, !key.isEmpty, key.count <= 2_048,
              let encoded = payload["data"] as? String,
              !encoded.isEmpty,
              encoded.count <= maximumEncodedCharacters,
              let data = Data(base64Encoded: encoded),
              data.count <= PlayerBridge.maximumArtworkBytes else { return nil }
        return WebMusicArtwork(key: key, data: data)
    }
}

enum WebMusicCommand: String {
    case playPause
    case next
    case previous
}

/// What the page reported about itself when it failed to start. Never shown to
/// the user and never stored — it exists so a provider that hangs on its own
/// splash screen can be diagnosed from the system log instead of guessed at.
struct WebMusicDiagnostic: Equatable {
    var level: String
    var message: String

    static func decode(_ body: Any) -> WebMusicDiagnostic? {
        guard let payload = body as? [String: Any],
              (payload["version"] as? NSNumber)?.intValue == 2,
              payload["kind"] as? String == "diagnostic",
              let message = payload["message"] as? String,
              !message.isEmpty else { return nil }
        return WebMusicDiagnostic(
            level: String((payload["level"] as? String ?? "error").prefix(32)),
            message: String(message.prefix(512))
        )
    }
}

/// An accessory application has no menu bar, so the usual editing shortcuts
/// never reach the web view and a sign-in form cannot be pasted into. Routing
/// the standard selectors through the responder chain restores them without
/// installing an application-wide menu.
final class WebMusicWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    var onReload: (() -> Void)?
    var onGoBack: (() -> Void)?
    var onGoForward: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command || flags == [.command, .shift] else {
            return super.performKeyEquivalent(with: event)
        }

        // String selectors rather than `#selector`: the editing actions are
        // resolved on whatever the web view puts in the responder chain, and
        // `NSObject.copy()` would otherwise shadow `copy:`.
        let action: String?
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": action = "selectAll:"
        case "c": action = "copy:"
        case "v": action = "paste:"
        case "x": action = "cut:"
        case "z": action = flags.contains(.shift) ? "redo:" : "undo:"
        case "r": onReload?(); return true
        case "[": onGoBack?(); return true
        case "]": onGoForward?(); return true
        case "w": performClose(self); return true
        default: action = nil
        }

        if let action, NSApp.sendAction(Selector((action)), to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// What `MediaController` needs from a web player, kept separate from
/// `WebMusicPlayer`'s WebKit machinery so a test can drive the exact same
/// state-adoption path `MediaController` runs in production without ever
/// building a `WKWebView` — construction that alone would touch the network
/// boundary CI's `lsof` check exists to catch.
@MainActor
protocol WebMusicPlaying: AnyObject {
    var onState: ((MusicSource, WebMusicState?) -> Void)? { get set }
    var onArtwork: ((MusicSource, String, NSImage?) -> Void)? { get set }
    var onLoading: ((MusicSource, Bool) -> Void)? { get set }
    var onFailure: ((MusicSource, String) -> Void)? { get set }
    var source: MusicSource? { get }
    var currentState: WebMusicState? { get }

    func show(source: MusicSource)
    func command(_ command: WebMusicCommand)
    func seek(to seconds: TimeInterval)
    func requestSnapshot()
    func deactivate()
    func teardown()
}

/// What `show(source:)` should do with the web view it already has.
///
/// Extracted because the choice is the interesting part and the alternative —
/// asserting on a real `WKWebView` — cannot be made without loading a provider
/// page over the network. `show(source:)` calls exactly this, so a test of it
/// is a test of the production decision rather than a second algorithm written
/// to agree with it.
///
/// Deliberately **not** actor-isolated: it is a pure value describing a
/// decision, with no state and nothing to protect. Isolating it would say
/// something untrue about it — and, when this enum was first added, an
/// `@MainActor` written here is exactly what silently took that isolation away
/// from the class below.
enum WebPlayerShowAction: Equatable {
    /// The page is healthy and already showing this provider: ask it to speak.
    case snapshot
    /// Navigate to the provider's home page.
    case load
    /// One explicit reload of a page whose content process died. Allowed only
    /// because the user asked for it by opening or retrying.
    case recoveryReload
}

/// Owns a user-opened web player. Merely creating `MediaController` or choosing
/// a source never constructs a WKWebView and therefore never starts networking.
/// The first request is made only by `show(source:)`, which is wired to the
/// explicit "Open web player" button in the Music pane.
///
/// `@MainActor` belongs on the **class**, not merely on `WebMusicPlaying`.
/// Conforming to a main-actor protocol isolates the protocol's own
/// requirements; it says nothing about the concrete state this object owns —
/// the `WKWebView`, the window controller, the popup table, `currentState`,
/// `source`, `requestedArtworkKey`, `playbackIntent`, `needsRecoveryLoad`, the
/// navigation callbacks, JS evaluation and teardown. All of that is AppKit and
/// WebKit state that must stay on the main actor, so the isolation is declared
/// where the state lives.
@MainActor
final class WebMusicPlayer: NSObject, WKNavigationDelegate, WKUIDelegate, WebMusicPlaying {
    var onState: ((MusicSource, WebMusicState?) -> Void)?
    var onArtwork: ((MusicSource, String, NSImage?) -> Void)?
    var onLoading: ((MusicSource, Bool) -> Void)?
    var onFailure: ((MusicSource, String) -> Void)?

    private(set) var source: MusicSource?
    private(set) var currentState: WebMusicState?

    private var webView: WKWebView?
    /// Whether a web view is currently held. Opening one is a user action, so
    /// the shutdown path is checked for the absence of one rather than by
    /// driving a real page load.
    var hasWebView: Bool { webView != nil }
    private var windowController: NSWindowController?
    private var messageProxy: WeakScriptMessageHandler?
    private var popups: [ObjectIdentifier: NSWindowController] = [:]
    private var requestedArtworkKey: String?
    private var isPresentingFailure = false
    /// Identifies the most recent play/pause press, so a stale follow-up check
    /// cannot act on an intent the user has already replaced.
    private var playbackIntent = 0
    /// Set when the content process died: the view still holds a provider URL,
    /// but the document behind it — and the injected bridge with it — is gone.
    /// Without this the next `show(source:)` would see a same-source,
    /// still-allowlisted URL, ask a dead page for a snapshot, and wait forever.
    private var needsRecoveryLoad = false

    func show(source: MusicSource) {
        guard let homeURL = source.webHomeURL else { return }
        let webView = webView ?? makeWebView()
        let sourceChanged = self.source != source
        self.source = source
        currentState = nil
        requestedArtworkKey = nil
        onState?(source, nil)

        let windowController = windowController ?? makeWindowController(webView: webView)
        windowController.window?.title = "Impuls — \(source.displayName)"
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // A load already in flight is left to finish — unless the page behind
        // it is the dead one, which finishes nothing.
        if !sourceChanged, !needsRecoveryLoad, webView.isLoading { return }

        let action = Self.showAction(
            sourceChanged: sourceChanged,
            currentURL: webView.url,
            source: source,
            needsRecovery: needsRecoveryLoad
        )
        // Cleared before navigating, not after: whichever branch runs, this
        // page has now had its one explicit recovery. A second crash raises the
        // flag again and gives the user another Retry — which is a cycle only
        // if the user keeps choosing it.
        needsRecoveryLoad = false

        switch action {
        case .snapshot:
            requestSnapshot()
        case .load:
            onLoading?(source, true)
            webView.load(URLRequest(url: homeURL))
        case .recoveryReload:
            onLoading?(source, true)
            webView.reload()
        }
    }

    /// Test seam: whether a recovery navigation is still owed. Read-only, so a
    /// test can observe the flag's lifecycle without being able to forge it.
    var needsRecoveryLoadForTesting: Bool { needsRecoveryLoad }

    /// The rule `show(source:)` follows, in one testable place.
    ///
    /// A source change always loads: the recovery flag belongs to the dead
    /// page, not to whatever the user asks for next, so switching services
    /// after a crash is an ordinary load of the new one.
    static func showAction(
        sourceChanged: Bool,
        currentURL: URL?,
        source: MusicSource,
        needsRecovery: Bool
    ) -> WebPlayerShowAction {
        if sourceChanged { return .load }
        let showsThisProvider = currentURL.map { source.allowsStateReport(from: $0) } == true
        if needsRecovery { return showsThisProvider ? .recoveryReload : .load }
        return showsThisProvider ? .snapshot : .load
    }

    /// Test seam: reaches the state a running session has — a web view and a
    /// selected source — **without loading a page**, so the lifecycle tests
    /// never touch the network or a provider's servers.
    ///
    /// Production gets here through `show(source:)`, which does the same and
    /// then loads. Kept internal for the same reason `hasWebView` and
    /// `bridgeScript` are: the alternative is a test that proves nothing about
    /// the real object.
    @discardableResult
    func prepareWithoutLoading(source: MusicSource) -> WKWebView {
        self.source = source
        return webView ?? makeWebView()
    }

    func command(_ command: WebMusicCommand) {
        guard command == .playPause else {
            evaluate("window.__impulsMusicBridge?.command('\(command.rawValue)')")
            return
        }
        togglePlayback()
    }

    /// Play/pause is the one command that needs to know the current state, and
    /// guessing it from the page was what kept getting it wrong. WebKit knows
    /// the answer — it is the same state it publishes to the system's own Now
    /// Playing controls — so the intent is decided here and handed to the page
    /// rather than inferred inside it.
    private func togglePlayback() {
        guard let webView else { return }
        // Each press supersedes the one before it. Without this, the delayed
        // check below belongs to a press the user has already changed their
        // mind about, and a quick pause-then-play would be pausing again a
        // moment after it started.
        playbackIntent &+= 1
        let intent = playbackIntent

        webView.requestMediaPlaybackState { [weak self] state in
            guard let self, self.playbackIntent == intent else { return }
            let shouldPlay = state != .playing
            self.reportKnownState(state)
            self.evaluate("window.__impulsMusicBridge?.setPlaying(\(shouldPlay))")

            // If the page ignored it, stop the audio the way the system
            // transport does. There is no public counterpart for starting it
            // again, so resuming stays with the page's own media element.
            guard !shouldPlay else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self, weak webView] in
                guard let self, let webView, self.playbackIntent == intent else { return }
                webView.requestMediaPlaybackState { [weak self] current in
                    guard let self, self.playbackIntent == intent, current == .playing else { return }
                    NSLog("Impuls: web music page ignored pause, stopping media directly")
                    webView.pauseAllMediaPlayback(completionHandler: nil)
                }
            }
        }
    }

    /// Hands WebKit's own view of playback to the page bridge, which trusts it
    /// above anything it can observe itself.
    private func reportKnownState(_ state: WKMediaPlaybackState) {
        let token: String
        switch state {
        case .playing: token = "playing"
        case .paused, .suspended: token = "paused"
        default: token = "none"
        }
        evaluate("window.__impulsMusicBridge?.setKnownState('\(token)')")
    }

    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        evaluate("window.__impulsMusicBridge?.seek(\(max(0, seconds)))")
    }

    func requestSnapshot() {
        webView?.requestMediaPlaybackState { [weak self] state in
            self?.reportKnownState(state)
        }
        evaluate("window.__impulsMusicBridge?.push()")
    }

    func reload() {
        guard let webView, let source else { return }
        if let url = webView.url, source.allowsStateReport(from: url) {
            webView.reload()
        } else if let homeURL = source.webHomeURL {
            webView.load(URLRequest(url: homeURL))
        }
    }

    func deactivate() {
        evaluate("window.__impulsMusicBridge?.pause()")
        windowController?.window?.orderOut(nil)
        currentState = nil
        requestedArtworkKey = nil
    }

    /// Releases the web view and everything it keeps running.
    ///
    /// The injected bridge installs `setInterval(..., 1000)` and a
    /// `MutationObserver`, and nothing used to stop them: `deactivate` only
    /// ordered the window out, and `MediaController.stop()` did not reach here
    /// at all. So the page kept pushing state once a second — with the panel
    /// folded, and past `NotchController.teardown()` — until the process exited.
    ///
    /// Idempotent, and it leaves the object usable. `show(source:)` builds the
    /// web view through `webView ?? makeWebView()`, so the next explicit user
    /// action reconstructs a working player. Nothing here creates a web view or
    /// loads a URL: opening one is the user's decision, and this is the path
    /// that runs at shutdown.
    func teardown() {
        for controller in popups.values {
            controller.window?.orderOut(nil)
            controller.window?.contentView = nil
        }
        popups.removeAll()

        if let webView {
            // Stops the pump at the source, then removes the only route the
            // page has back into the app. Order matters: the handler must
            // outlive the scripts that may still be mid-callback.
            webView.evaluateJavaScript("window.__impulsMusicBridge?.stop?.()") { _, _ in }
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            let controller = webView.configuration.userContentController
            controller.removeAllUserScripts()
            controller.removeScriptMessageHandler(forName: "impulsMusic")
        }

        windowController?.window?.orderOut(nil)
        windowController?.window?.contentView = nil
        windowController = nil
        messageProxy = nil
        webView = nil

        currentState = nil
        requestedArtworkKey = nil
        source = nil
        isPresentingFailure = false
        needsRecoveryLoad = false
        playbackIntent += 1
    }

    private func evaluate(_ source: String) {
        guard let webView, let selected = self.source,
              webView.url.map({ selected.allowsStateReport(from: $0) }) == true else { return }
        // Wrapped so the result is always `null`: WebKit reports an
        // unsupported-result error for anything it cannot bridge to an
        // Objective-C type, which made a perfectly successful call look failed.
        webView.evaluateJavaScript("(function(){ \(source); return null; })()") { _, error in
            if let error { NSLog("Impuls: web music command failed: \(error.localizedDescription)") }
        }
    }

    // MARK: - Web view

    /// WebKit's default product token stops at `AppleWebKit/605.1.15`, and every
    /// one of these services treats a client without the Safari token as an
    /// unsupported browser — which is exactly why the window came up blank.
    /// The engine version stays real; only the Safari token is appended, read
    /// from the copy of Safari installed on this Mac.
    static let safariUserAgentToken: String = {
        let allowed = CharacterSet(charactersIn: "0123456789.")
        let installed = (Bundle(path: "/Applications/Safari.app")?
            .infoDictionary?["CFBundleShortVersionString"] as? String)
            .map { String($0.prefix(8)) }
            .flatMap { candidate -> String? in
                guard !candidate.isEmpty,
                      candidate.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
                return candidate
            }
        return "Version/\(installed ?? "18.5") Safari/605.1.15"
    }()

    private func makeConfiguration() -> WKWebViewConfiguration {
        let controller = WKUserContentController()
        let proxy = WeakScriptMessageHandler(owner: self)
        messageProxy = proxy
        controller.add(proxy, name: "impulsMusic")
        // Page console output can contain anything the site chose to print, so
        // forwarding it is a debugging aid the user turns on, not a default.
        // The bridge's own status lines carry no page content and stay on.
        if UserDefaults.standard.bool(forKey: Self.inspectorDefaultsKey) {
            controller.addUserScript(WKUserScript(
                source: "window.__impulsMusicVerbose = true;",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }

        // Document start, not end: the bridge has to wrap
        // `navigator.mediaSession.setActionHandler` before the page installs
        // its own handlers, otherwise the transport route that actually works
        // is already registered by the time Impuls can see it.
        controller.addUserScript(WKUserScript(
            source: Self.bridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = Self.safariUserAgentToken
        configuration.preferences.isElementFullscreenEnabled = true
        // The panel's play button is the user action. Without this, WebKit
        // refuses the resulting `play()` and the transport silently does nothing.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        return configuration
    }

    /// Opt-in, off by default:
    /// `defaults write io.tumanov.impuls music.webInspector -bool YES`.
    /// The web view holds a signed-in provider session, so Safari's inspector
    /// is not something to leave attachable without the user asking for it.
    static let inspectorDefaultsKey = "music.webInspector"

    private func makeWebView() -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: makeConfiguration())
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = true
        if UserDefaults.standard.bool(forKey: Self.inspectorDefaultsKey) {
            webView.isInspectable = true
            NSLog("Impuls: web music inspector enabled")
        }
        NSLog("Impuls: web music user agent \(Self.safariUserAgentToken)")
        // A new view has no dead page behind it.
        needsRecoveryLoad = false
        self.webView = webView
        return webView
    }

    private func makeWindowController(webView: WKWebView) -> NSWindowController {
        let window = WebMusicWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.minSize = NSSize(width: 760, height: 520)
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Impuls.WebMusicPlayer")
        window.onReload = { [weak self] in self?.reload() }
        window.onGoBack = { [weak webView] in webView?.goBack() }
        window.onGoForward = { [weak webView] in webView?.goForward() }
        let controller = NSWindowController(window: window)
        windowController = controller
        return controller
    }

    // MARK: - Navigation boundary

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, let source else {
            decisionHandler(.cancel)
            return
        }

        // A subframe cannot talk to the Impuls message handler, and captcha,
        // consent and sign-in widgets legitimately live on other hosts.
        if navigationAction.targetFrame?.isMainFrame == false {
            let allowed = MusicSource.allowsSubframeNavigation(to: url)
            if !allowed { logCancelled(url, frame: "subframe") }
            decisionHandler(allowed ? .allow : .cancel)
            return
        }

        if source.allowsMainFrameNavigation(to: url) {
            decisionHandler(.allow)
            return
        }
        logCancelled(url, frame: "main frame")
        if navigationAction.navigationType == .linkActivated,
           ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    /// A cancelled navigation is the first thing to look at when a provider
    /// page will not finish starting, so it is logged with its host rather than
    /// disappearing silently. Only the scheme and host are recorded: a query
    /// string on an authentication URL can carry a token.
    private func logCancelled(_ url: URL, frame: String) {
        NSLog("Impuls: web music blocked \(frame) navigation to \(url.scheme ?? "?")://\(url.host ?? "?")")
    }

    /// Yandex ID and Google both sign in through a real popup. Returning nil
    /// used to strand the user on a dead button; the popup now opens with the
    /// same configuration so the session cookie lands in the same store.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let source else { return nil }
        if let url = navigationAction.request.url,
           !source.allowsMainFrameNavigation(to: url) {
            if ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self

        let width = windowFeatures.width?.doubleValue ?? 620
        let height = windowFeatures.height?.doubleValue ?? 720
        let window = WebMusicWindow(
            contentRect: NSRect(x: 0, y: 0, width: max(420, width), height: max(420, height)),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = popup
        window.title = "Impuls — \(source.displayName)"
        window.center()
        window.isReleasedWhenClosed = false
        let controller = NSWindowController(window: window)
        popups[ObjectIdentifier(popup)] = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        closePopup(for: webView)
    }

    private func closePopup(for webView: WKWebView) {
        guard let controller = popups.removeValue(forKey: ObjectIdentifier(webView)) else { return }
        controller.window?.orderOut(nil)
        controller.window?.contentView = nil
    }

    private func isPopup(_ webView: WKWebView) -> Bool {
        popups[ObjectIdentifier(webView)] != nil
    }

    // MARK: - Dialogs

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        present(message: message, buttons: [localized("OK")]) { _ in
            completionHandler()
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        present(message: message, buttons: [localized("OK"), localized("Cancel")]) { index in
            completionHandler(index == 0)
        }
    }

    private func present(
        message: String,
        buttons: [String],
        completion: @escaping (Int) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Impuls"
        alert.informativeText = String(message.prefix(2_048))
        buttons.forEach { alert.addButton(withTitle: $0) }
        let response = alert.runModal()
        completion(response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
    }

    // MARK: - Navigation events

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let source, !isPopup(webView), !isPresentingFailure else { return }
        onLoading?(source, true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let source, !isPopup(webView) else { return }
        if isPresentingFailure {
            isPresentingFailure = false
            return
        }
        onLoading?(source, false)
        requestSnapshot()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        navigationFailed(error, in: webView)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        navigationFailed(error, in: webView)
    }

    /// The web content process died — a crash, or the system reclaiming it
    /// under memory pressure. Routine with a heavy single-page app.
    ///
    /// Nothing else reports this. Without it the view goes blank while the last
    /// adopted track stays on screen, with transport buttons that silently do
    /// nothing: the JS pump died with the process, so no later push corrects
    /// the picture and only an explicit reload recovers. Clearing here is what
    /// turns a dead player into an honest one.
    ///
    /// Deliberately **no automatic reload**. A page that crashes once tends to
    /// crash again, and reloading from the callback that reports the crash is
    /// how a retry storm is built. The user's next explicit Open or Reload
    /// rebuilds it through the ordinary path — `show(source:)` still finds a
    /// usable web view, and WebKit spawns a fresh process for it.
    ///
    /// No timer, no task, no network: this method only reports.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Identity, not just presence. After `teardown()` the view this object
        // owns is `nil`, and a popup's process dying is not the player's
        // business — in neither case may a late callback clear live state.
        guard let current = self.webView, current === webView, !isPopup(webView) else { return }
        guard let source else { return }

        NSLog("Impuls: web music content process terminated")
        currentState = nil
        requestedArtworkKey = nil
        // The view keeps its URL, so the next `show(source:)` would otherwise
        // mistake this for a healthy page. Raising the flag is all that happens
        // here — nothing is loaded from the callback that reports the crash.
        needsRecoveryLoad = true
        // Any press in flight belonged to a page that no longer exists.
        playbackIntent += 1

        onLoading?(source, false)
        // Clearing the state is what resets the transport capabilities: they
        // travel with it through the same pipeline rather than being cleared
        // by a second, separate path that could disagree with it.
        onState?(source, nil)
        onFailure?(source, Self.processTerminatedMessage)
    }

    /// Fixed and localized, carrying nothing from the page. The failure channel
    /// is user-visible, and a crash tells us nothing about the site worth
    /// repeating into it.
    static var processTerminatedMessage: String {
        localized("The web player stopped unexpectedly. Reload to continue.")
    }

    private func navigationFailed(_ error: Error, in webView: WKWebView) {
        guard let source, !isPopup(webView) else { return }
        // A cancelled load is the ordinary result of a redirect, and WebKit's
        // "frame load interrupted" is what the boundary above produces every
        // time it hands a link to the browser. Neither is a failure.
        let failure = error as NSError
        let interruptedByPolicy = failure.domain == "WebKitErrorDomain" && failure.code == 102
        guard failure.code != NSURLErrorCancelled, !interruptedByPolicy else { return }
        NSLog("Impuls: web music navigation failed: \(error.localizedDescription)")
        onLoading?(source, false)
        onState?(source, nil)
        onFailure?(source, error.localizedDescription)
        isPresentingFailure = true
        webView.loadHTMLString(
            Self.failureHTML(source: source, message: error.localizedDescription),
            baseURL: nil
        )
    }

    private static func failureHTML(source: MusicSource, message: String) -> String {
        func escape(_ value: String) -> String {
            value
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <!doctype html><meta charset="utf-8">
        <style>
        :root { color-scheme: light dark; }
        body { margin:0; height:100vh; display:flex; align-items:center; justify-content:center;
               font:400 14px/1.5 -apple-system, system-ui, sans-serif;
               background:Canvas; color:CanvasText; }
        div { max-width:34em; text-align:center; padding:2em; }
        h1 { font-size:16px; margin:0 0 .5em; }
        p { margin:0; opacity:.7; }
        </style>
        <div><h1>\(escape(source.displayName))</h1><p>\(escape(String(message.prefix(400))))</p></div>
        """
    }

    // MARK: - Bridge messages

    static func acceptsBridgeMessage(
        source: MusicSource,
        mainPageURL: URL?,
        isMainFrame: Bool
    ) -> Bool {
        guard isMainFrame, let mainPageURL else { return false }
        return source.allowsStateReport(from: mainPageURL)
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.name == "impulsMusic",
              let source,
              let webView = message.webView,
              !isPopup(webView),
              Self.acceptsBridgeMessage(
                  source: source,
                  mainPageURL: webView.url,
                  isMainFrame: message.frameInfo.isMainFrame
              ) else { return }

        if let diagnostic = WebMusicDiagnostic.decode(message.body) {
            NSLog("Impuls: web music page \(diagnostic.level): \(diagnostic.message)")
            return
        }

        if let artwork = WebMusicArtwork.decode(message.body, source: source) {
            guard artwork.key == currentState?.artworkKey else { return }
            let image = PlayerBridge.thumbnailArtwork(from: artwork.data)
            onArtwork?(source, artwork.key, image)
            return
        }

        let state = WebMusicState.decode(message.body, source: source)
        currentState = state
        onState?(source, state)

        guard let state, !state.artworkKey.isEmpty else {
            requestedArtworkKey = nil
            return
        }
        guard requestedArtworkKey != state.artworkKey else { return }
        requestedArtworkKey = state.artworkKey
        evaluate("window.__impulsMusicBridge?.artwork()")
    }

    /// Internal so the test suite can compile the complete embedded program
    /// with JavaScriptCore. Swift treats it as an ordinary string and cannot
    /// otherwise catch a JavaScript syntax error before WebKit injection.
    static let bridgeScript = #"""
    (() => {
      if (window.__impulsMusicBridge) return;

      const VERSION = 2;
      const MAX_TEXT = 512;
      const MAX_ARTWORK_CHARS = 6 * 1024 * 1024;
      const MAX_ARTWORK_BYTES = 4 * 1024 * 1024;

      const host = location.hostname.toLowerCase();
      const under = suffix => host === suffix || host.endsWith('.' + suffix);
      const site = under('youtube.com') ? 'youtube'
        : (['yandex.ru','yandex.com','yandex.by','yandex.kz','yandex.com.tr','ya.ru'].some(under)) ? 'yandex'
        : (under('vk.com') || under('vk.ru')) ? 'vk'
        : 'generic';

      const PACKS = {
        youtube: {
          title: ['.ytmusic-player-bar yt-formatted-string.title', 'ytmusic-player-bar .title'],
          artist: ['.ytmusic-player-bar yt-formatted-string.byline', 'ytmusic-player-bar .byline'],
          cover: ['ytmusic-player-bar img.image', '#song-image img', 'ytmusic-player-bar img'],
          clock: ['.ytmusic-player-bar .time-info'],
          playPause: ['#play-pause-button'],
          next: ['.next-button.ytmusic-player-bar', 'ytmusic-player-bar .next-button'],
          previous: ['.previous-button.ytmusic-player-bar', 'ytmusic-player-bar .previous-button']
        },
        yandex: {
          title: ['[data-test-id="TRACK_TITLE"]', '[class*="Meta_title"]', '.track__title'],
          artist: ['[data-test-id="SEPARATED_ARTIST_TITLE"]', '[data-test-id="TRACK_ARTIST"]',
                   '[class*="Meta_artistCaption"]', '.track__artists'],
          cover: ['[data-test-id="ENTITY_COVER_IMAGE"]', '[class*="PlayerBar"] img',
                  '.player-controls img', '.entity-cover__image'],
          clock: ['[data-test-id="TIMECODE_TIME_START"]'],
          playPause: ['[data-test-id="PLAY_BUTTON"]', '[data-test-id="PAUSE_BUTTON"]',
                      '[data-test-id="TOGGLE_PLAY_BUTTON"]', '[class*="SonataControls"] [class*="Play"]',
                      '.player-controls__btn_play'],
          next: ['[data-test-id="NEXT_TRACK_BUTTON"]', '.player-controls__btn_next'],
          previous: ['[data-test-id="PREV_TRACK_BUTTON"]', '[data-test-id="PREVIOUS_TRACK_BUTTON"]',
                     '.player-controls__btn_prev']
        },
        vk: {
          title: ['.audio_page_player_title_song', '.top_audio_player_title_song',
                  '[class*="AudioPlayerBlock__title"]'],
          artist: ['.audio_page_player_title_performer', '.top_audio_player_title_performer',
                   '[class*="AudioPlayerBlock__performer"]'],
          cover: ['.audio_page_player_cover_img', '[class*="AudioPlayerBlock"] img'],
          clock: [],
          playPause: ['.audio_page_player_play', '.top_audio_player_play',
                      '[class*="AudioPlayerBlock__play"]'],
          next: ['.audio_page_player_next', '.top_audio_player_next'],
          previous: ['.audio_page_player_prev', '.top_audio_player_prev']
        },
        generic: { title: [], artist: [], cover: [], clock: [], playPause: [], next: [], previous: [] }
      };
      const pack = PACKS[site];

      const tidy = value => typeof value === 'string' ? value.trim().slice(0, MAX_TEXT) : '';
      const post = payload => {
        try { window.webkit.messageHandlers.impulsMusic.postMessage(payload); } catch (_) {}
      };

      // A provider that will not respond to a transport button says why in its
      // console. Forwarding a bounded number of those lines is the difference
      // between diagnosing that and guessing at it.
      let reports = 0;
      const report = (level, text) => {
        if (reports >= 40) return;
        reports += 1;
        post({
          version: VERSION,
          kind: 'diagnostic',
          page: location.href,
          level: String(level).slice(0, 32),
          message: String(text).slice(0, 512)
        });
      };

      // The transport route that actually works everywhere. Every one of these
      // services registers Media Session handlers — that is how the keyboard's
      // own media keys drive them — so recording those handlers as the page
      // installs them lets Impuls call the site's own code instead of hunting
      // for a button whose class name changes with every redesign.
      const handlers = Object.create(null);
      try {
        const session = navigator.mediaSession;
        if (session && typeof session.setActionHandler === 'function') {
          const original = session.setActionHandler.bind(session);
          session.setActionHandler = (action, handler) => {
            if (handler) handlers[action] = handler;
            else delete handlers[action];
            return original(action, handler);
          };
        }
      } catch (_) {}
      const invoke = (action, details) => {
        const handler = handlers[action];
        if (!handler) return false;
        try { handler(details || { action: action }); return true; } catch (_) { return false; }
      };

      const visible = element => {
        if (!element) return false;
        const rect = element.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0) return false;
        const style = getComputedStyle(element);
        return style.visibility !== 'hidden' && style.display !== 'none';
      };
      const pick = selectors => {
        for (const selector of selectors) {
          const element = document.querySelector(selector);
          if (element) return element;
        }
        return null;
      };
      const label = selectors => {
        const element = pick(selectors);
        if (!element) return '';
        return tidy(element.getAttribute('title') || element.textContent
          || element.getAttribute('aria-label'));
      };

      // Several of these players never put their audio element in the document
      // — a bare `new Audio()` is enough to play a track, and nothing in the
      // DOM ever references it. No query can find that element, which is why
      // the bridge reported no media while the system's own controls worked.
      // Recording every element the page actually drives closes that hole, and
      // it only works because this script runs before the page does.
      const created = new Set();
      let activeMedia = null;
      try {
        for (const name of ['play', 'load']) {
          const original = HTMLMediaElement.prototype[name];
          if (typeof original !== 'function') continue;
          HTMLMediaElement.prototype[name] = function (...args) {
            created.add(this);
            // A player that prefetches the next track has more than one element
            // in flight. The one it last asked to play is the current track.
            if (name === 'play') activeMedia = this;
            return original.apply(this, args);
          };
        }
      } catch (_) {}

      // WebKit's own answer, pushed in from the application. It outranks
      // everything observable from here, being the same state the system
      // transport acts on.
      let knownState = 'none';
      let knownStateAt = 0;
      const setKnownState = token => {
        knownState = token;
        knownStateAt = Date.now();
      };

      // The media element is cached: rescanning shadow roots on every push is
      // far too expensive on a Polymer app like YouTube Music.
      let cachedMedia = null;
      const scanShadow = () => {
        const found = [];
        let budget = 4000;
        const walk = root => {
          if (budget <= 0) return;
          let elements;
          try { elements = root.querySelectorAll('*'); } catch (_) { return; }
          for (const element of elements) {
            if (budget-- <= 0) return;
            const shadow = element.shadowRoot;
            if (!shadow) continue;
            found.push(...shadow.querySelectorAll('audio, video'));
            walk(shadow);
          }
        };
        walk(document);
        return found;
      };
      const choose = list => list.find(element => !element.paused && !element.ended)
        || list.find(element => Number.isFinite(element.duration) && element.duration > 0)
        || list[0] || null;
      const media = () => {
        if (activeMedia) return activeMedia;
        if (cachedMedia && (cachedMedia.isConnected || created.has(cachedMedia))) return cachedMedia;
        cachedMedia = choose([...created])
          || choose([...document.querySelectorAll('audio, video')])
          || choose(scanShadow());
        return cachedMedia;
      };

      const metadata = () => {
        try { return navigator.mediaSession?.metadata || null; } catch (_) { return null; }
      };
      const playbackState = () => {
        try { return navigator.mediaSession?.playbackState || 'none'; } catch (_) { return 'none'; }
      };

      // "1:07 / 3:42" is the last resort when the element reports no duration,
      // which is what MSE-backed players do before the first buffer settles.
      const clockSeconds = text => {
        const parts = String(text).trim().split(':').map(Number);
        if (!parts.length || parts.some(part => !Number.isFinite(part))) return 0;
        return parts.reduce((total, part) => total * 60 + part, 0);
      };
      const clock = () => {
        const element = pick(pack.clock);
        if (!element) return null;
        const matched = tidy(element.textContent).match(/(\d+:\d{2}(?::\d{2})?)\s*\/\s*(\d+:\d{2}(?::\d{2})?)/);
        if (!matched) return null;
        return { position: clockSeconds(matched[1]), duration: clockSeconds(matched[2]) };
      };

      const coverURL = () => {
        const artwork = metadata()?.artwork || [];
        let best = '';
        let bestArea = -1;
        for (const entry of artwork) {
          const size = String(entry.sizes || '').split('x').map(Number);
          const area = Number.isFinite(size[0]) ? size[0] * (size[1] || size[0]) : 0;
          if (area > bestArea && typeof entry.src === 'string') { best = entry.src; bestArea = area; }
        }
        if (!best) {
          const image = pick(pack.cover);
          best = image?.currentSrc || image?.src || '';
        }
        try { return best ? new URL(best, location.href).href : ''; } catch (_) { return ''; }
      };

      const fallbackTitle = () => tidy(document.title)
        .replace(/^\(\d+\)\s*/, '')
        .replace(/\s+[—|·-]\s+(Яндекс Музыка|Yandex Music|YouTube Music|VK Музыка|ВКонтакте).*$/i, '');

      const snapshot = () => {
        const element = media();
        const meta = metadata();
        const readout = clock();
        const duration = Number.isFinite(element?.duration) && element.duration > 0
          ? element.duration
          : (readout?.duration || 0);
        const position = Number.isFinite(element?.currentTime) && element.currentTime > 0
          ? element.currentTime
          : (readout?.position || 0);
        noteProgress(position);
        return {
          version: VERSION,
          kind: 'state',
          page: location.href,
          title: tidy(meta?.title) || label(pack.title) || (element ? fallbackTitle() : ''),
          artist: tidy(meta?.artist) || label(pack.artist),
          album: tidy(meta?.album),
          duration: duration,
          position: position,
          playing: isPlaying(),
          artworkKey: coverURL(),
          // Honest capability, not an assumption: the same route lookup that
          // would carry the actual command. Play/pause has a further element
          // fallback in `drive()`, so any loaded media counts.
          canNext: hasRoute('next', 'nexttrack'),
          canPrevious: hasRoute('previous', 'previoustrack'),
          canPlayPause: Boolean(handlers.play || handlers.pause) || findKnown('playPause') !== null || Boolean(element),
          canSeek: Boolean(handlers.seekto) || (Number.isFinite(element?.duration) && element.duration > 0)
        };
      };

      let lastSignature = '';
      let lastSentAt = 0;
      // Set by `stop()` when Impuls is releasing the web view. The event
      // listeners and the MutationObserver outlive the timers, so they need a
      // way to fall silent too.
      let stopped = false;
      const push = force => {
        if (stopped) return;
        const payload = snapshot();
        const signature = [payload.title, payload.artist, payload.album, payload.playing,
                           Math.round(payload.duration), payload.artworkKey,
                           payload.canNext, payload.canPrevious, payload.canPlayPause, payload.canSeek]
          .join('|');
        const now = Date.now();
        if (!force && signature === lastSignature && now - lastSentAt < 900) return;
        lastSignature = signature;
        lastSentAt = now;
        post(payload);
      };

      const fetchArtwork = async () => {
        const url = coverURL();
        if (!url || !url.startsWith('https:')) return;
        try {
          const response = await fetch(url, { credentials: 'omit' });
          if (!response.ok) return;
          if (!/^image\//i.test(response.headers.get('content-type') || '')) return;
          const blob = await response.blob();
          if (!blob.size || blob.size > MAX_ARTWORK_BYTES) return;
          const encoded = await new Promise(resolve => {
            const reader = new FileReader();
            reader.onload = () => resolve(String(reader.result || '').split(',')[1] || '');
            reader.onerror = () => resolve('');
            reader.readAsDataURL(blob);
          });
          if (!encoded || encoded.length > MAX_ARTWORK_CHARS) return;
          post({ version: VERSION, kind: 'artwork', page: location.href, key: url, data: encoded });
        } catch (_) {}
      };

      const LABELS = {
        playPause: /воспроизвести|воспроизведение|пауза|приостановить|play|pause/i,
        next: /следующ|вперёд|вперед|next/i,
        previous: /предыдущ|назад|previous|back/i
      };
      // Every one of these services puts its transport in a bar pinned to the
      // bottom of the window. Preferring that strip keeps a label match from
      // landing on the play button of some track row half a page up.
      const inTransportBar = element => {
        const rect = element.getBoundingClientRect();
        return rect.bottom > innerHeight - 140 && rect.top < innerHeight;
      };
      // Finds the element `clickKnown` would press, without pressing it. This
      // is also the honest signal behind `canNext`/`canPrevious`/`canPlayPause`
      // in the state snapshot: the same lookup that decides whether a command
      // can act decides whether the button should look enabled, so the two can
      // never disagree.
      const findKnown = action => {
        for (const selector of pack[action] || []) {
          const candidates = [...document.querySelectorAll(selector)].filter(visible);
          const button = candidates.find(inTransportBar) || candidates[0];
          if (button) return button;
        }
        const pattern = LABELS[action];
        const labelled = [...document.querySelectorAll('button, [role="button"]')].filter(element => {
          const text = `${element.getAttribute('aria-label') || ''} ${element.getAttribute('title') || ''}`;
          return visible(element) && pattern?.test(text);
        });
        return labelled.find(inTransportBar) || labelled[0] || null;
      };
      const clickKnown = action => {
        const button = findKnown(action);
        if (button) { button.click(); return true; }
        return false;
      };
      const hasRoute = (action, mediaSessionAction) => {
        if (mediaSessionAction && handlers[mediaSessionAction]) return true;
        return findKnown(action) !== null;
      };

      // Whether the page is playing has to survive a player that exposes no
      // media element and never sets playbackState — Yandex Music is both. The
      // last resort is the only universally true signal: the position moved.
      let lastPosition = -1;
      let advancedAt = 0;
      const noteProgress = position => {
        // The first sample has nothing to compare against; counting it as
        // progress would report a paused player at 0:00 as playing.
        if (lastPosition >= 0 && position > lastPosition + 0.2) advancedAt = Date.now();
        lastPosition = position;
      };

      // A transport button relabels itself: "Пауза" while playing, "Слушать"
      // while stopped. That is a state the page maintains for its own use, so
      // it stays right even when nothing else here does.
      const PLAYING_LABEL = /пауза|приостанов|pause/i;
      const PAUSED_LABEL = /воспроизв|слушать|play/i;
      const buttonSaysPlaying = () => {
        for (const selector of pack.playPause || []) {
          const button = [...document.querySelectorAll(selector)]
            .filter(visible)
            .find(inTransportBar);
          if (!button) continue;
          const text = `${button.getAttribute('aria-label') || ''} ${button.getAttribute('title') || ''}`;
          if (PLAYING_LABEL.test(text)) return true;
          if (PAUSED_LABEL.test(text)) return false;
        }
        return null;
      };

      const isPlaying = () => {
        if (knownState !== 'none' && Date.now() - knownStateAt < 2500) {
          return knownState === 'playing';
        }
        const element = media();
        if (element && (element.currentTime > 0 || element.readyState > 0)) {
          return !element.paused && !element.ended;
        }
        const state = playbackState();
        if (state === 'playing') return true;
        if (state === 'paused') return false;
        const labelled = buttonSaysPlaying();
        if (labelled !== null) return labelled;
        return Date.now() - advancedAt < 2500;
      };

      // For play/pause the site's own button comes first: it is a toggle, so it
      // carries the state and Impuls never has to guess which half to call.
      // For next and previous there is nothing to guess, so Media Session —
      // the same route the keyboard's media keys use — leads.
      // The application decides play versus pause and says so; nothing here
      // has to infer it. Media Session leads because it is the page's own code
      // and keeps the site's transport UI in step.
      const drive = (element, shouldPlay) => {
        if (!element) return false;
        try {
          if (shouldPlay) { const result = element.play(); if (result) result.catch(() => {}); }
          else element.pause();
          return true;
        } catch (_) { return false; }
      };

      let lastOutcome = '';
      const setPlaying = shouldPlay => {
        const route = invoke(shouldPlay ? 'play' : 'pause') ? 'mediaSession'
          : clickKnown('playPause') ? 'button'
          : '';
        setKnownState(shouldPlay ? 'playing' : 'paused');

        // Whatever was tried, check that it landed. A site with no Media
        // Session handlers whose transport button ignores a synthetic click —
        // Yandex Music is exactly that — leaves the element as the only route
        // that works, and it is the same one the system's controls use.
        setTimeout(() => {
          const element = media();
          let outcome;
          if (element && element.paused === shouldPlay) {
            const applied = drive(element, shouldPlay);
            outcome = `${route || 'no page route'} did not take, media element ${applied ? 'used' : 'unavailable'}`;
          } else {
            outcome = route || 'media element';
          }
          // Once per distinct outcome: a transport button is pressed often, and
          // the same line repeated is noise, not information.
          if (outcome !== lastOutcome) {
            lastOutcome = outcome;
            report('route', `playPause: ${outcome}`);
          }
          push(true);
        }, 220);
      };

      const command = action => {
        if (action === 'playPause') return setPlaying(!isPlaying());
        const done = invoke(action === 'next' ? 'nexttrack' : 'previoustrack')
          || clickKnown(action);
        if (!done) {
          report('command', `${action}: no route (media=${!!media()}, state=${playbackState()}, handlers=${Object.keys(handlers).join(',') || 'none'})`);
        }
        setTimeout(() => push(true), 150);
      };

      const seek = seconds => {
        if (!Number.isFinite(seconds)) return;
        const element = media();
        const maximum = element && Number.isFinite(element.duration) && element.duration > 0
          ? element.duration
          : seconds;
        const target = Math.max(0, Math.min(seconds, maximum));
        if (!invoke('seekto', { action: 'seekto', seekTime: target }) && element) {
          try { element.currentTime = target; } catch (_) {}
        }
        setTimeout(() => push(true), 100);
      };

      const pause = () => {
        if (isPlaying() && !invoke('pause') && !clickKnown('playPause')) {
          const element = media();
          if (element && !element.paused) element.pause();
        }
        setTimeout(() => push(true), 100);
      };

      // Only when the user asked for it. Everything below repeats what the page
      // printed, and a page may print anything.
      if (window.__impulsMusicVerbose) {
        window.addEventListener('error', event => {
          report('error', `${event.message} @ ${event.filename || '?'}:${event.lineno || 0}`);
        }, true);
        window.addEventListener('unhandledrejection', event => {
          const reason = event.reason;
          report('rejection', (reason && (reason.message || reason.name)) || reason);
        });
        const readable = value => {
          if (value instanceof Error) return `${value.name}: ${value.message}`;
          if (typeof value === 'object' && value !== null) {
            try { return JSON.stringify(value); } catch (_) { return Object.prototype.toString.call(value); }
          }
          return String(value);
        };
        try {
          const original = console.error.bind(console);
          console.error = (...args) => {
            try { report('console', args.map(readable).join(' ')); } catch (_) {}
            original(...args);
          };
        } catch (_) {}
      }

      // Everything here returns undefined on purpose: `evaluateJavaScript`
      // cannot serialise a Promise, and an async function handed back to it
      // fails with an unsupported-result error even though it ran fine.
      window.__impulsMusicBridge = {
        command,
        setPlaying: shouldPlay => { setPlaying(!!shouldPlay); },
        setKnownState: token => { setKnownState(String(token)); },
        seek,
        pause,
        artwork: () => { fetchArtwork(); },
        push: () => { push(true); }
      };

      for (const event of ['play', 'pause', 'loadedmetadata', 'durationchange', 'ended', 'emptied']) {
        document.addEventListener(event, () => push(true), true);
      }
      let scheduled = 0;
      const observe = () => {
        new MutationObserver(() => {
          clearTimeout(scheduled);
          scheduled = setTimeout(() => push(false), 400);
        }).observe(document.documentElement, { subtree: true, childList: true, characterData: true });
      };
      if (document.documentElement) observe();
      else document.addEventListener('readystatechange', observe, { once: true });

      // One line, once, naming the routes that exist on this page. It is what
      // turns "the button does nothing" into a fixable report.
      // Twice: once after the page settles, and once after playback starts,
      // because these players register their Media Session handlers only when
      // there is something to control.
      let described = 0;
      const describe = () => {
        if (described >= 2) return;
        described += 1;
        report('bridge', `site=${site} media=${!!media()} created=${created.size} state=${playbackState()} known=${knownState} playing=${isPlaying()} handlers=${Object.keys(handlers).join(',') || 'none'}`);
      };
      setTimeout(describe, 5000);
      const describeOnPlay = setInterval(() => {
        if (!isPlaying()) return;
        clearInterval(describeOnPlay);
        describe();
      }, 1000);

      const pump = setInterval(() => push(true), 1000);
      // Impuls calls this before it releases the web view. Releasing it would
      // take the timers with it, but a pump that is still pushing while the
      // message handler is being removed logs failures for no reason, and a
      // bridge that cannot be stopped is the kind of thing that outlives the
      // next refactor.
      window.__impulsMusicBridge.stop = () => {
        clearInterval(pump);
        clearInterval(describeOnPlay);
        stopped = true;
      };
      push(true);
    })();
    """#
}

@MainActor
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: WebMusicPlayer?

    init(owner: WebMusicPlayer) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}
