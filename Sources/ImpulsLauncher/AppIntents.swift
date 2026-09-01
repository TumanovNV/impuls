import AppIntents
import Foundation
import ImpulsCore

private enum IntentStrings {
    static func resource(_ key: StaticString, _ fallback: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(
            key,
            defaultValue: fallback,
            table: "AppIntents",
            locale: Locale.current,
            bundle: Bundle.main,
            comment: nil
        )
    }

    static func text(_ key: String, fallback: String) -> String {
        NSLocalizedString(
            key,
            tableName: "AppIntents",
            bundle: .main,
            value: fallback,
            comment: ""
        )
    }
}

enum ImpulsShortcutModule: String, AppEnum {
    case actions
    case media
    case shelf
    case clipboard
    case snippets
    case calendar
    case translate
    case notes
    case power

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: IntentStrings.resource("Module", "Module")
    )

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .actions: DisplayRepresentation(title: IntentStrings.resource("Actions", "Actions")),
        .media: DisplayRepresentation(title: IntentStrings.resource("Music", "Music")),
        .shelf: DisplayRepresentation(title: IntentStrings.resource("Shelf", "Shelf")),
        .clipboard: DisplayRepresentation(title: IntentStrings.resource("Clipboard", "Clipboard")),
        .snippets: DisplayRepresentation(title: IntentStrings.resource("Snippets", "Snippets")),
        .calendar: DisplayRepresentation(title: IntentStrings.resource("Calendar", "Calendar")),
        .translate: DisplayRepresentation(title: IntentStrings.resource("Translate", "Translate")),
        .notes: DisplayRepresentation(title: IntentStrings.resource("Notes", "Notes")),
        .power: DisplayRepresentation(title: IntentStrings.resource("Power Center", "Power Center"))
    ]

    var runtimeModule: ImpulsAutomationModule {
        switch self {
        case .actions: return .actions
        case .media: return .media
        case .shelf: return .shelf
        case .clipboard: return .clipboard
        case .snippets: return .snippets
        case .calendar: return .calendar
        case .translate: return .translate
        case .notes: return .notes
        case .power: return .power
        }
    }
}

private struct ImpulsIntentFailure: LocalizedError {
    let code: ImpulsAutomationError

    var errorDescription: String? {
        switch code {
        case .moduleUnavailable:
            return IntentStrings.text("The requested module is unavailable.", fallback: "The requested module is unavailable.")
        case .invalidInput:
            return IntentStrings.text("The supplied text is empty or too large.", fallback: "The supplied text is empty or too large.")
        case .operationUnavailable:
            return IntentStrings.text("This operation is currently unavailable.", fallback: "This operation is currently unavailable.")
        case .permissionRequired:
            return IntentStrings.text("Permission is required in Impuls before this operation can run.", fallback: "Permission is required in Impuls before this operation can run.")
        case .serviceUnavailable:
            return IntentStrings.text("Impuls is not ready to perform this action.", fallback: "Impuls is not ready to perform this action.")
        case .unsupportedOperation:
            return IntentStrings.text("This operation is not supported.", fallback: "This operation is not supported.")
        }
    }
}

private func mapAutomationFailure(_ error: Error) -> Error {
    guard let automationError = error as? ImpulsAutomationError else {
        return ImpulsIntentFailure(code: .serviceUnavailable)
    }
    return ImpulsIntentFailure(code: automationError)
}

struct ShowImpulsIntent: AppIntent {
    static let title = IntentStrings.resource("Show Impuls", "Show Impuls")
    static let description = IntentDescription(
        IntentStrings.resource("Open the Impuls panel.", "Open the Impuls panel.")
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        do {
            try await ImpulsAutomationRuntime.shared.show()
            return .result()
        } catch {
            throw mapAutomationFailure(error)
        }
    }
}

struct OpenImpulsModuleIntent: AppIntent {
    static let title = IntentStrings.resource("Open Impuls Module", "Open Impuls Module")
    static let description = IntentDescription(
        IntentStrings.resource("Open a specific module in Impuls.", "Open a specific module in Impuls.")
    )
    static let openAppWhenRun = true

    @Parameter(title: "Module", description: "The Impuls module to open.")
    var module: ImpulsShortcutModule

    init() {}

    init(module: ImpulsShortcutModule) {
        self.module = module
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$module) in Impuls")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        do {
            try await ImpulsAutomationRuntime.shared.open(module: module.runtimeModule)
            return .result()
        } catch {
            throw mapAutomationFailure(error)
        }
    }
}

struct AddTextToImpulsSnippetsIntent: AppIntent {
    static let title = IntentStrings.resource("Add Text to Impuls Snippets", "Add Text to Impuls Snippets")
    static let description = IntentDescription(
        IntentStrings.resource(
            "Save text supplied by the shortcut to Impuls Snippets.",
            "Save text supplied by the shortcut to Impuls Snippets."
        )
    )
    static let openAppWhenRun = false

    @Parameter(title: "Text", description: "Text to save in Snippets.")
    var text: String

    @Parameter(title: "Label", description: "Optional name for the snippet.")
    var label: String?

    init() {}

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to Impuls Snippets")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        do {
            try await ImpulsAutomationRuntime.shared.addSnippet(text: text, label: label)
            return .result()
        } catch {
            throw mapAutomationFailure(error)
        }
    }
}

struct ImpulsAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShowImpulsIntent(),
            phrases: [
                "Show \(.applicationName)",
                "Open \(.applicationName)"
            ],
            shortTitle: IntentStrings.resource("Show Impuls", "Show Impuls"),
            systemImageName: "waveform.path.ecg"
        )

        AppShortcut(
            intent: OpenImpulsModuleIntent(module: .power),
            phrases: ["Open Power Center in \(.applicationName)"],
            shortTitle: IntentStrings.resource("Open Power Center", "Open Power Center"),
            systemImageName: "powerplug.fill"
        )

        AppShortcut(
            intent: OpenImpulsModuleIntent(module: .clipboard),
            phrases: ["Open Clipboard in \(.applicationName)"],
            shortTitle: IntentStrings.resource("Open Clipboard", "Open Clipboard"),
            systemImageName: "list.clipboard.fill"
        )

        AppShortcut(
            intent: OpenImpulsModuleIntent(module: .snippets),
            phrases: ["Open Snippets in \(.applicationName)"],
            shortTitle: IntentStrings.resource("Open Snippets", "Open Snippets"),
            systemImageName: "pin.fill"
        )

        AppShortcut(
            intent: OpenImpulsModuleIntent(module: .shelf),
            phrases: ["Open Shelf in \(.applicationName)"],
            shortTitle: IntentStrings.resource("Open Shelf", "Open Shelf"),
            systemImageName: "tray.full.fill"
        )

        AppShortcut(
            intent: AddTextToImpulsSnippetsIntent(),
            phrases: ["Add text to \(.applicationName) Snippets"],
            shortTitle: IntentStrings.resource("Add Text to Snippets", "Add Text to Snippets"),
            systemImageName: "pin.badge.plus"
        )
    }
}
