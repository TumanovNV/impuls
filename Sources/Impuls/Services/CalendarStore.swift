import AppKit
import EventKit

/// Today's meetings, and the link that joins the next one.
///
/// Access is requested only when the user first opens the calendar tab. It is
/// sensitive, and nobody should be asked for it just because the app launched.
@MainActor
final class CalendarStore: ObservableObject {
    private static let maximumMeetings = 250
    enum Access: Equatable {
        case notRequested
        case granted
        case denied
        case failed(String)
    }

    struct Meeting: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let calendarColor: NSColor
        let link: URL?
        let provider: String?

        var isRunning: Bool {
            let now = Date()
            return start <= now && now < end
        }
    }

    @Published private(set) var access: Access = .notRequested
    @Published private(set) var meetings: [Meeting] = []
    /// Recomputed on a timer so the countdown in the header stays honest.
    @Published private(set) var now = Date()

    private let store = EKEventStore()
    private var timer: Timer?
    private var observer: Any?
    /// Whether the panel is open. The half-minute tick serves eyes only — it
    /// keeps the countdown honest and drops meetings as they end — so it runs
    /// exactly while there are eyes.
    private var isActive = false
    /// A day-long horizon leaves the tab empty every evening, which is exactly
    /// when one wonders what tomorrow looks like. A week is still glanceable
    /// because only the next meeting gets the large treatment.
    private let horizon: TimeInterval = 7 * 24 * 3600

    var next: Meeting? {
        meetings.first { $0.end > Date() }
    }

    var upcoming: [Meeting] {
        guard let next else { return [] }
        return meetings.filter { $0.id != next.id && $0.end > Date() }
    }

    // MARK: - Lifecycle

    func start() {
        access = Self.currentAccess()
        guard access == .granted else { return }
        observe()
        reload()
    }

    func stop() {
        stopTimer()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Panel opened or closed. Opening refreshes at once — the countdown must
    /// be right on the first frame, not thirty seconds in — and starts the
    /// tick; closing stops it. Meetings still change while the panel is
    /// closed, but `EKEventStoreChanged` covers that without a clock.
    func setActive(_ active: Bool) {
        isActive = active
        guard active else { return stopTimer() }
        guard access == .granted else { return }
        tick()
        startTimer()
    }

    /// Called when the calendar tab is shown. Never prompts — it only notices
    /// that access was granted elsewhere, or since last launch.
    func refreshAccess() {
        access = Self.currentAccess()
        guard access == .granted else { return }
        observe()
        reload()
        if isActive { startTimer() }
    }

    /// Prompts. Only ever called from the button the user presses.
    func requestAccess() {
        guard Self.currentAccess() == .notRequested else {
            refreshAccess()
            return
        }
        store.requestFullAccessToEvents { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    let message = error.localizedDescription
                    self.access = .failed(message)
                    NSLog("Impuls: Calendar permission request failed: \(message)")
                    return
                }
                self.access = granted ? .granted : .denied
                guard granted else { return }
                self.observe()
                self.reload()
                if self.isActive { self.startTimer() }
            }
        }
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notRequested
        default: return .denied
        }
    }

    private func observe() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        // Half a minute is enough for a countdown shown in whole minutes, and
        // the generous tolerance lets the system fold the wake-up into others.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        now = Date()
        // Drop finished meetings without a full refetch.
        if meetings.contains(where: { $0.end <= now }) {
            meetings.removeAll { $0.end <= now }
        }
    }

    // MARK: - Loading

    func reload() {
        guard access == .granted else { return }
        let start = Date()
        let predicate = store.predicateForEvents(
            withStart: start,
            end: start.addingTimeInterval(horizon),
            calendars: nil
        )
        meetings = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .prefix(Self.maximumMeetings)
            .map { event in
                let link = MeetingLink.find(in: event)
                let title = BoundedText.firstLine(event.title ?? "", maximumCharacters: 240)
                return Meeting(
                    id: event.eventIdentifier
                        ?? "\(event.startDate.timeIntervalSince1970)-\(event.endDate.timeIntervalSince1970)",
                    title: title.isEmpty ? localized("Untitled") : title,
                    start: event.startDate,
                    end: event.endDate,
                    calendarColor: event.calendar.color ?? .systemBlue,
                    link: link,
                    provider: link.flatMap(MeetingLink.provider)
                )
            }
        now = Date()
    }

    func join(_ meeting: Meeting) {
        guard let link = meeting.link else { return }
        NSWorkspace.shared.open(link)
    }

    func openCalendarApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }

    func openPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Finds the video call in an event. Providers put the link wherever they like:
/// Google Meet in the notes, Zoom often in the location, Teams in both.
enum MeetingLink {
    static let maximumScannedCharacters = 32 * 1_024
    private static let providerHosts = [
        "meet.google.com": "Google Meet",
        "zoom.us": "Zoom",
        "teams.microsoft.com": "Teams",
        "teams.live.com": "Teams",
        "webex.com": "Webex",
        "whereby.com": "Whereby",
        "meet.jit.si": "Jitsi",
        "discord.gg": "Discord",
        "telemost.yandex.ru": "Телемост",
    ]

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func find(in event: EKEvent) -> URL? {
        let haystacks = [event.location, event.notes, event.url?.absoluteString].compactMap { $0 }
        for text in haystacks {
            if let url = firstKnownLink(in: text) { return url }
        }
        return event.url.flatMap { isAllowedMeetingURL($0) ? $0 : nil }
    }

    static func firstKnownLink(in text: String) -> URL? {
        guard let detector else { return nil }
        let sample = BoundedText.prefix(text, maximumCharacters: maximumScannedCharacters)
        let range = NSRange(sample.startIndex..., in: sample)
        for match in detector.matches(in: sample, range: range) {
            guard let url = match.url, isAllowedMeetingURL(url) else { continue }
            return url
        }
        return nil
    }

    static func isAllowedMeetingURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              url.port == nil,
              url.user == nil,
              url.password == nil else { return false }

        switch host {
        case "meet.google.com":
            return isGoogleMeetURL(url)
        case "teams.microsoft.com":
            return isTeamsURL(url)
        default:
            if host == "zoom.us" || host.hasSuffix(".zoom.us") {
                return isZoomURL(url)
            }
            // These providers deliberately retain their pre-IMP-21 host-only
            // compatibility contract. Their path semantics need separate
            // product review before a future tightening can be fail-closed.
            return providerHosts.keys.contains { providerHost in
                providerHost != "meet.google.com"
                    && providerHost != "zoom.us"
                    && providerHost != "teams.microsoft.com"
                    && (host == providerHost || host.hasSuffix(".\(providerHost)"))
            }
        }
    }

    static func provider(for url: URL) -> String? {
        guard isAllowedMeetingURL(url), let host = url.host?.lowercased() else { return nil }
        return providerHosts.first { host == $0.key || host.hasSuffix(".\($0.key)") }?.value
    }

    private static func isZoomURL(_ url: URL) -> Bool {
        let components = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3, components[0].isEmpty, components[1] == "j" else { return false }
        let meetingID = components[2].utf8
        return (9...11).contains(meetingID.count) && meetingID.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func isGoogleMeetURL(_ url: URL) -> Bool {
        let bytes = Array(url.path.utf8)
        guard bytes.count == 13, bytes[0] == 47, bytes[4] == 45, bytes[9] == 45 else { return false }
        return [1...3, 5...8, 10...12].allSatisfy { range in
            bytes[range].allSatisfy { ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) }
        }
    }

    private static func isTeamsURL(_ url: URL) -> Bool {
        let components = url.path.split(separator: "/", omittingEmptySubsequences: false)
        return components.count >= 4
            && components[0].isEmpty
            && components[1] == "l"
            && components[2] == "meetup-join"
            && !components[3].isEmpty
    }
}
