import XCTest
@testable import ImpulsCore

final class OnboardingFlowTests: XCTestCase {
    // MARK: - OnboardingEligibility

    func testUpgradeFromAPreviousVersionShowsWhatsNew() {
        let decision = OnboardingEligibility.decision(
            hasSettingsSnapshot: true,
            completedLegacyTour: false,
            completedCurrentTour: true,
            seenVersion: "1.4.13",
            currentVersion: "1.4.14"
        )
        XCTAssertEqual(decision, .whatsNew)
    }

    func testSameVersionSeenAgainShowsNothing() {
        let decision = OnboardingEligibility.decision(
            hasSettingsSnapshot: true,
            completedLegacyTour: false,
            completedCurrentTour: true,
            seenVersion: "1.4.14",
            currentVersion: "1.4.14"
        )
        XCTAssertEqual(decision, .none)
    }

    func testFreshInstallShowsTheFullTourNotWhatsNew() {
        let decision = OnboardingEligibility.decision(
            hasSettingsSnapshot: false,
            completedLegacyTour: false,
            completedCurrentTour: false,
            seenVersion: nil,
            currentVersion: "1.4.14"
        )
        XCTAssertEqual(decision, .full)
    }

    func testFreshInstallThatAlreadyCompletedTheTourShowsNothing() {
        // The full tour was just finished in this same launch; presentIfNeeded
        // must not immediately show it again.
        let decision = OnboardingEligibility.decision(
            hasSettingsSnapshot: false,
            completedLegacyTour: false,
            completedCurrentTour: true,
            seenVersion: "1.4.14",
            currentVersion: "1.4.14"
        )
        XCTAssertEqual(decision, .none)
    }

    // MARK: - WhatsNewCatalog

    func testWhatsNewCatalogReturnsTheCurated1414Content() {
        let content = WhatsNewCatalog.content(forVersion: "1.4.14")
        XCTAssertEqual(content.version, "1.4.14")
        XCTAssertEqual(content.title, localized("What’s new in Impuls %@", "1.4.14"))
        XCTAssertFalse(content.highlights.isEmpty)
        XCTAssertTrue(content.highlights.contains(
            localized("More reliable detection for Magic Keyboard, Magic Mouse and Magic Trackpad.")
        ))
        XCTAssertTrue(content.highlights.contains(
            localized("A new Impuls app icon and Menu Bar glyph.")
        ))
    }

    func testWhatsNewContentNeverMentionsTheOld1411Text() {
        // This is the regression this file exists to guard: 1.4.12 and 1.4.13
        // both kept showing "What's new in Impuls 1.4.11" because the string
        // was hardcoded rather than driven by the catalog/bundle version.
        for version in ["1.4.12", "1.4.13", "1.4.14", "1.4.15"] {
            let content = WhatsNewCatalog.content(forVersion: version)
            XCTAssertFalse(content.title.contains("1.4.11"))
            XCTAssertFalse(content.detail.contains("1.4.11"))
            for highlight in content.highlights {
                XCTAssertFalse(highlight.contains("1.4.11"))
            }
        }
    }

    func testAnUnknownFutureVersionDoesNotInheritThe1414ReleaseNotes() {
        let futureContent = WhatsNewCatalog.content(forVersion: "1.4.15")
        let currentContent = WhatsNewCatalog.content(forVersion: "1.4.14")

        XCTAssertTrue(futureContent.highlights.isEmpty, "An undescribed version gets the generic fallback, not stale copy")
        XCTAssertNotEqual(futureContent.highlights, currentContent.highlights)
        XCTAssertEqual(
            futureContent.detail,
            localized("This update includes reliability and compatibility improvements. See the release notes for the full list.")
        )
    }

    func testWhatsNewTitleAlwaysReflectsTheRequestedVersionNotAFixedOne() {
        XCTAssertEqual(
            WhatsNewCatalog.content(forVersion: "2.0.0").title,
            localized("What’s new in Impuls %@", "2.0.0")
        )
    }
}
