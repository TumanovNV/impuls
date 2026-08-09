import AppKit
import ApplicationServices
import ImageIO

/// Public-API bridge dedicated to the native Apple Music application.
///
/// State is read through the application's scripting interface. Distributed
/// player notifications provide a second metadata path, which matters when a
/// transient scripting reply is unavailable even though Music is visibly
/// playing. No private Now Playing framework is linked or loaded.
enum PlayerApp: String, CaseIterable, Hashable {
    case music

    var bundleID: String {
        "com.apple.Music"
    }

    var displayName: String {
        "Apple Music"
    }

    /// Distributed notification the player posts on every state change.
    var changeNotification: Notification.Name {
        Notification.Name("com.apple.Music.playerInfo")
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
    var readFailed: Bool
}

struct PlayerState {
    var app: PlayerApp
    var isPlaying: Bool
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var position: TimeInterval
    var positionIsKnown: Bool
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
        case readFailed
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
                    return completion(.readFailed)
                }
                guard let raw = result.descriptor?.stringValue else { return completion(.readFailed) }
                guard !raw.isEmpty else { return completion(.noState) }
                guard let state = parse(raw, app: app) else { return completion(.readFailed) }
                completion(.state(state))
            }
        }
    }

    /// Apple Music broadcasts public distributed notifications when its player
    /// changes. Their payload is treated as a bounded fallback, not as an
    /// authority for permissions or process discovery.
    static func parseNotification(_ userInfo: [AnyHashable: Any]) -> PlayerState? {
        func string(_ key: String) -> String {
            guard let value = userInfo[key] as? String else { return "" }
            return String(value.prefix(512)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func number(_ key: String) -> Double? {
            (userInfo[key] as? NSNumber)?.doubleValue
        }

        let title = string("Name")
        guard !title.isEmpty else { return nil }
        let durationMilliseconds = max(0, number("Total Time") ?? 0)
        let duration = durationMilliseconds / 1000

        let reportedPosition = number("Player Position") ?? number("Elapsed Time")
        let position: TimeInterval
        if let reportedPosition, reportedPosition.isFinite {
            // Some Music versions report milliseconds and others seconds.
            position = duration > 0 && reportedPosition > duration * 4
                ? reportedPosition / 1000
                : reportedPosition
        } else {
            position = 0
        }
        let nonnegativePosition = max(0, position)

        return PlayerState(
            app: .music,
            isPlaying: string("Player State").lowercased() == "playing",
            title: title,
            artist: string("Artist"),
            album: string("Album"),
            duration: duration,
            position: min(nonnegativePosition, duration > 0 ? duration : nonnegativePosition),
            positionIsKnown: reportedPosition != nil,
            artworkURL: nil
        )
    }

    /// Never launches Music. The pane has a separate explicit action for that.
    static func currentState(completion: @escaping (PlayerScanResult) -> Void) {
        let candidates = PlayerApp.allCases.filter(\.isRunning)
        guard !candidates.isEmpty else {
            return completion(PlayerScanResult(
                state: nil,
                accessIssue: nil,
                hasRunningPlayer: false,
                readFailed: false
            ))
        }

        var results: [PlayerState] = []
        var accessIssues: [PlayerAccessIssue] = []
        var readFailed = false
        let group = DispatchGroup()
        for app in candidates {
            group.enter()
            state(of: app) { result in
                switch result {
                case .state(let state): results.append(state)
                case .accessIssue(let issue): accessIssues.append(issue)
                case .noState: break
                case .readFailed: readFailed = true
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let state = results.first(where: \.isPlaying) ?? results.first
            let issue = state == nil
                ? accessIssues.first(where: { $0.authorization == .denied }) ?? accessIssues.first
                : nil
            completion(PlayerScanResult(
                state: state,
                accessIssue: issue,
                hasRunningPlayer: true,
                readFailed: readFailed
            ))
        }
    }

    // MARK: - Transport

    static func playPause(_ app: PlayerApp) { command("playpause", on: app) }
    static func next(_ app: PlayerApp) { command("next track", on: app) }
    static func previous(_ app: PlayerApp) { command("back track", on: app) }

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

    // MARK: - Artwork

    static func artwork(for _: PlayerState, completion: @escaping (NSImage?) -> Void) {
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

    private static func stateScript(for _: PlayerApp) -> String {
        let sep = "set sep to character id 1"
        return """
        \(sep)
        tell application id "com.apple.Music"
            set st to player state as text
            if st is "stopped" then return ""
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
            positionIsKnown: true,
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
