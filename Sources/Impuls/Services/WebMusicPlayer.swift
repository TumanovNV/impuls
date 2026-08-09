import AppKit
import WebKit

struct WebMusicState: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var position: TimeInterval
    var isPlaying: Bool

    var key: String { "web|\(title)|\(artist)|\(album)" }

    static func decode(_ body: Any, source: MusicSource) -> WebMusicState? {
        guard source.isWeb,
              let payload = body as? [String: Any],
              (payload["version"] as? NSNumber)?.intValue == 1,
              let page = payload["page"] as? String,
              let pageURL = URL(string: page),
              source.allowsTopLevelNavigation(to: pageURL) else { return nil }

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
            isPlaying: (payload["playing"] as? NSNumber)?.boolValue ?? false
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

enum WebMusicCommand: String {
    case playPause
    case next
    case previous
}

/// Owns a user-opened web player. Merely creating `MediaController` or choosing
/// a source never constructs a WKWebView and therefore never starts networking.
/// The first request is made only by `show(source:)`, which is wired to the
/// explicit "Open web player" button in the Music pane.
@MainActor
final class WebMusicPlayer: NSObject, WKNavigationDelegate, WKUIDelegate {
    var onState: ((MusicSource, WebMusicState?) -> Void)?
    var onLoading: ((MusicSource, Bool) -> Void)?

    private(set) var source: MusicSource?
    private(set) var currentState: WebMusicState?

    private var webView: WKWebView?
    private var windowController: NSWindowController?
    private var messageProxy: WeakScriptMessageHandler?

    func show(source: MusicSource) {
        guard let homeURL = source.webHomeURL else { return }
        let webView = webView ?? makeWebView()
        let sourceChanged = self.source != source
        self.source = source
        currentState = nil
        onState?(source, nil)

        let windowController = windowController ?? makeWindowController(webView: webView)
        windowController.window?.title = "Impuls — \(source.displayName)"
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        if !sourceChanged, webView.isLoading { return }
        if sourceChanged || webView.url.map({ !source.allowsTopLevelNavigation(to: $0) }) != false {
            onLoading?(source, true)
            webView.load(URLRequest(url: homeURL))
        } else {
            requestSnapshot()
        }
    }

    func command(_ command: WebMusicCommand) {
        evaluate("window.__impulsMusicBridge?.command('\(command.rawValue)')")
    }

    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        evaluate("window.__impulsMusicBridge?.seek(\(max(0, seconds)))")
    }

    func requestSnapshot() {
        evaluate("window.__impulsMusicBridge?.push()")
    }

    func deactivate() {
        evaluate("window.__impulsMusicBridge?.pause()")
        windowController?.window?.orderOut(nil)
        currentState = nil
    }

    private func evaluate(_ source: String) {
        guard let webView, let selected = self.source,
              webView.url.map({ selected.allowsTopLevelNavigation(to: $0) }) == true else { return }
        webView.evaluateJavaScript(source) { _, error in
            if let error { NSLog("Impuls: web music command failed: \(error.localizedDescription)") }
        }
    }

    private func makeWebView() -> WKWebView {
        let controller = WKUserContentController()
        let proxy = WeakScriptMessageHandler(owner: self)
        messageProxy = proxy
        controller.add(proxy, name: "impulsMusic")
        controller.addUserScript(WKUserScript(
            source: Self.bridgeScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = "Impuls/1.3"
        configuration.preferences.isElementFullscreenEnabled = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        self.webView = webView
        return webView
    }

    private func makeWindowController(webView: WKWebView) -> NSWindowController {
        let window = NSWindow(
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
        if source.allowsTopLevelNavigation(to: url) {
            decisionHandler(.allow)
            return
        }
        if navigationAction.navigationType == .linkActivated,
           ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url, let source else { return nil }
        if source.allowsTopLevelNavigation(to: url) {
            webView.load(navigationAction.request)
        } else if ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let source else { return }
        onLoading?(source, true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let source else { return }
        onLoading?(source, false)
        requestSnapshot()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        navigationFailed(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        navigationFailed(error)
    }

    private func navigationFailed(_ error: Error) {
        guard let source else { return }
        NSLog("Impuls: web music navigation failed: \(error.localizedDescription)")
        onLoading?(source, false)
        onState?(source, nil)
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.name == "impulsMusic",
              let source,
              let pageURL = message.webView?.url,
              source.allowsTopLevelNavigation(to: pageURL) else { return }
        let state = WebMusicState.decode(message.body, source: source)
        currentState = state
        onState?(source, state)
    }

    private static let bridgeScript = #"""
    (() => {
      if (window.__impulsMusicBridge) return;

      const tidy = value => typeof value === 'string' ? value.trim().slice(0, 512) : '';
      const visible = element => {
        if (!element) return false;
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
      };
      const text = selectors => {
        for (const selector of selectors) {
          const element = document.querySelector(selector);
          const value = tidy(element?.textContent || element?.getAttribute?.('aria-label'));
          if (value) return value;
        }
        return '';
      };
      const mediaElement = () => {
        const elements = [...document.querySelectorAll('audio, video')];
        return elements.find(element => !element.paused && !element.ended)
          || elements.find(element => Number.isFinite(element.duration) && element.duration > 0)
          || elements[0]
          || null;
      };
      const metadata = () => {
        try { return navigator.mediaSession?.metadata || null; } catch (_) { return null; }
      };
      const fallbackTitle = () => tidy(document.title)
        .replace(/\s+[—|·-]\s+(Яндекс Музыка|Yandex Music|YouTube Music|Spotify|VK Музыка).*$/i, '')
        .replace(/^\(\d+\)\s*/, '');
      const snapshot = () => {
        const media = mediaElement();
        const meta = metadata();
        const playbackState = navigator.mediaSession?.playbackState || 'none';
        return {
          version: 1,
          page: location.href,
          title: tidy(meta?.title) || text([
            '[data-test-id="TRACK_TITLE"]',
            'yt-formatted-string.title.ytmusic-player-bar',
            '[data-testid="now-playing-widget"] [data-testid="context-item-link"]',
            '[class*="PlayerBar"] [class*="title"]'
          ]) || (media ? fallbackTitle() : ''),
          artist: tidy(meta?.artist) || text([
            '[data-test-id="TRACK_ARTIST"]',
            '.byline.ytmusic-player-bar',
            '[data-testid="now-playing-widget"] [data-testid="context-item-info-artist"]',
            '[class*="PlayerBar"] [class*="artist"]'
          ]),
          album: tidy(meta?.album),
          duration: Number.isFinite(media?.duration) ? media.duration : 0,
          position: Number.isFinite(media?.currentTime) ? media.currentTime : 0,
          playing: playbackState === 'playing' || (playbackState === 'none' && !!media && !media.paused && !media.ended)
        };
      };
      const push = () => {
        try { window.webkit.messageHandlers.impulsMusic.postMessage(snapshot()); } catch (_) {}
      };
      const clickKnown = action => {
        const selectors = {
          playPause: [
            '[data-test-id="PLAY_BUTTON"]', '[data-testid="control-button-playpause"]',
            '#play-pause-button', '.play-pause-button', '[class*="PlayerBar"] button[class*="play"]'
          ],
          next: [
            '[data-test-id="NEXT_TRACK_BUTTON"]', '[data-testid="control-button-skip-forward"]',
            '.next-button', '[class*="PlayerBar"] button[class*="next"]'
          ],
          previous: [
            '[data-test-id="PREVIOUS_TRACK_BUTTON"]', '[data-testid="control-button-skip-back"]',
            '.previous-button', '[class*="PlayerBar"] button[class*="prev"]'
          ]
        }[action] || [];
        for (const selector of selectors) {
          const button = [...document.querySelectorAll(selector)].find(visible);
          if (button) { button.click(); return true; }
        }
        const expressions = {
          playPause: /воспроизвести|пауза|play|pause/i,
          next: /следующ|next/i,
          previous: /предыдущ|назад|previous|back/i
        };
        const pattern = expressions[action];
        const candidate = [...document.querySelectorAll('button, [role="button"]')].find(element => {
          const label = `${element.getAttribute('aria-label') || ''} ${element.getAttribute('title') || ''}`;
          return visible(element) && pattern?.test(label);
        });
        if (candidate) { candidate.click(); return true; }
        return false;
      };
      const command = action => {
        const media = mediaElement();
        if (action === 'playPause' && media) {
          if (media.paused) media.play().catch(() => clickKnown(action));
          else media.pause();
        } else {
          clickKnown(action);
        }
        setTimeout(push, 120);
      };
      const seek = seconds => {
        const media = mediaElement();
        if (!media || !Number.isFinite(seconds)) return;
        const maximum = Number.isFinite(media.duration) ? media.duration : seconds;
        media.currentTime = Math.max(0, Math.min(seconds, maximum));
        setTimeout(push, 80);
      };

      const pause = () => {
        const media = mediaElement();
        if (media && !media.paused) media.pause();
        setTimeout(push, 80);
      };

      window.__impulsMusicBridge = { command, seek, pause, push };
      for (const event of ['play', 'pause', 'loadedmetadata', 'durationchange', 'ended', 'emptied']) {
        document.addEventListener(event, push, true);
      }
      let scheduled = 0;
      new MutationObserver(() => {
        clearTimeout(scheduled);
        scheduled = setTimeout(push, 180);
      }).observe(document.documentElement, { subtree: true, childList: true, characterData: true });
      setInterval(push, 1000);
      push();
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
