import AppKit

/// Coordinates one explicitly selected music source. Apple Music and web
/// players have separate adapters and permissions; no process-scanning winner
/// is guessed when several services happen to be open at once.
@MainActor
final class MediaController: ObservableObject {
    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var key: String
    }

    enum EmptyReason: Equatable {
        case appleMusicNotRunning
        case appleMusicIdle
        case appleMusicUnreadable
        case webPlayerNotOpen
        case webPlayerLoading
        case webPlayerIdle
        case webPlayerFailed
    }

    static let selectedSourceKey = "music.selectedSource.v1"

    @Published private(set) var selectedSource: MusicSource
    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var accessIssue: PlayerAccessIssue?
    @Published private(set) var emptyReason: EmptyReason
    @Published private(set) var isLoading = false
    /// What WebKit reported when a provider page refused to load, so the pane
    /// can say why instead of showing an empty card.
    @Published private(set) var webPlayerError: String?

    var sourceName: String { selectedSource.displayName }
    var canSeek: Bool { track != nil && duration > 0 }
    var webPlayerWasOpened: Bool { webPlayer?.source == selectedSource }

    private let defaults: UserDefaults
    private var webPlayer: WebMusicPlayer?
    private var artworkKey: String?
    private var anchor: (position: TimeInterval, at: Date)?
    private var pendingSeek: (target: TimeInterval, at: Date)?
    private var ticker: Timer?
    private var nativeRefreshTimer: Timer?
    private var observers: [Any] = []
    private var isActive = false
    private var isStarted = false
    private var refreshInFlight = false
    private var refreshPending = false
    private var consecutiveEmptyRefreshes = 0
    private var notificationFallback: (state: PlayerState, receivedAt: Date)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.selectedSourceKey).flatMap {
            MusicSource(rawValue: $0)
        }
        let source = stored ?? .appleMusic
        selectedSource = source
        emptyReason = source.isWeb ? .webPlayerNotOpen : .appleMusicNotRunning
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(
            forName: PlayerApp.music.changeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.selectedSource == .appleMusic else { return }
                if let userInfo = notification.userInfo,
                   let state = PlayerBridge.parseNotification(userInfo) {
                    self.notificationFallback = (state, Date())
                    self.adopt(state)
                }
                self.refreshFromAppleMusic()
            }
        })
        if selectedSource == .appleMusic { refreshFromAppleMusic() }
    }

    func stop() {
        isStarted = false
        refreshPending = false
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
        ticker?.invalidate()
        ticker = nil
        nativeRefreshTimer?.invalidate()
        nativeRefreshTimer = nil
        // The web player was the one piece of background work `stop()` did not
        // reach. Its injected bridge pushes state once a second, and that ran
        // on past panel teardown until the process exited. `teardown()` is
        // idempotent and leaves the player reusable: `openWebPlayer()` rebuilds
        // it through `webPlayer ?? makeWebPlayer()` when the user asks again.
        webPlayer?.teardown()
        webPlayer = nil
    }

    func setActive(_ active: Bool) {
        isActive = active
        updateTicker()
        updateNativeRefreshTimer()
        guard active else { return }
        tick()
        if selectedSource == .appleMusic {
            refreshFromAppleMusic()
        } else {
            webPlayer?.requestSnapshot()
        }
    }

    func selectSource(_ source: MusicSource) {
        guard source != selectedSource else { return }
        if let player = webPlayer, player.source != nil, player.source != source {
            player.deactivate()
        }
        selectedSource = source
        defaults.set(source.rawValue, forKey: Self.selectedSourceKey)
        clear(reason: source.isWeb ? .webPlayerNotOpen : .appleMusicNotRunning)
        updateNativeRefreshTimer()

        if source == .appleMusic {
            refreshFromAppleMusic()
        } else if let player = webPlayer, player.source == source {
            emptyReason = .webPlayerIdle
            if let state = player.currentState { adopt(state, source: source) }
            player.requestSnapshot()
        }
    }

    /// The only entry point that opens a web service. Source selection itself
    /// remains local and does not create a web view or perform a request.
    func openSelectedSource() {
        if selectedSource == .appleMusic {
            guard let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: PlayerApp.music.bundleID
            ) else {
                clear(reason: .appleMusicNotRunning)
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [weak self] _, error in
                if let error { NSLog("Impuls: cannot open Apple Music: \(error.localizedDescription)") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self?.refreshFromAppleMusic()
                }
            }
            return
        }

        let player = webPlayer ?? makeWebPlayer()
        isLoading = true
        webPlayerError = nil
        emptyReason = .webPlayerLoading
        player.show(source: selectedSource)
    }

    func retry() {
        if selectedSource == .appleMusic {
            refreshFromAppleMusic()
        } else if emptyReason == .webPlayerFailed {
            // A failed load leaves the window on the local error page, so the
            // retry has to start the provider page again, not reload that.
            openSelectedSource()
        } else if webPlayerWasOpened {
            webPlayer?.requestSnapshot()
        } else {
            openSelectedSource()
        }
    }

    func togglePlayPause() {
        guard track != nil else { return }
        isPlaying.toggle()
        setAnchor(position)
        if selectedSource == .appleMusic {
            PlayerBridge.playPause(.music)
        } else {
            webPlayer?.command(.playPause)
        }
    }

    func next() {
        if selectedSource == .appleMusic {
            PlayerBridge.next(.music)
        } else {
            webPlayer?.command(.next)
        }
    }

    func previous() {
        if selectedSource == .appleMusic {
            PlayerBridge.previous(.music)
        } else {
            webPlayer?.command(.previous)
        }
    }

    func seek(to seconds: TimeInterval) {
        guard canSeek else { return }
        let clamped = min(max(0, seconds), duration)
        setAnchor(clamped)
        pendingSeek = (clamped, Date())
        if selectedSource == .appleMusic {
            PlayerBridge.seek(.music, to: clamped)
        } else {
            webPlayer?.seek(to: clamped)
        }
    }

    func resolveAutomationAccess() {
        guard let issue = accessIssue else { return }
        if issue.authorization == .notDetermined {
            PlayerBridge.automationAuthorization(for: .music, prompt: true) { [weak self] _ in
                self?.refreshFromAppleMusic()
            }
        } else {
            openAutomationSettings()
        }
    }

    func openAutomationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Apple Music

    private func refreshFromAppleMusic() {
        guard isStarted, selectedSource == .appleMusic else { return }
        if refreshInFlight {
            refreshPending = true
            return
        }
        refreshInFlight = true
        PlayerBridge.currentState { [weak self] result in
            guard let self else { return }
            self.refreshInFlight = false
            guard self.isStarted, self.selectedSource == .appleMusic else {
                self.refreshPending = false
                return
            }
            let shouldRefreshAgain = self.refreshPending
            self.refreshPending = false
            defer {
                if shouldRefreshAgain { self.refreshFromAppleMusic() }
            }

            if let state = result.state {
                self.notificationFallback = (state, Date())
                self.consecutiveEmptyRefreshes = 0
                self.accessIssue = nil
                self.isLoading = false
                self.adopt(state)
                return
            }

            if let fallback = self.notificationFallback,
               Date().timeIntervalSince(fallback.receivedAt) < 8,
               result.hasRunningPlayer {
                self.adopt(fallback.state)
                return
            }

            if result.accessIssue == nil,
               result.hasRunningPlayer,
               self.track != nil,
               self.consecutiveEmptyRefreshes == 0 {
                self.consecutiveEmptyRefreshes = 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.refreshFromAppleMusic()
                }
                return
            }

            self.consecutiveEmptyRefreshes = 0
            self.accessIssue = result.accessIssue
            self.clear(reason: result.readFailed ? .appleMusicUnreadable : (
                result.hasRunningPlayer ? .appleMusicIdle : .appleMusicNotRunning
            ), preservingAccessIssue: true)
        }
    }

    private func updateNativeRefreshTimer() {
        guard isActive, selectedSource == .appleMusic else {
            nativeRefreshTimer?.invalidate()
            nativeRefreshTimer = nil
            return
        }
        guard nativeRefreshTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFromAppleMusic() }
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        nativeRefreshTimer = timer
    }

    // MARK: - Web players

    private func makeWebPlayer() -> WebMusicPlayer {
        let player = WebMusicPlayer()
        player.onLoading = { [weak self] source, loading in
            guard let self, self.selectedSource == source else { return }
            self.isLoading = loading
            if loading, self.track == nil {
                self.emptyReason = .webPlayerLoading
            } else if !loading, self.track == nil {
                self.emptyReason = .webPlayerIdle
            }
        }
        player.onState = { [weak self] source, state in
            guard let self, self.selectedSource == source else { return }
            self.isLoading = false
            guard let state else {
                self.clear(reason: self.emptyReason == .webPlayerFailed
                    ? .webPlayerFailed
                    : .webPlayerIdle)
                return
            }
            self.adopt(state, source: source)
        }
        player.onArtwork = { [weak self] source, key, image in
            guard let self, self.selectedSource == source,
                  self.artworkKey == Self.artworkKey(source: source, cover: key) else { return }
            self.artwork = image
        }
        player.onFailure = { [weak self] source, message in
            guard let self, self.selectedSource == source else { return }
            self.webPlayerError = String(message.prefix(200))
            self.clear(reason: .webPlayerFailed)
        }
        webPlayer = player
        return player
    }

    private static func artworkKey(source: MusicSource, cover: String) -> String? {
        cover.isEmpty ? nil : "\(source.rawValue)|cover|\(cover)"
    }

    // MARK: - Shared presentation state

    private func adopt(_ state: PlayerState) {
        let oldKey = track?.key
        accessIssue = nil
        emptyReason = .appleMusicIdle
        track = Track(
            title: state.title,
            artist: state.artist,
            album: state.album,
            key: state.key
        )
        isPlaying = state.isPlaying
        duration = state.duration

        if state.positionIsKnown {
            settlePosition(state.position)
        } else if oldKey != state.key {
            setAnchor(0)
        }
        updateTicker()

        guard artworkKey != state.key else { return }
        artworkKey = state.key
        artwork = nil
        PlayerBridge.artwork(for: state) { [weak self] image in
            guard let self, self.artworkKey == state.key else { return }
            self.artwork = image
        }
    }

    private func adopt(_ state: WebMusicState, source: MusicSource) {
        accessIssue = nil
        emptyReason = .webPlayerIdle
        webPlayerError = nil
        track = Track(
            title: state.title,
            artist: state.artist,
            album: state.album,
            key: "\(source.rawValue)|\(state.key)"
        )
        isPlaying = state.isPlaying
        duration = state.duration
        settlePosition(state.position)
        updateTicker()

        // The cover is keyed by the image the page is showing, not by the
        // track: a page can swap one without the other, and reloading on every
        // snapshot would make the card flicker once a second.
        let cover = Self.artworkKey(source: source, cover: state.artworkKey)
        guard artworkKey != cover else { return }
        artworkKey = cover
        artwork = nil
    }

    private func settlePosition(_ reported: TimeInterval) {
        if let pending = pendingSeek {
            let settled = abs(reported - pending.target) < 2.5
            let expired = Date().timeIntervalSince(pending.at) > 1.5
            if settled || expired {
                pendingSeek = nil
                adoptPosition(reported)
            }
        } else {
            adoptPosition(reported)
        }
    }

    private func clear(reason: EmptyReason, preservingAccessIssue: Bool = false) {
        track = nil
        artwork = nil
        artworkKey = nil
        isPlaying = false
        duration = 0
        position = 0
        anchor = nil
        pendingSeek = nil
        isLoading = reason == .webPlayerLoading
        emptyReason = reason
        if reason != .webPlayerFailed { webPlayerError = nil }
        if !preservingAccessIssue { accessIssue = nil }
        updateTicker()
    }

    private func setAnchor(_ value: TimeInterval) {
        position = value
        anchor = (value, Date())
    }

    private let forwardTolerance: TimeInterval = 0.75
    private let seekThreshold: TimeInterval = 2

    private func adoptPosition(_ reported: TimeInterval) {
        var value = max(0, reported)
        if duration > 0 { value = min(value, duration) }
        let delta = value - position

        if delta >= forwardTolerance || delta <= -seekThreshold {
            position = value
            anchor = (value, Date())
        } else {
            anchor = (position, Date())
        }
    }

    private func updateTicker() {
        guard isPlaying, isActive else {
            ticker?.invalidate()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        guard let anchor, isPlaying else { return }
        let value = anchor.position + Date().timeIntervalSince(anchor.at)
        position = duration > 0 ? min(value, duration) : value
    }
}
