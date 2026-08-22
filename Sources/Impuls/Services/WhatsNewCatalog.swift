import Foundation

/// Central source of "What's new" content, keyed by the exact running
/// `CFBundleShortVersionString`.
///
/// Before this existed, `OnboardingFlow` had 1.4.11's headline and copy typed
/// directly into its view body. Every later release kept showing that same
/// text because nothing forced the string to track `Bundle.main.shortVersion`,
/// so 1.4.12 and 1.4.13 both greeted upgraders with stale 1.4.11 notes. Adding
/// an entry here for a new version is now the only change a release needs; a
/// version with no entry gets `fallback`, never a previous version's copy.
enum WhatsNewCatalog {
    struct Content: Equatable {
        let version: String
        let title: String
        let detail: String
        let highlights: [String]
    }

    static func content(forVersion version: String) -> Content {
        let title = localized("What’s new in Impuls %@", version)
        guard let highlights = releaseHighlights[version] else {
            return Content(
                version: version,
                title: title,
                detail: localized(
                    "This update includes reliability and compatibility improvements. See the release notes for the full list."
                ),
                highlights: []
            )
        }
        return Content(
            version: version,
            title: title,
            detail: localized("Here’s what changed in this update:"),
            highlights: highlights
        )
    }

    /// Keyed by the exact version it describes. Internal implementation/security
    /// details are deliberately left out — this is user-facing copy.
    private static let releaseHighlights: [String: [String]] = [
        "1.4.15": [
            localized("Impuls follows the macOS language unless you choose one here."),
            localized("The selected language will be applied after Impuls restarts."),
            localized("Impuls is developed in the open. A star on GitHub helps other people find it, and your feedback shapes what comes next."),
            localized("General reliability and compatibility improvements."),
        ],
        "1.4.14": [
            localized("A redesigned Power Center with a device navigator and real details for every connected Mac, iPhone and iPad."),
            localized("More reliable detection for Magic Keyboard, Magic Mouse and Magic Trackpad."),
            localized("Clearer status for the Apple devices connected to this Mac."),
            localized("A new Impuls app icon and Menu Bar glyph."),
            localized("General reliability and compatibility improvements."),
        ],
    ]
}
