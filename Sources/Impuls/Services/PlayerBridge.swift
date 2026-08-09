import AppKit
import ApplicationServices
import ImageIO

/// Public-API bridge to the two scriptable players macOS ships with support
/// for. Everything goes through AppleScript (state, artwork, transport) and
/// distributed notifications (change events) — no private frameworks.
enum PlayerApp: String, CaseIterable, Hashable {
    case music, spotify

    var bundleID: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }

    var displayName: String {
        switch self {
        case .music: return "Apple Music"
        case .spotify: return "Spotify"
        }
    }

    /// Distributed notification the player posts on every state change.
    var changeNotification: Notification.Name {
        switch self {
        case .music: return Notification.Name("com.apple.Music.playerInfo")
        case .spotify: return Notification.Name("com.spotify.client.PlaybackStateChanged")
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}

enum AutomationAuthorization: Equatable {
    case allowed
    case denied
    case notDetermined
    case restricted
}

struct PlayerAccessIssue: Equatable {
    var app: PlayerApp
    var authorization: AutomationAuthorization
}

struct PlayerScanResult {
    var state: PlayerState?
    var accessIssue: PlayerAccessIssue?
    var hasRunningPlayer: Bool
}

struct PlayerState {
    var app: PlayerApp
    var isPlaying: Bool
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var position: TimeInterval
    var artworkURL: URL?
    /// Identity of the track, used to decide when artwork must be refetched.
    var key: String { "\(app.rawValue)|\(title)|\(artist)|\(album)" }
}

enum PlayerBridge {
    private static let queue = DispatchQueue(label: "io.tumanov.impuls.applescript", qos: .utility)
    static let maximumArtworkBytes = 16 * 1_024 * 1_024
    static let artworkPixelSize = 512

    // MARK: - State

    private enum StateQueryResult {
        case state(PlayerState)
        case noState
        case accessIssue(PlayerAccessIssue)
    }

    static func automationAuthorization(
        for app: PlayerApp,
        prompt: Bool,
        completion: @escaping (AutomationAuthorization) -> Void
    ) {
        queue.async {
            let target = NSAppleEventDescriptor(bundleIdentifier: app.bundleID)
            let status = AEDeterminePermissionToAutomateTarget(
                target.aeDesc,
                typeWildCard,
                typeWildCard,
                prompt
            )
            let authorization = automationAuthorization(for: status)
            DispatchQueue.main.async { completion(authorization) }
        }
    }

    static func automationAuthorization(for status: OSStatus) -> AutomationAuthorization {
        if status == noErr { return .allowed }
        if status == OSStatus(errAEEventNotPermitted) { return .denied }
        if status == OSStatus(errAEEventWouldRequireUserConsent) { return .notDetermined }
        return .restricted
    }

    private static func state(of app: PlayerApp, completion: @escaping (StateQueryResult) -> Void) {
        guard app.isRunning else { return completion(.noState) }
        automationAuthorization(for: app, prompt: false) { authorization in
            guard authorization == .allowed else {
                return completion(.accessIssue(PlayerAccessIssue(app: app, authorization: authorization)))
            }

            runScriptDetailed(stateScript(for: app)) { result in
                if let code = result.errorNumber {
                    if code == Int(errAEEventNotPermitted) {
                        return completion(.accessIssue(PlayerAccessIssue(app: app, authorization: .denied)))
                    }
                    if code == Int(errAEEventWouldRequireUserConsent) {
                        return completion(.accessIssue(PlayerAccessIssue(app: app, authorization: .notDetermined)))
                    }
                }
                guard let raw = result.descriptor?.stringValue,
                      !raw.isEmpty,
                      let state = parse(raw, app: app) else {
                    return completion(.noState)
                }
                completion(.state(state))
            }
        }
    }

    /// Never launches a player: only already-running ones are queried, and a
    /// playing app wins over a merely-open one.
    static func currentState(completion: @escaping (PlayerScanResult) -> Void) {
        let candidates = PlayerApp.allCases.filter(\.isRunning)
        guard !candidates.isEmpty else {
            return completion(PlayerScanResult(state: nil, accessIssue: nil, hasRunningPlayer: false))
        }

        var results: [PlayerState] = []
        var accessIssues: [PlayerAccessIssue] = []
        let group = DispatchGroup()
        for app in candidates {
            group.enter()
            state(of: app) { result in
                switch result {
                case .state(let state): results.append(state)
                case .accessIssue(let issue): accessIssues.append(issue)
                case .noState: break
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let state = results.first(where: \.isPlaying) ?? results.first
            let issue = state == nil
                ? accessIssues.first(where: { $0.authorization == .denied }) ?? accessIssues.first
                : nil
            completion(PlayerScanResult(state: state, accessIssue: issue, hasRunningPlayer: true))
        }
    }

    // MARK: - Transport

    static func playPause(_ app: PlayerApp) { command("playpause", on: app) }
    static func next(_ app: PlayerApp) { command("next track", on: app) }
    static func previous(_ app: PlayerApp) {
        // Spotify's `previous track` restarts the current song first, matching
        // its own UI; Music behaves the same way. Seeking to 0 first is what
        // users expect from a "skip back" button.
        command(app == .spotify ? "set player position to 0\n    previous track" : "back track", on: app)
    }

    static func seek(_ app: PlayerApp, to seconds: TimeInterval) {
        command("set player position to \(Int(seconds))", on: app)
    }

    private static func command(_ body: String, on app: PlayerApp) {
        guard app.isRunning else { return }
        runScript("""
        tell application id "\(app.bundleID)"
            \(body)
        end tell
        """) { _ in }
    }

    /// System-wide media key, used when no scriptable player is running.
    /// Requires Accessibility permission; silently does nothing without it.
    static func postMediaKey(_ key: Int32) {
        for down in [true, false] {
            let flags: Int = down ? 0xA00 : 0xB00
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (Int(key) << 16) | flags,
                data2: -1
            ) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    enum MediaKey: Int32 {
        case playPause = 16, next = 17, previous = 18
    }

    // MARK: - Artwork

    static func artwork(for state: PlayerState, completion: @escaping (NSImage?) -> Void) {
        switch state.app {
        case .spotify:
            // Сетевая загрузка обложки отключена в локальной безопасной сборке.
            completion(nil)
        case .music:
            runScript("""
            tell application id "com.apple.Music"
                if (count of artworks of current track) is 0 then return missing value
                return raw data of artwork 1 of current track
            end tell
            """) { descriptor in
                guard let data = descriptor?.data, !data.isEmpty else { return completion(nil) }
                completion(thumbnailArtwork(from: data))
            }
        }
    }

    /// Artwork only occupies a 118-point card. Downsampling through ImageIO
    /// avoids retaining a full source bitmap and validates its dimensions
    /// before AppKit is asked to display it.
    static func thumbnailArtwork(from data: Data) -> NSImage? {
        guard data.count <= maximumArtworkBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              (try? FileToolsService.validateImageDimensions(in: source)) != nil else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: artworkPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(
            cgImage: image,
            size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height))
        )
    }

    // MARK: - Scripts

    private static func stateScript(for app: PlayerApp) -> String {
        let sep = "set sep to character id 1"
        switch app {
        case .spotify:
            return """
            \(sep)
            tell application id "com.spotify.client"
                set st to player state as text
                set t to current track
                set trackName to ""
                set trackArtist to ""
                set trackAlbum to ""
                set trackDuration to 0
                set pos to 0
                set artworkURL to ""
                try
                    set trackName to name of t as text
                end try
                try
                    set trackArtist to artist of t as text
                end try
                try
                    set trackAlbum to album of t as text
                end try
                try
                    set trackDuration to duration of t
                end try
                try
                    set pos to (round ((player position) * 1000))
                end try
                try
                    set artworkURL to artwork url of t as text
                end try
                return st & sep & trackName & sep & trackArtist & sep & trackAlbum & sep & trackDuration & sep & pos & sep & artworkURL
            end tell
            """
        case .music:
            return """
            \(sep)
            tell application id "com.apple.Music"
                set st to player state as text
                set t to current track
                set trackName to ""
                set trackArtist to ""
                set trackAlbum to ""
                set trackDuration to 0
                set pos to 0
                try
                    set trackName to name of t as text
                end try
                try
                    set trackArtist to artist of t as text
                end try
                try
                    set trackAlbum to album of t as text
                end try
                try
                    set trackDuration to (round ((duration of t) * 1000))
                end try
                try
                    set pos to (round ((player position) * 1000))
                end try
                return st & sep & trackName & sep & trackArtist & sep & trackAlbum & sep & trackDuration & sep & pos & sep & ""
            end tell
            """
        }
    }

    static func parse(_ raw: String, app: PlayerApp) -> PlayerState? {
        let parts = raw.components(separatedBy: "\u{1}")
        guard parts.count >= 6, !parts[1].isEmpty else { return nil }
        return PlayerState(
            app: app,
            isPlaying: parts[0].lowercased() == "playing",
            title: parts[1],
            artist: parts[2],
            album: parts[3],
            duration: (Double(parts[4]) ?? 0) / 1000,
            position: (Double(parts[5]) ?? 0) / 1000,
            artworkURL: parts.count > 6 ? URL(string: parts[6]) : nil
        )
    }

    /// Shared AppleScript runner: one serial queue for every script the app sends.
    static func runScript(_ source: String, completion: @escaping (NSAppleEventDescriptor?) -> Void) {
        runScriptDetailed(source) { completion($0.descriptor) }
    }

    private struct ScriptResult {
        var descriptor: NSAppleEventDescriptor?
        var errorNumber: Int?
    }

    private static func runScriptDetailed(
        _ source: String,
        completion: @escaping (ScriptResult) -> Void
    ) {
        queue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let errorNumber = error?[NSAppleScript.errorNumber] as? Int
            if let error, let errorNumber, errorNumber != 0 {
                NSLog("Impuls: AppleScript error \(errorNumber): \(error[NSAppleScript.errorMessage] ?? "")")
            }
            let scriptResult = ScriptResult(descriptor: result, errorNumber: errorNumber)
            DispatchQueue.main.async { completion(scriptResult) }
        }
    }
}
