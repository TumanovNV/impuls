import Foundation
import XCTest
@testable import ImpulsCore

/// The prompt's whole value is that it stops. These tests are mostly about the
/// stopping: that it does not start early, does not come back after a decline,
/// and cannot reach three appearances by any route.
final class ProjectSupportPromptServiceTests: XCTestCase {
    /// A fixed instant everything is measured from, so no test depends on the
    /// day it runs. UTC keeps `startOfDay` boundaries reproducible on any
    /// machine, and the instant is UTC midnight so that "advance a few hours"
    /// stays inside one calendar day, as the tests below assume.
    private static let epoch = Date(timeIntervalSince1970: 1_699_920_000)

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// A clock the test moves by hand.
    private final class TestClock {
        var current: Date
        init(_ start: Date) { current = start }
        func advance(days: Int = 0, hours: Int = 0, seconds: TimeInterval = 0) {
            current = current
                .addingTimeInterval(TimeInterval(days) * 86_400)
                .addingTimeInterval(TimeInterval(hours) * 3_600)
                .addingTimeInterval(seconds)
        }
    }

    @MainActor
    private func makeService(
        clock: TestClock,
        defaults: UserDefaults
    ) -> ProjectSupportPromptService {
        ProjectSupportPromptService(
            defaults: defaults,
            calendar: Self.utcCalendar,
            now: { clock.current }
        )
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "ProjectSupportPromptServiceTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    /// Records `count` uses spread far enough apart to escape the coalescing
    /// window, one per calendar day.
    @MainActor
    private func useOnConsecutiveDays(
        _ service: ProjectSupportPromptService,
        clock: TestClock,
        days: Int
    ) {
        for _ in 0..<days {
            service.recordMeaningfulUse()
            clock.advance(days: 1)
        }
    }

    /// The moment that always allows a prompt, so state tests are not also
    /// testing the quiet-moment rules.
    private var quietMoment: ProjectSupportPromptMoment {
        ProjectSupportPromptMoment(
            timeSinceLaunch: 600,
            isPanelOpen: false,
            showsAnotherWindow: false,
            isAwaitingLanguageRelaunch: false,
            didPresentInThisSession: false
        )
    }

    // MARK: - Eligibility thresholds

    @MainActor
    func testFreshInstallIsNotEligible() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let service = makeService(clock: clock, defaults: defaults)

        XCTAssertEqual(service.record.state, .neverShown)
        XCTAssertEqual(service.record.meaningfulUseCount, 0)
        XCTAssertNil(service.record.firstMeaningfulUseAt)
        XCTAssertFalse(service.isEligible)
        XCTAssertFalse(service.shouldPresent(in: quietMoment))
    }

    @MainActor
    func testTwentyNineDaysIsNotEnoughEvenWithEveryOtherThresholdMet() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let service = makeService(clock: clock, defaults: defaults)

        // 29 daily uses: 29 active days, 29 uses, but only 28 days elapsed at
        // the last one. Advance to exactly day 29 and check the boundary.
        useOnConsecutiveDays(service, clock: clock, days: 29)
        clock.current = Self.epoch.addingTimeInterval(29 * 86_400)

        XCTAssertGreaterThanOrEqual(service.record.activeDayCount, ProjectSupportPromptService.requiredActiveDays)
        XCTAssertGreaterThanOrEqual(
            service.record.meaningfulUseCount,
            ProjectSupportPromptService.requiredMeaningfulUses
        )
        XCTAssertFalse(service.isEligible, "29 elapsed days must not qualify")

        clock.current = Self.epoch.addingTimeInterval(30 * 86_400)
        XCTAssertTrue(service.isEligible, "the thirtieth day is the boundary")
    }

    @MainActor
    func testEnoughTimeButTooFewActiveDaysIsNotEligible() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let service = makeService(clock: clock, defaults: defaults)

        // Twenty-five uses, all on five calendar days: plenty of uses, plenty of
        // elapsed time, but the app was only reached for on five days. The
        // instants are stated absolutely so the day each one lands on is not a
        // matter of accumulated arithmetic.
        for day in 0..<5 {
            for use in 0..<5 {
                clock.current = Self.epoch
                    .addingTimeInterval(TimeInterval(day) * 86_400 + TimeInterval(use) * 300)
                service.recordMeaningfulUse()
            }
        }
        clock.current = Self.epoch.addingTimeInterval(60 * 86_400)

        XCTAssertEqual(service.record.activeDayCount, 5)
        XCTAssertEqual(service.record.meaningfulUseCount, 25)
        XCTAssertFalse(service.isEligible)
    }

    @MainActor
    func testEnoughTimeAndActiveDaysButTooFewUsesIsNotEligible() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let service = makeService(clock: clock, defaults: defaults)

        // Twelve active days, one use each: past the day thresholds, short of
        // twenty uses.
        useOnConsecutiveDays(service, clock: clock, days: 12)
        clock.current = Self.epoch.addingTimeInterval(60 * 86_400)

        XCTAssertEqual(service.record.activeDayCount, 12)
        XCTAssertEqual(service.record.meaningfulUseCount, 12)
        XCTAssertFalse(service.isEligible)
    }

    @MainActor
    func testAllThreeThresholdsTogetherMakeItEligible() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let service = makeService(clock: clock, defaults: defaults)

        // Ten active days carrying two uses each: 10 days, 20 uses, and enough
        // calendar time afterwards.
        for _ in 0..<10 {
            service.recordMeaningfulUse()
            clock.advance(hours: 2)
            service.recordMeaningfulUse()
            clock.advance(days: 1)
        }
        clock.current = Self.epoch.addingTimeInterval(30 * 86_400)

        XCTAssertEqual(service.record.activeDayCount, 10)
        XCTAssertEqual(service.record.meaningfulUseCount, 20)
        XCTAssertTrue(service.isEligible)
    }

    // MARK: - Counting

    @MainActor
    func testSeveralUsesInOneDayCountAsOneActiveDay() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let service = makeService(clock: clock, defaults: defaults)

        for _ in 0..<6 {
            service.recordMeaningfulUse()
            clock.advance(hours: 1)
        }

        XCTAssertEqual(service.record.activeDayCount, 1)
        XCTAssertEqual(service.record.meaningfulUseCount, 6)
    }

    @MainActor
    func testRapidRepeatsAreOneEpisode() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let service = makeService(clock: clock, defaults: defaults)

        XCTAssertTrue(service.recordMeaningfulUse())
        clock.advance(seconds: 5)
        XCTAssertFalse(service.recordMeaningfulUse(), "a use seconds later is the same episode")
        clock.advance(seconds: 5)
        XCTAssertFalse(service.recordMeaningfulUse())
        XCTAssertEqual(service.record.meaningfulUseCount, 1)

        // The window is anchored to the counted use, so it cannot be slid
        // forward indefinitely by continuing to click.
        clock.advance(seconds: ProjectSupportPromptService.meaningfulUseWindow)
        XCTAssertTrue(service.recordMeaningfulUse())
        XCTAssertEqual(service.record.meaningfulUseCount, 2)
    }

    @MainActor
    func testClockMovingBackwardsNeitherLowersCountersNorGrantsEligibility() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let service = makeService(clock: clock, defaults: defaults)

        useOnConsecutiveDays(service, clock: clock, days: 20)
        clock.current = Self.epoch.addingTimeInterval(40 * 86_400)
        XCTAssertTrue(service.isEligible)

        let daysBefore = service.record.activeDayCount
        let usesBefore = service.record.meaningfulUseCount
        let firstUseBefore = service.record.firstMeaningfulUseAt

        // The Mac's clock jumps back a year.
        clock.current = Self.epoch.addingTimeInterval(-365 * 86_400)
        service.recordMeaningfulUse()

        XCTAssertEqual(service.record.meaningfulUseCount, usesBefore + 1, "counters only ever grow")
        XCTAssertEqual(service.record.activeDayCount, daysBefore, "an earlier day is not a new active day")
        XCTAssertEqual(service.record.firstMeaningfulUseAt, firstUseBefore, "the first use never moves")
        XCTAssertFalse(service.isEligible, "a clock behind the first use cannot satisfy the elapsed-day rule")

        // And the real date returning restores the honest answer.
        clock.current = Self.epoch.addingTimeInterval(40 * 86_400)
        XCTAssertTrue(service.isEligible)
    }

    @MainActor
    func testExistingInstallStartsCountingAtItsFirstUseNotAtInstallTime() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let service = makeService(clock: clock, defaults: defaults)

        // There is no stored record at all — exactly what an install that
        // predates this feature looks like — so day zero is now, not whenever
        // the app was installed.
        XCTAssertNil(service.record.firstMeaningfulUseAt)
        service.recordMeaningfulUse()
        XCTAssertEqual(service.record.firstMeaningfulUseAt, Self.epoch)
        XCTAssertFalse(service.isEligible)
    }

    // MARK: - State machine

    @MainActor
    func testFirstDeclineSnoozesAndSixtyDaysMustPassWithNewActivity() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let service = makeService(clock: clock, defaults: defaults)

        useOnConsecutiveDays(service, clock: clock, days: 20)
        clock.current = Self.epoch.addingTimeInterval(40 * 86_400)
        XCTAssertTrue(service.isEligible)

        service.recordPresented()
        service.recordDeclined()
        XCTAssertEqual(service.record.state, .snoozedOnce)
        XCTAssertEqual(service.record.shownCount, 1)
        XCTAssertFalse(service.isEligible)

        // Halfway through the snooze, with use continuing: still nothing.
        clock.advance(days: 30)
        service.recordMeaningfulUse()
        XCTAssertFalse(service.isEligible)
        XCTAssertFalse(service.shouldPresent(in: quietMoment))

        // Sixty days *and* somebody who kept using Impuls. Both were needed.
        clock.advance(days: 31)
        XCTAssertTrue(service.isEligible, "sixty days plus real activity reopens the second prompt")
    }

    @MainActor
    func testSixtyDaysOfSilenceAloneDoesNotReopenThePrompt() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let service = makeService(clock: clock, defaults: defaults)

        useOnConsecutiveDays(service, clock: clock, days: 20)
        clock.current = Self.epoch.addingTimeInterval(40 * 86_400)
        service.recordPresented()
        service.recordDeclined()

        // Time passes on an app nobody opens. Calendar time is not a reason to
        // ask a second time; coming back to Impuls is.
        clock.advance(days: 400)
        XCTAssertFalse(service.isEligible)

        service.recordMeaningfulUse()
        XCTAssertTrue(service.isEligible)
    }

    @MainActor
    func testSecondDeclineDismissesForever() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let service = makeService(clock: clock, defaults: defaults)

        useOnConsecutiveDays(service, clock: clock, days: 20)
        clock.current = Self.epoch.addingTimeInterval(40 * 86_400)

        service.recordPresented()
        service.recordDeclined()
        XCTAssertEqual(service.record.state, .snoozedOnce)

        clock.advance(days: 61)
        service.recordMeaningfulUse()
        XCTAssertTrue(service.isEligible)

        service.recordPresented()
        service.recordDeclined()
        XCTAssertEqual(service.record.state, .dismissedForever)
        XCTAssertEqual(service.record.shownCount, 2)
    }

    @MainActor
    func testAtMostTwoAutomaticPromptsForTheLifetimeOfTheState() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let service = makeService(clock: clock, defaults: defaults)

        useOnConsecutiveDays(service, clock: clock, days: 20)
        clock.current = Self.epoch.addingTimeInterval(40 * 86_400)

        var presented = 0
        // Ten years of continued, qualifying use, checked every month.
        for _ in 0..<120 {
            clock.advance(days: 30)
            service.recordMeaningfulUse()
            if service.shouldPresent(in: quietMoment) {
                service.recordPresented()
                presented += 1
                service.recordDeclined()
            }
        }

        XCTAssertEqual(presented, ProjectSupportPromptService.maximumAutomaticPrompts)
        XCTAssertEqual(service.record.shownCount, 2)
        XCTAssertEqual(service.record.state, .dismissedForever)
    }

    @MainActor
    func testDismissedForeverNeverBecomesEligibleAgain() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let service = makeService(clock: clock, defaults: defaults)

        useOnConsecutiveDays(service, clock: clock, days: 20)
        clock.current = Self.epoch.addingTimeInterval(40 * 86_400)
        service.recordPresented()
        service.recordDeclined()
        clock.advance(days: 61)
        service.recordMeaningfulUse()
        service.recordPresented()
        service.recordDeclined()
        XCTAssertEqual(service.record.state, .dismissedForever)

        for _ in 0..<40 {
            clock.advance(days: 90)
            service.recordMeaningfulUse()
            XCTAssertFalse(service.isEligible)
            XCTAssertFalse(service.shouldPresent(in: quietMoment))
        }
    }

    @MainActor
    func testOpeningGitHubEndsTheAutomaticPromptForGood() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let service = makeService(clock: clock, defaults: defaults)

        useOnConsecutiveDays(service, clock: clock, days: 20)
        clock.current = Self.epoch.addingTimeInterval(40 * 86_400)
        service.recordPresented()

        var opened: [URL] = []
        XCTAssertTrue(service.openProjectPage(using: { opened.append($0); return true }))

        XCTAssertEqual(opened, [ProjectSupportPromptService.projectURL])
        XCTAssertEqual(service.record.state, .openedGitHub)

        clock.advance(days: 400)
        service.recordMeaningfulUse()
        XCTAssertFalse(service.isEligible)
    }

    @MainActor
    func testChoosingFeedbackEndsTheAutomaticPromptForGood() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let service = makeService(clock: clock, defaults: defaults)

        useOnConsecutiveDays(service, clock: clock, days: 20)
        clock.current = Self.epoch.addingTimeInterval(40 * 86_400)
        service.recordPresented()
        service.recordOpenedFeedback()

        XCTAssertEqual(service.record.state, .openedFeedback)
        clock.advance(days: 400)
        service.recordMeaningfulUse()
        XCTAssertFalse(service.isEligible)
    }

    // MARK: - The project URL

    @MainActor
    func testFailedOpenDoesNotRecordAnOutcome() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let service = makeService(clock: clock, defaults: defaults)

        service.recordPresented()
        XCTAssertFalse(service.openProjectPage(using: { _ in false }))

        XCTAssertEqual(service.record.state, .neverShown, "a browser that did not launch decides nothing")
    }

    func testOnlyTheExactProjectURLIsAllowed() {
        XCTAssertTrue(
            ProjectSupportPromptService.isAllowedProjectURL(ProjectSupportPromptService.projectURL)
        )
        XCTAssertEqual(
            ProjectSupportPromptService.projectURL.absoluteString,
            "https://github.com/TumanovNV/impuls"
        )

        let rejected = [
            "http://github.com/TumanovNV/impuls",
            "https://github.com/TumanovNV/impuls/stargazers",
            "https://github.com/TumanovNV/impuls-evil",
            "https://github.com.example.com/TumanovNV/impuls",
            "https://api.github.com/TumanovNV/impuls",
            "https://user:secret@github.com/TumanovNV/impuls",
            "https://github.com:8443/TumanovNV/impuls",
            "https://github.com/TumanovNV/impuls?utm_source=impuls",
            "https://github.com/TumanovNV/impuls#readme",
        ]
        for candidate in rejected {
            guard let url = URL(string: candidate) else { continue }
            XCTAssertFalse(
                ProjectSupportPromptService.isAllowedProjectURL(url),
                "\(candidate) must not be openable"
            )
        }
    }

    // MARK: - Voluntary support URLs

    func testVoluntarySupportDestinationHasExactlyTwoCases() {
        XCTAssertEqual(VoluntarySupportDestination.allCases, [.cloudTips, .boosty])
    }

    func testExactVoluntarySupportURLsAreAllowed() throws {
        let cloudTips = try XCTUnwrap(VoluntarySupportDestination.cloudTips.url)
        let boosty = try XCTUnwrap(VoluntarySupportDestination.boosty.url)

        XCTAssertEqual(cloudTips.absoluteString, "https://pay.cloudtips.ru/p/e04ac53f")
        XCTAssertEqual(boosty.absoluteString, "https://boosty.to/tumanovnv/donate")
        XCTAssertTrue(ProjectSupportPromptService.isAllowedVoluntarySupportURL(cloudTips))
        XCTAssertTrue(ProjectSupportPromptService.isAllowedVoluntarySupportURL(boosty))
    }

    func testHTTPCloudTipsURLIsRejected() {
        assertVoluntarySupportURLRejected("http://pay.cloudtips.ru/p/e04ac53f")
    }

    func testWrongCloudTipsPathIsRejected() {
        assertVoluntarySupportURLRejected("https://pay.cloudtips.ru/p/different")
    }

    func testWrongBoostyProfileIsRejected() {
        assertVoluntarySupportURLRejected("https://boosty.to/another-profile/donate")
    }

    func testLookalikeVoluntarySupportHostIsRejected() {
        assertVoluntarySupportURLRejected("https://pay.cloudtips.ru.example.com/p/e04ac53f")
    }

    func testVoluntarySupportURLWithCredentialsIsRejected() {
        assertVoluntarySupportURLRejected("https://user:secret@pay.cloudtips.ru/p/e04ac53f")
    }

    func testVoluntarySupportURLWithCustomPortIsRejected() {
        assertVoluntarySupportURLRejected("https://boosty.to:8443/tumanovnv/donate")
    }

    func testVoluntarySupportURLWithQueryIsRejected() {
        assertVoluntarySupportURLRejected("https://pay.cloudtips.ru/p/e04ac53f?redirect=https://example.com")
    }

    func testVoluntarySupportURLWithFragmentIsRejected() {
        assertVoluntarySupportURLRejected("https://boosty.to/tumanovnv/donate#support")
    }

    func testArbitraryVoluntarySupportURLIsRejected() {
        assertVoluntarySupportURLRejected("https://example.com/support")
    }

    @MainActor
    func testEachVoluntarySupportActionOpensItsExactURL() {
        var opened: [URL] = []

        XCTAssertTrue(ProjectSupportPromptService.openVoluntarySupportPage(
            .cloudTips,
            using: { opened.append($0); return true }
        ))
        XCTAssertTrue(ProjectSupportPromptService.openVoluntarySupportPage(
            .boosty,
            using: { opened.append($0); return true }
        ))

        XCTAssertEqual(opened.map(\.absoluteString), [
            "https://pay.cloudtips.ru/p/e04ac53f",
            "https://boosty.to/tumanovnv/donate",
        ])
    }

    @MainActor
    func testFailedVoluntarySupportOpenerReturnsFalse() {
        XCTAssertFalse(ProjectSupportPromptService.openVoluntarySupportPage(.cloudTips, using: { _ in false }))
    }

    @MainActor
    func testVoluntarySupportActionDoesNotChangePromptRecord() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let service = makeService(clock: clock, defaults: defaults)
        service.recordMeaningfulUse()
        let recordBeforeOpen = service.record

        XCTAssertTrue(ProjectSupportPromptService.openVoluntarySupportPage(.cloudTips, using: { _ in true }))
        XCTAssertTrue(ProjectSupportPromptService.openVoluntarySupportPage(.boosty, using: { _ in true }))

        XCTAssertEqual(service.record, recordBeforeOpen)
    }

    private func assertVoluntarySupportURLRejected(
        _ candidate: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let url = URL(string: candidate) else {
            return XCTFail("invalid test URL: \(candidate)", file: file, line: line)
        }
        XCTAssertFalse(
            ProjectSupportPromptService.isAllowedVoluntarySupportURL(url),
            "\(candidate) must not be openable",
            file: file,
            line: line
        )
    }

    // MARK: - Quiet moment

    func testEveryBadMomentBlocksThePrompt() {
        var moment = ProjectSupportPromptMoment(
            timeSinceLaunch: 600,
            isPanelOpen: false,
            showsAnotherWindow: false,
            isAwaitingLanguageRelaunch: false,
            didPresentInThisSession: false
        )
        XCTAssertTrue(moment.isQuiet)

        moment.timeSinceLaunch = ProjectSupportPromptService.minimumUptimeBeforePrompt - 1
        XCTAssertFalse(moment.isQuiet, "launch is never the moment")
        moment.timeSinceLaunch = 600

        moment.isPanelOpen = true
        XCTAssertFalse(moment.isQuiet, "the user is working in the panel")
        moment.isPanelOpen = false

        // Onboarding, What's New, Settings, Feedback and Sparkle dialogs all
        // arrive through this one flag.
        moment.showsAnotherWindow = true
        XCTAssertFalse(moment.isQuiet)
        moment.showsAnotherWindow = false

        moment.isAwaitingLanguageRelaunch = true
        XCTAssertFalse(moment.isQuiet, "the app is about to restart itself")
        moment.isAwaitingLanguageRelaunch = false

        moment.didPresentInThisSession = true
        XCTAssertFalse(moment.isQuiet, "one prompt per session, whatever else happens")
    }

    @MainActor
    func testAnEligibleServiceStillWaitsForAQuietMoment() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let service = makeService(clock: clock, defaults: defaults)

        useOnConsecutiveDays(service, clock: clock, days: 20)
        clock.current = Self.epoch.addingTimeInterval(40 * 86_400)
        XCTAssertTrue(service.isEligible)

        var busy = quietMoment
        busy.isPanelOpen = true
        XCTAssertFalse(service.shouldPresent(in: busy))
        XCTAssertTrue(service.shouldPresent(in: quietMoment))
    }

    /// Counts flush requests. A unit test cannot observe whether a write
    /// survived this process being killed — that needs a second process, and it
    /// is what manual `SUP-01` is for. What it *can* pin is that the service
    /// asks for the flush on the writes that record a decision, and does not on
    /// the one that merely counts use.
    ///
    /// Reading `persistentDomain` instead would prove nothing: it resolves
    /// through the same in-process CFPreferences cache that held the lost
    /// decline in the first place, so it answers yes either way.
    private final class FlushCountingDefaults: UserDefaults {
        private(set) var flushes = 0

        override func synchronize() -> Bool {
            flushes += 1
            return super.synchronize()
        }
    }

    @MainActor
    func testEveryDecisionAsksToBeFlushedAtTheMomentItIsMade() throws {
        // Found by manual SUP-01: the decline lived in the in-process cache, the
        // process was killed without a graceful termination, and the state on
        // disk still said the question had never been asked. A `shownCount` that
        // can be lost is a two-appearance cap that can be exceeded.
        let suite = "ProjectSupportPromptServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(FlushCountingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let service = ProjectSupportPromptService(
            defaults: defaults,
            calendar: Self.utcCalendar,
            now: { clock.current }
        )

        useOnConsecutiveDays(service, clock: clock, days: 20)
        clock.current = Self.epoch.addingTimeInterval(40 * 86_400)
        let afterCountingUses = defaults.flushes

        service.recordPresented()
        XCTAssertEqual(defaults.flushes, afterCountingUses + 1, "the prompt appearing is a decision")

        service.recordDeclined()
        XCTAssertEqual(defaults.flushes, afterCountingUses + 2, "a decline is a decision")

        service.recordOpenedFeedback()
        XCTAssertEqual(defaults.flushes, afterCountingUses + 3)

        service.recordOpenedGitHub()
        XCTAssertEqual(defaults.flushes, afterCountingUses + 4, "a terminal outcome is a decision")
    }

    @MainActor
    func testCountingAUseIsNotForcedToDisk() throws {
        // Stated so it is not "fixed" later by making every write durable: this
        // runs up to once a minute for the life of the install, and losing one
        // only delays eligibility — an error in the direction of asking less
        // often, which is the safe direction for this feature.
        let suite = "ProjectSupportPromptServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(FlushCountingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let service = ProjectSupportPromptService(
            defaults: defaults,
            calendar: Self.utcCalendar,
            now: { clock.current }
        )

        for _ in 0..<25 {
            service.recordMeaningfulUse()
            clock.advance(days: 1)
        }

        XCTAssertEqual(service.record.meaningfulUseCount, 25, "still recorded, just not flushed")
        XCTAssertEqual(defaults.flushes, 0, "counting use must not force a disk write")
    }

    @MainActor
    func testNewServiceReloadsRecordedDeclineAndDoesNotPresent() throws {
        // Sequential, not concurrent: the second service is built *after* the
        // first recorded its outcome, which is the real shape of the question —
        // production has one service, owned by AppDelegate, and the state it
        // must not contradict is the one already on disk. Two live instances
        // sharing a preloaded record is not a case this models, and it is not a
        // case worth building cross-process locking for.
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let first = makeService(clock: clock, defaults: defaults)

        useOnConsecutiveDays(first, clock: clock, days: 20)
        clock.current = Self.epoch.addingTimeInterval(40 * 86_400)
        XCTAssertTrue(first.shouldPresent(in: quietMoment))
        first.recordPresented()
        first.recordDeclined()

        let second = makeService(clock: clock, defaults: defaults)
        XCTAssertEqual(second.record.shownCount, 1)
        XCTAssertEqual(second.record.state, .snoozedOnce)
        XCTAssertFalse(second.shouldPresent(in: quietMoment))
    }

    // MARK: - Persistence

    @MainActor
    func testStateSurvivesRelaunch() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let first = makeService(clock: clock, defaults: defaults)

        useOnConsecutiveDays(first, clock: clock, days: 20)
        clock.current = Self.epoch.addingTimeInterval(40 * 86_400)
        first.recordPresented()
        first.recordDeclined()

        // A new process reading the same defaults.
        let second = makeService(clock: clock, defaults: defaults)
        XCTAssertEqual(second.record, first.record)
        XCTAssertEqual(second.record.activeDayCount, 20)
        XCTAssertEqual(second.record.meaningfulUseCount, 20)
        XCTAssertEqual(second.record.state, .snoozedOnce)
    }

    @MainActor
    func testStateIsNotPartOfThePortableSettingsSnapshot() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Self.epoch)
        let service = makeService(clock: clock, defaults: defaults)
        service.recordMeaningfulUse()
        service.recordPresented()

        // It is written, and it is written somewhere a backup does not look.
        XCTAssertNotNil(defaults.data(forKey: ProjectSupportPromptService.storageKey))

        let settings = SettingsStore(defaults: defaults)
        let snapshot = settings.snapshot
        let encoded = try XCTUnwrap(String(data: try JSONEncoder().encode(snapshot), encoding: .utf8))

        for field in ["projectSupport", "shownCount", "meaningfulUse", "activeDay", "firstMeaningfulUseAt"] {
            XCTAssertFalse(encoded.contains(field), "\(field) must not travel in an exported backup")
        }
    }

    @MainActor
    func testUnknownStoredStateFailsClosed() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        // A blob from a build that knows a state this one does not.
        let forged = """
        {"activeDayCount":99,"meaningfulUseCount":99,"shownCount":0,"state":"someFutureState"}
        """
        defaults.set(Data(forged.utf8), forKey: ProjectSupportPromptService.storageKey)

        let clock = TestClock(Self.epoch)
        let service = makeService(clock: clock, defaults: defaults)
        XCTAssertEqual(service.record.state, .dismissedForever, "an unreadable decision is not permission to ask")
        XCTAssertFalse(service.isEligible)
    }

    @MainActor
    func testCorruptStoredBlobDegradesToAFreshRecord() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json at all".utf8), forKey: ProjectSupportPromptService.storageKey)

        let clock = TestClock(Self.epoch)
        let service = makeService(clock: clock, defaults: defaults)
        XCTAssertEqual(service.record, .empty)
        XCTAssertFalse(service.isEligible)
    }
}
