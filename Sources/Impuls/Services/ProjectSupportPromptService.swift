import AppKit
import Foundation

/// Where a person is in the one conversation Impuls is allowed to start about
/// supporting the project.
///
/// Four of the five states are terminal for the *automatic* prompt. Only
/// `neverShown` and `snoozedOnce` can still lead to one appearing by itself,
/// which is what caps the whole feature at two lifetime appearances.
enum ProjectSupportPromptState: String, Codable, Equatable, Sendable {
    /// No automatic prompt has been shown yet.
    case neverShown
    /// Shown once and declined. One more automatic appearance remains possible.
    case snoozedOnce
    /// The user asked to open the project page. Impuls does not know, and must
    /// not claim to know, whether a star was actually given.
    case openedGitHub
    /// The user chose to send feedback. The existing feedback flow took over.
    case openedFeedback
    /// Declined twice, or the second prompt was closed. Never ask again.
    case dismissedForever

    /// Whether an automatic prompt may still appear for this state.
    var allowsAutomaticPrompt: Bool {
        switch self {
        case .neverShown, .snoozedOnce:
            return true
        case .openedGitHub, .openedFeedback, .dismissedForever:
            return false
        }
    }
}

/// The machine-local counters behind the prompt decision.
///
/// Everything here is a number or a date about *this* installation. There is no
/// history of what the user did, which modules they opened, what they searched
/// for or what they copied — the decision needs none of that, and collecting it
/// would turn an anti-nag policy into a usage log.
struct ProjectSupportPromptRecord: Codable, Equatable, Sendable {
    /// When Impuls first observed a deliberate use. Set once and never moved.
    var firstMeaningfulUseAt: Date?
    /// Start of the most recent calendar day that counted as active.
    var lastActiveDay: Date?
    var activeDayCount: Int
    var meaningfulUseCount: Int
    /// When the last *counted* use happened. Anchors the coalescing window and
    /// answers "has anything happened since the last prompt?".
    var lastMeaningfulUseAt: Date?
    var lastPromptAt: Date?
    var shownCount: Int
    var state: ProjectSupportPromptState

    static let empty = ProjectSupportPromptRecord(
        firstMeaningfulUseAt: nil,
        lastActiveDay: nil,
        activeDayCount: 0,
        meaningfulUseCount: 0,
        lastMeaningfulUseAt: nil,
        lastPromptAt: nil,
        shownCount: 0,
        state: .neverShown
    )

    private enum CodingKeys: String, CodingKey {
        case firstMeaningfulUseAt, lastActiveDay, activeDayCount, meaningfulUseCount
        case lastMeaningfulUseAt, lastPromptAt, shownCount, state
    }

    init(
        firstMeaningfulUseAt: Date?,
        lastActiveDay: Date?,
        activeDayCount: Int,
        meaningfulUseCount: Int,
        lastMeaningfulUseAt: Date?,
        lastPromptAt: Date?,
        shownCount: Int,
        state: ProjectSupportPromptState
    ) {
        self.firstMeaningfulUseAt = firstMeaningfulUseAt
        self.lastActiveDay = lastActiveDay
        self.activeDayCount = activeDayCount
        self.meaningfulUseCount = meaningfulUseCount
        self.lastMeaningfulUseAt = lastMeaningfulUseAt
        self.lastPromptAt = lastPromptAt
        self.shownCount = shownCount
        self.state = state
    }

    /// Tolerant on purpose, and biased towards *fewer* prompts.
    ///
    /// A blob written by a newer build, or one that was truncated, must not be
    /// able to manufacture eligibility. Every field falls back to the value a
    /// fresh install would have, an unknown state decodes as `dismissedForever`
    /// rather than as "ask again", and counts are clamped non-negative.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        firstMeaningfulUseAt = try container.decodeIfPresent(Date.self, forKey: .firstMeaningfulUseAt)
        lastActiveDay = try container.decodeIfPresent(Date.self, forKey: .lastActiveDay)
        activeDayCount = max(0, try container.decodeIfPresent(Int.self, forKey: .activeDayCount) ?? 0)
        meaningfulUseCount = max(0, try container.decodeIfPresent(Int.self, forKey: .meaningfulUseCount) ?? 0)
        lastMeaningfulUseAt = try container.decodeIfPresent(Date.self, forKey: .lastMeaningfulUseAt)
        lastPromptAt = try container.decodeIfPresent(Date.self, forKey: .lastPromptAt)
        shownCount = max(0, try container.decodeIfPresent(Int.self, forKey: .shownCount) ?? 0)
        let raw = try container.decodeIfPresent(String.self, forKey: .state)
        state = raw.flatMap(ProjectSupportPromptState.init(rawValue:)) ?? (raw == nil ? .neverShown : .dismissedForever)
    }
}

/// What the running app looks like at the instant a prompt is being considered.
///
/// Kept as plain data so "is this a good moment?" is answerable in a test rather
/// than only in front of a real window server.
struct ProjectSupportPromptMoment: Equatable, Sendable {
    /// How long this process has been running. A prompt is never part of launch.
    var timeSinceLaunch: TimeInterval
    /// The notch panel is expanded — the user is working in it.
    var isPanelOpen: Bool
    /// Any other Impuls window is on screen: onboarding, What's New, Settings,
    /// Feedback, a Sparkle dialog. All of them mean "not now".
    var showsAnotherWindow: Bool
    /// A language change is waiting to restart the app.
    var isAwaitingLanguageRelaunch: Bool
    /// A prompt has already been presented in this process.
    var didPresentInThisSession: Bool

    /// Impuls is idle and nothing is competing for the user's attention.
    var isQuiet: Bool {
        timeSinceLaunch >= ProjectSupportPromptService.minimumUptimeBeforePrompt
            && !isPanelOpen
            && !showsAnotherWindow
            && !isAwaitingLanguageRelaunch
            && !didPresentInThisSession
    }
}

/// Decides — entirely on this Mac — whether Impuls has earned the right to ask
/// once for a GitHub star or a piece of feedback, and makes sure it stops asking.
///
/// Deliberately not a network client and deliberately not telemetry. Nothing it
/// counts leaves the machine: there is no "prompt shown" event, no "star
/// clicked" event and no server that could be asked whether the star exists.
/// GitHub is never queried, because the only honest thing Impuls can record is
/// that it handed a URL to the browser.
///
/// The thresholds are a policy, not a formula to tune later without thought:
/// thirty calendar days, ten separate active days and twenty deliberate uses
/// together describe somebody who kept the app, rather than somebody who
/// installed it a month ago and forgot.
@MainActor
final class ProjectSupportPromptService {
    /// Versioned like the other machine-local blobs so a future shape change is
    /// a deliberate migration rather than a silent reinterpretation.
    nonisolated static let storageKey = "projectSupport.prompt.v1"

    /// The one URL this feature may open. Compared exactly, never assembled from
    /// user input.
    nonisolated static let projectURL = URL(string: "https://github.com/TumanovNV/impuls")!

    // MARK: - Policy

    /// Calendar days between the first deliberate use and the first prompt.
    nonisolated static let requiredDaysSinceFirstUse = 30
    /// Distinct calendar days on which Impuls was deliberately used.
    nonisolated static let requiredActiveDays = 10
    /// Deliberate uses, coalesced by `meaningfulUseWindow`.
    nonisolated static let requiredMeaningfulUses = 20
    /// Calendar days a "Not Now" buys before the subject may come up again.
    nonisolated static let snoozeDays = 60
    /// Two, ever. The second decline ends the conversation permanently.
    nonisolated static let maximumAutomaticPrompts = 2
    /// Uses closer together than this are one episode.
    ///
    /// Without it, "twenty uses" would be twenty clicks — which a single busy
    /// afternoon produces — instead of twenty separate times somebody reached
    /// for Impuls. It does not weaken the other two thresholds; it stops this
    /// one from measuring the wrong thing.
    nonisolated static let meaningfulUseWindow: TimeInterval = 60
    /// A prompt is never part of the launch experience.
    nonisolated static let minimumUptimeBeforePrompt: TimeInterval = 120

    private let defaults: UserDefaults
    /// Injected so a test can be thirty days old without waiting thirty days.
    private let now: () -> Date
    /// Injected for the same reason day boundaries must be reproducible: the
    /// live value is the user's calendar, in the user's time zone.
    private let calendar: Calendar

    private(set) var record: ProjectSupportPromptRecord

    init(
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
        record = Self.load(from: defaults)
    }

    // MARK: - Recording

    /// One deliberate entrance into the workspace.
    ///
    /// Called from the single funnel in `NotchController`; see that file for
    /// what counts. Returns whether the call actually advanced the counters,
    /// which is only used by tests and by the caller's own bookkeeping.
    @discardableResult
    func recordMeaningfulUse() -> Bool {
        let moment = now()

        if let last = record.lastMeaningfulUseAt {
            let elapsed = moment.timeIntervalSince(last)
            // Same episode. A backwards clock produces a negative interval and
            // is deliberately *not* treated as one, so a clock correction can
            // never swallow real use.
            if elapsed >= 0, elapsed < Self.meaningfulUseWindow { return false }
        }

        if record.firstMeaningfulUseAt == nil {
            // Existing installs start their thirty days here rather than at an
            // install date reconstructed from filesystem metadata. Guessing one
            // would show this prompt to every current user on the first launch
            // after the update, which is precisely the behaviour being avoided.
            record.firstMeaningfulUseAt = moment
        }

        let day = calendar.startOfDay(for: moment)
        if let lastDay = record.lastActiveDay {
            // Strictly later only. A repeat within the same day is not a new
            // active day, and a day *earlier* than the last one is a clock that
            // moved back — which cannot be allowed to buy an extra active day.
            if day > lastDay {
                record.lastActiveDay = day
                record.activeDayCount += 1
            }
        } else {
            record.lastActiveDay = day
            record.activeDayCount += 1
        }

        record.meaningfulUseCount += 1
        record.lastMeaningfulUseAt = moment
        persist()
        return true
    }

    // MARK: - Eligibility

    /// Whether the counters alone would justify an automatic prompt.
    ///
    /// Says nothing about whether *now* is a good moment; that is
    /// `ProjectSupportPromptMoment`.
    var isEligible: Bool {
        guard record.state.allowsAutomaticPrompt,
              record.shownCount < Self.maximumAutomaticPrompts,
              let first = record.firstMeaningfulUseAt else { return false }

        // Negative when the clock has moved back behind the first use, which
        // therefore fails the comparison instead of satisfying it.
        let elapsedDays = calendar.dateComponents([.day], from: first, to: now()).day ?? 0
        guard elapsedDays >= Self.requiredDaysSinceFirstUse,
              record.activeDayCount >= Self.requiredActiveDays,
              record.meaningfulUseCount >= Self.requiredMeaningfulUses else { return false }

        guard let lastPrompt = record.lastPromptAt else { return true }

        // A snooze is two conditions, not one. Sixty days must pass *and* the
        // person must have gone on using Impuls; time alone passing on an app
        // nobody opens is not a reason to ask again.
        let daysSincePrompt = calendar.dateComponents([.day], from: lastPrompt, to: now()).day ?? 0
        guard daysSincePrompt >= Self.snoozeDays else { return false }
        guard let lastUse = record.lastMeaningfulUseAt else { return false }
        return lastUse > lastPrompt
    }

    /// The full decision: earned it, and this is a moment that will not intrude.
    func shouldPresent(in moment: ProjectSupportPromptMoment) -> Bool {
        moment.isQuiet && isEligible
    }

    // MARK: - Outcomes

    /// A prompt has just been put on screen.
    func recordPresented() {
        record.shownCount += 1
        record.lastPromptAt = now()
        persist(durably: true)
    }

    /// The user asked to open the project page and the open was accepted.
    ///
    /// The state is named for what happened. Impuls did not observe a star and
    /// stores no `starred` flag, because it has no way to know and no business
    /// asking GitHub.
    func recordOpenedGitHub() {
        record.state = .openedGitHub
        persist(durably: true)
    }

    /// The user chose feedback; the existing feedback window took over.
    func recordOpenedFeedback() {
        record.state = .openedFeedback
        persist(durably: true)
    }

    /// "Not Now", or the window simply closed. Closing is a decline, not a
    /// postponement of the decision — leaving it undecided would mean asking
    /// again at the next opportunity, which is the nagging this feature avoids.
    func recordDeclined() {
        record.state = record.shownCount >= Self.maximumAutomaticPrompts ? .dismissedForever : .snoozedOnce
        persist(durably: true)
    }

    // MARK: - Opening the project page

    /// Hands the one allow-listed project URL to the user's default browser.
    ///
    /// This is the whole of Impuls's "GitHub integration": no API call, no
    /// OAuth, no token, no request of any kind from the app itself. That is why
    /// the feature does not add a fourth Internet network owner — the browser
    /// makes the request, exactly as it would for a link the user typed.
    ///
    /// The state only advances when the open actually succeeded. A failed open
    /// leaves the prompt as it was, so a browser that could not be launched does
    /// not quietly consume the user's one remaining chance to be asked.
    ///
    /// `open` is injected so the suite can prove both branches without a browser
    /// window appearing on somebody's screen.
    @discardableResult
    func openProjectPage(using open: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
        guard Self.openProjectPageInBrowser(using: open) else { return false }
        recordOpenedGitHub()
        return true
    }

    /// The same hand-off without any prompt bookkeeping.
    ///
    /// Settings offers "Support Impuls on GitHub" permanently, and that path
    /// must keep working after the automatic prompt has ended for good. It is
    /// deliberately stateless: choosing it in Settings is not an answer to a
    /// question Impuls asked, so it neither consumes nor revives the prompt.
    @discardableResult
    static func openProjectPageInBrowser(
        using open: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Bool {
        let url = projectURL
        guard isAllowedProjectURL(url) else { return false }
        return open(url)
    }

    // MARK: - URL

    /// Fail-closed in the same shape as `FeedbackService.isAllowedIssueURL`.
    ///
    /// Credentials, a port or a fragment on a URL that is about to be handed to
    /// the browser are all signs it was not the URL this app meant to open.
    nonisolated static func isAllowedProjectURL(_ url: URL) -> Bool {
        url.scheme == "https"
            && url.host == "github.com"
            && url.path == "/TumanovNV/impuls"
            && url.query == nil
            && url.user == nil
            && url.password == nil
            && url.port == nil
            && url.fragment == nil
    }

    // MARK: - Persistence

    nonisolated private static func load(from defaults: UserDefaults) -> ProjectSupportPromptRecord {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(ProjectSupportPromptRecord.self, from: data) else {
            return .empty
        }
        return decoded
    }

    /// Writes the record, optionally forcing it all the way out.
    ///
    /// `durably` is for the handful of writes that record a *decision* — the
    /// prompt was shown, or the user answered. Those must survive whatever
    /// happens to the process next, because the cap this feature promises is
    /// two appearances for the lifetime of the local state, and a `shownCount`
    /// that never reached disk is a cap that can be exceeded. Impuls is a
    /// menu-bar utility: it gets force-quit, killed by the system and cut off
    /// by a flat battery, and none of those run a graceful termination. Manual
    /// `SUP-01` found exactly this — a decline recorded in memory, the process
    /// killed, and the state on disk still saying the question had never been
    /// asked. Same reasoning as `AppLanguageService`, which forces its flush
    /// because the next process has to read the value.
    ///
    /// Counting a use is deliberately *not* durable. It happens at most once a
    /// minute for the whole life of the install, and losing one only slows
    /// eligibility down — an error in the direction of asking less often, which
    /// is the safe direction for this feature.
    private func persist(durably: Bool = false) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.storageKey)
        if durably { defaults.synchronize() }
    }
}
