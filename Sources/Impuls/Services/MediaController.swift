import AppKit

/// Safe Now Playing integration based only on public macOS mechanisms.
///
/// Apple Music and Spotify expose track metadata and transport through their
/// scripting dictionaries. Other sources can still receive standard media-key
/// events when macOS grants the required Accessibility permission, but private
/// playback APIs and process injection are deliberately not used.
@MainActor
final class MediaController: ObservableObject {
    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var key: String
    }

    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var sourceName: String?

    private var activeApp: PlayerApp?
    private var artworkKey: String?
    private var anchor: (position: TimeInterval, at: Date)?
    private var pendingSeek: (target: TimeInterval, at: Date)?
    private var ticker: Timer?
    private var observers: [Any] = []
    private var isActive = false

    func start() {
        let center = DistributedNotificationCenter.default()
        for app in PlayerApp.allCases {
            observers.append(center.addObserver(
                forName: app.changeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.activeApp = app
                    self?.refreshFromPlayers()
                }
            })
        }
        refreshFromPlayers()
    }

    func stop() {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
        ticker?.invalidate()
        ticker = nil
    }

    func setActive(_ active: Bool) {
        isActive = active
        updateTicker()
        guard active else { return }
        tick()
        refreshFromPlayers()
    }

    func togglePlayPause() {
        isPlaying.toggle()
        setAnchor(position)
        if let activeApp {
            PlayerBridge.playPause(activeApp)
        } else {
            PlayerBridge.postMediaKey(PlayerBridge.MediaKey.playPause.rawValue)
        }
    }

    func next() {
        if let activeApp {
            PlayerBridge.next(activeApp)
        } else {
            PlayerBridge.postMediaKey(PlayerBridge.MediaKey.next.rawValue)
        }
    }

    func previous() {
        if let activeApp {
            PlayerBridge.previous(activeApp)
        } else {
            PlayerBridge.postMediaKey(PlayerBridge.MediaKey.previous.rawValue)
        }
    }

    func seek(to seconds: TimeInterval) {
        guard duration > 0, let activeApp else { return }
        let clamped = min(max(0, seconds), duration)
        setAnchor(clamped)
        pendingSeek = (clamped, Date())
        PlayerBridge.seek(activeApp, to: clamped)
    }

    private func refreshFromPlayers() {
        PlayerBridge.currentState { [weak self] state in
            guard let self else { return }
            guard let state else { return self.clear() }

            self.activeApp = state.app
            self.sourceName = state.app.displayName
            self.track = Track(title: state.title, artist: state.artist, album: state.album, key: state.key)
            self.isPlaying = state.isPlaying
            self.duration = state.duration

            if let pending = self.pendingSeek {
                let settled = abs(state.position - pending.target) < 2.5
                let expired = Date().timeIntervalSince(pending.at) > 1.5
                if settled || expired {
                    self.pendingSeek = nil
                    self.adopt(state.position)
                }
            } else {
                self.adopt(state.position)
            }
            self.updateTicker()

            guard self.artworkKey != state.key else { return }
            self.artworkKey = state.key
            self.artwork = nil
            PlayerBridge.artwork(for: state) { [weak self] image in
                guard let self, self.artworkKey == state.key else { return }
                self.artwork = image
            }
        }
    }

    private func clear() {
        activeApp = nil
        track = nil
        artwork = nil
        artworkKey = nil
        isPlaying = false
        duration = 0
        position = 0
        sourceName = nil
        updateTicker()
    }

    private func setAnchor(_ value: TimeInterval) {
        position = value
        anchor = (value, Date())
    }

    private let forwardTolerance: TimeInterval = 0.75
    private let seekThreshold: TimeInterval = 2

    private func adopt(_ reported: TimeInterval) {
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
        ticker?.invalidate()
        ticker = nil
        guard isPlaying, isActive else { return }
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
