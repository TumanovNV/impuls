import Foundation
import XCTest
@testable import ImpulsCore

final class FeedbackServiceTests: XCTestCase {
    private let diagnostics = FeedbackDiagnostics(
        appVersion: "1.2.4",
        macOSVersion: "15.6.1",
        architecture: "Apple Silicon"
    )

    func testSubmissionIsStructuredAndUsesOnlyAllowedIssueEndpoint() throws {
        let submission = try XCTUnwrap(FeedbackService.makeSubmission(
            draft: FeedbackDraft(
                category: .problem,
                area: .wholeApp,
                frequency: .often,
                rating: 2,
                summary: "  Panel does not close\nafter typing  ",
                details: "It happens every time.",
                includeDiagnostics: true
            ),
            diagnostics: diagnostics
        ))

        XCTAssertTrue(FeedbackService.isAllowedIssueURL(submission.issueURL))
        XCTAssertTrue(submission.reportIncludedInURL)
        XCTAssertTrue(submission.report.contains("Category: problem"))
        XCTAssertTrue(submission.report.contains("Area: wholeApp"))
        XCTAssertTrue(submission.report.contains("Frequency: often"))
        XCTAssertTrue(submission.report.contains("Rating: 2/5"))
        XCTAssertTrue(submission.report.contains("Impuls: 1.2.4"))

        let components = try XCTUnwrap(URLComponents(url: submission.issueURL, resolvingAgainstBaseURL: false))
        let title = components.queryItems?.first(where: { $0.name == "title" })?.value
        XCTAssertEqual(title, "[Problem] Panel does not close after typing")
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "labels" })?.value,
            "bug"
        )
    }

    func testDiagnosticsCanBeExcludedCompletely() throws {
        let submission = try XCTUnwrap(FeedbackService.makeSubmission(
            draft: FeedbackDraft(
                category: .idea,
                area: .actions,
                frequency: .everyDay,
                rating: 0,
                summary: "Faster search",
                details: "",
                includeDiagnostics: false
            ),
            diagnostics: diagnostics
        ))

        XCTAssertTrue(submission.report.contains("Rating: not specified"))
        XCTAssertFalse(submission.report.contains("Technical context"))
        XCTAssertFalse(submission.report.contains("15.6.1"))
    }

    func testLongReportFallsBackToClipboardFriendlyIssueURL() throws {
        let submission = try XCTUnwrap(FeedbackService.makeSubmission(
            draft: FeedbackDraft(
                category: .impression,
                area: .wholeApp,
                frequency: .sometimes,
                rating: 5,
                summary: "Отзыв",
                details: String(repeating: "я", count: FeedbackService.maximumDetailsLength),
                includeDiagnostics: true
            ),
            diagnostics: diagnostics
        ))

        XCTAssertFalse(submission.reportIncludedInURL)
        XCTAssertNil(URLComponents(url: submission.issueURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "body" }))
        XCTAssertTrue(submission.report.contains(String(repeating: "я", count: 100)))
    }

    func testEmptySummaryCannotCreateSubmission() {
        XCTAssertNil(FeedbackService.makeSubmission(
            draft: FeedbackDraft(
                category: .problem,
                area: .settings,
                frequency: .once,
                rating: 1,
                summary: "   \n ",
                details: "Details",
                includeDiagnostics: true
            ),
            diagnostics: diagnostics
        ))
    }

    func testLookalikeGitHubURLIsRejected() throws {
        XCTAssertFalse(FeedbackService.isAllowedIssueURL(
            try XCTUnwrap(URL(string: "https://github.com.evil.example/TumanovNV/impuls/issues/new"))
        ))
        XCTAssertFalse(FeedbackService.isAllowedIssueURL(
            try XCTUnwrap(URL(string: "https://github.com/TumanovNV/other/issues/new"))
        ))
        XCTAssertFalse(FeedbackService.isAllowedIssueURL(
            try XCTUnwrap(URL(string: "https://attacker@github.com/TumanovNV/impuls/issues/new"))
        ))
    }
}
