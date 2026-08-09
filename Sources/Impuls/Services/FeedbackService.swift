import AppKit
import Foundation

enum FeedbackCategory: String, CaseIterable, Identifiable, Sendable {
    case problem
    case idea
    case impression

    var id: String { rawValue }

    var title: String {
        switch self {
        case .problem: return localized("Problem")
        case .idea: return localized("Feature Idea")
        case .impression: return localized("General Feedback")
        }
    }

    var issuePrefix: String {
        switch self {
        case .problem: return "Problem"
        case .idea: return "Idea"
        case .impression: return "Feedback"
        }
    }

    var issueLabel: String? {
        switch self {
        case .problem: return "bug"
        case .idea: return "enhancement"
        case .impression: return nil
        }
    }
}

enum FeedbackArea: String, CaseIterable, Identifiable, Sendable {
    case wholeApp
    case actions
    case shelf
    case clipboard
    case calendar
    case media
    case translate
    case notesAndSnippets
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wholeApp: return localized("Whole App")
        case .actions: return localized("Actions")
        case .shelf: return localized("Shelf")
        case .clipboard: return localized("Clipboard")
        case .calendar: return localized("Calendar")
        case .media: return localized("Music")
        case .translate: return localized("Translate")
        case .notesAndSnippets: return localized("Notes and Snippets")
        case .settings: return localized("Settings")
        }
    }
}

enum FeedbackFrequency: String, CaseIterable, Identifiable, Sendable {
    case notSpecified
    case once
    case sometimes
    case often
    case everyDay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notSpecified: return localized("Not Specified")
        case .once: return localized("Once or Rarely")
        case .sometimes: return localized("Sometimes")
        case .often: return localized("Often")
        case .everyDay: return localized("Every Day")
        }
    }
}

struct FeedbackDiagnostics: Equatable, Sendable {
    let appVersion: String
    let macOSVersion: String
    let architecture: String

    static var current: FeedbackDiagnostics {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let macOSVersion = [version.majorVersion, version.minorVersion, version.patchVersion]
            .map(String.init)
            .joined(separator: ".")
        #if arch(arm64)
        let architecture = "Apple Silicon"
        #elseif arch(x86_64)
        let architecture = "Intel"
        #else
        let architecture = "Unknown"
        #endif
        return FeedbackDiagnostics(
            appVersion: Bundle.main.shortVersion,
            macOSVersion: macOSVersion,
            architecture: architecture
        )
    }

    var markdown: String {
        """
        - Impuls: \(appVersion)
        - macOS: \(macOSVersion)
        - Architecture: \(architecture)
        """
    }
}

struct FeedbackDraft: Equatable, Sendable {
    var category: FeedbackCategory
    var area: FeedbackArea
    var frequency: FeedbackFrequency
    var rating: Int
    var summary: String
    var details: String
    var includeDiagnostics: Bool
}

struct FeedbackSubmission: Equatable, Sendable {
    let report: String
    let issueURL: URL
    let reportIncludedInURL: Bool
}

enum FeedbackService {
    static let maximumSummaryLength = 120
    static let maximumDetailsLength = 4_000
    static let maximumPrefilledURLLength = 7_000

    private static let issueBaseURL = URL(string: "https://github.com/TumanovNV/impuls/issues/new")!

    static func makeSubmission(
        draft: FeedbackDraft,
        diagnostics: FeedbackDiagnostics = .current
    ) -> FeedbackSubmission? {
        let summary = normalized(draft.summary, limit: maximumSummaryLength, singleLine: true)
        guard !summary.isEmpty else { return nil }
        let details = normalized(draft.details, limit: maximumDetailsLength, singleLine: false)
        let report = makeReport(
            category: draft.category,
            area: draft.area,
            frequency: draft.frequency,
            rating: draft.rating,
            summary: summary,
            details: details,
            diagnostics: draft.includeDiagnostics ? diagnostics : nil
        )
        let title = "[\(draft.category.issuePrefix)] \(summary)"

        if let url = issueURL(title: title, body: report, label: draft.category.issueLabel),
           url.absoluteString.count <= maximumPrefilledURLLength {
            return FeedbackSubmission(report: report, issueURL: url, reportIncludedInURL: true)
        }
        guard let url = issueURL(title: title, body: nil, label: draft.category.issueLabel) else { return nil }
        return FeedbackSubmission(report: report, issueURL: url, reportIncludedInURL: false)
    }

    @MainActor
    static func copyReport(_ report: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(Data(), forType: .impulsInternal)
        pasteboard.setString(report, forType: .string)
    }

    @discardableResult
    @MainActor
    static func open(_ submission: FeedbackSubmission) -> Bool {
        guard isAllowedIssueURL(submission.issueURL) else { return false }
        copyReport(submission.report)
        return NSWorkspace.shared.open(submission.issueURL)
    }

    static func isAllowedIssueURL(_ url: URL) -> Bool {
        url.scheme == "https"
            && url.host == "github.com"
            && url.path == "/TumanovNV/impuls/issues/new"
            && url.user == nil
            && url.password == nil
            && url.port == nil
            && url.fragment == nil
    }

    private static func makeReport(
        category: FeedbackCategory,
        area: FeedbackArea,
        frequency: FeedbackFrequency,
        rating: Int,
        summary: String,
        details: String,
        diagnostics: FeedbackDiagnostics?
    ) -> String {
        var sections = [
            "<!-- impuls-feedback:v1 -->",
            "## Feedback",
            "- Category: \(category.rawValue)",
            "- Area: \(area.rawValue)",
            "- Frequency: \(frequency.rawValue)",
            "- Rating: \((1...5).contains(rating) ? \"\(rating)/5\" : \"not specified\")",
            "",
            "## Summary",
            summary,
        ]
        if !details.isEmpty {
            sections += ["", "## Details", details]
        }
        if let diagnostics {
            sections += ["", "## Technical context", diagnostics.markdown]
        }
        sections += [
            "",
            "_Created explicitly by the user in Impuls. No clipboard contents, notes, file names, file paths, calendar data, device identifiers, or logs were added automatically._",
        ]
        return sections.joined(separator: "\n")
    }

    private static func issueURL(title: String, body: String?, label: String?) -> URL? {
        var components = URLComponents(url: issueBaseURL, resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "title", value: title)]
        if let body { queryItems.append(URLQueryItem(name: "body", value: body)) }
        if let label { queryItems.append(URLQueryItem(name: "labels", value: label)) }
        components?.queryItems = queryItems
        guard let url = components?.url, isAllowedIssueURL(url) else { return nil }
        return url
    }

    private static func normalized(_ value: String, limit: Int, singleLine: Bool) -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if singleLine {
            value = value
                .components(separatedBy: .newlines)
                .joined(separator: " ")
                .replacingOccurrences(of: "  ", with: " ")
        }
        return String(value.prefix(limit))
    }
}
