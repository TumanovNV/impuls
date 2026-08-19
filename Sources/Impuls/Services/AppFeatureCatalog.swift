import Foundation

/// The single, local catalogue of capabilities presented by onboarding and
/// the Menu Bar. A feature is only listed after its destination exists in the
/// shipped app; this keeps marketing copy and navigation from drifting apart.
struct AppFeature: Identifiable, Equatable {
    let id: String
    let tab: NotchViewModel.Tab?
    let quickAction: MenuBarQuickAction?
    let titleKey: String
    let detailKey: String
    let symbol: String

    var title: String { tab?.title ?? localized(titleKey) }
    var detail: String { localized(detailKey) }
}

enum AppFeatureCatalog {
    static let all: [AppFeature] = [
        feature(.actions, detail: "Search local snippets, clipboard items and practical conversions."),
        feature(.media, detail: "Control the music source you explicitly selected."),
        feature(.shelf, detail: "Keep files within reach while you work."),
        feature(.clipboard, detail: "Find recent copies locally on this Mac."),
        feature(.snippets, detail: "Keep reusable text close without leaving the panel."),
        feature(.calendar, detail: "See upcoming events after you grant access."),
        feature(.translate, detail: "Translate text when you deliberately open the tool."),
        feature(.notes, detail: "Capture a thought in a local scratchpad."),
        feature(.power, detail: "See honest Mac and opted-in device battery data.")
    ]

    private static let utilities: [AppFeature] = [
        .init(
            id: MenuBarQuickAction.openPanel.rawValue,
            tab: nil,
            quickAction: .openPanel,
            titleKey: "Open Panel",
            detailKey: "Open the Impuls panel.",
            symbol: "rectangle.topthird.inset.filled"
        ),
        .init(
            id: MenuBarQuickAction.showScreenshots.rawValue,
            tab: nil,
            quickAction: .showScreenshots,
            titleKey: "Show Screenshots Folder",
            detailKey: "Reveal the locally stored clipboard screenshots in Finder.",
            symbol: "folder"
        ),
        .init(
            id: MenuBarQuickAction.clearScreenshots.rawValue,
            tab: nil,
            quickAction: .clearScreenshots,
            titleKey: "Clear Screenshots Folder",
            detailKey: "Remove locally stored clipboard screenshots.",
            symbol: "trash"
        )
    ]

    static let quickActions: [MenuBarQuickAction] = utilities.compactMap(\.quickAction) + all.compactMap(\.quickAction)

    static func feature(for action: MenuBarQuickAction) -> AppFeature? {
        (utilities + all).first { $0.quickAction == action }
    }

    private static func feature(_ tab: NotchViewModel.Tab, detail: String) -> AppFeature {
        AppFeature(
            id: tab.rawValue,
            tab: tab,
            quickAction: MenuBarQuickAction(tab: tab),
            titleKey: "",
            detailKey: detail,
            symbol: tab.symbol
        )
    }
}

extension MenuBarQuickAction {
    init?(tab: NotchViewModel.Tab) {
        switch tab {
        case .actions: self = .actions
        case .media: self = .media
        case .shelf: self = .shelf
        case .clipboard: self = .clipboard
        case .snippets: self = .snippets
        case .calendar: self = .calendar
        case .translate: self = .translate
        case .notes: self = .notes
        case .power: self = .power
        }
    }
}
