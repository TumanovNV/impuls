import AppKit
import UniformTypeIdentifiers

struct ImpulsBackupDocument: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let createdAt: Date
    let appVersion: String
    let settings: ImpulsSettingsSnapshot
    let snippets: [Snippet]
    let notes: [Note]

    init(
        createdAt: Date = Date(),
        appVersion: String = Bundle.main.shortVersion,
        settings: ImpulsSettingsSnapshot,
        snippets: [Snippet],
        notes: [Note]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.settings = settings
        self.snippets = snippets
        self.notes = notes
    }

    static func decode(_ data: Data) throws -> ImpulsBackupDocument {
        guard data.count <= 10 * 1_024 * 1_024 else { throw BackupError.fileTooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ImpulsBackupDocument.self, from: data)
        guard document.schemaVersion == currentSchemaVersion else {
            throw BackupError.unsupportedSchema(document.schemaVersion)
        }
        guard document.notes.count <= 5_000, document.snippets.count <= 5_000 else {
            throw BackupError.tooManyItems
        }
        return document
    }
}

enum BackupError: LocalizedError {
    case unsupportedSchema(Int)
    case fileTooLarge
    case tooManyItems

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return localized("This backup format is not supported (version %d).", version)
        case .fileTooLarge:
            return localized("The selected backup is larger than 10 MB.")
        case .tooManyItems:
            return localized("The selected backup contains too many notes or snippets.")
        }
    }
}

@MainActor
enum BackupService {
    static func export(_ document: ImpulsBackupDocument, from window: NSWindow?) {
        let panel = NSSavePanel()
        panel.title = localized("Export Impuls Data")
        panel.nameFieldStringValue = "Impuls-backup-\(dateStamp()).json"
        panel.allowedContentTypes = [.json]
        begin(panel, from: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(document).write(to: url, options: .atomic)
            } catch {
                showError(localized("Could Not Export Data"), error: error, window: window)
            }
        }
    }

    static func importData(from window: NSWindow?, completion: @escaping (ImpulsBackupDocument) -> Void) {
        let panel = NSOpenPanel()
        panel.title = localized("Import Impuls Data")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        begin(panel, from: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let document = try decode(contentsOf: url)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = localized("Replace Current Impuls Data?")
                alert.informativeText = localized("Settings, snippets, and notes will be replaced by the selected backup. A new export can preserve the current data first.")
                alert.addButton(withTitle: localized("Import and Replace"))
                alert.addButton(withTitle: localized("Cancel"))
                present(alert, from: window) { result in
                    guard result == .alertFirstButtonReturn else { return }
                    completion(document)
                }
            } catch {
                showError(localized("Could Not Import Data"), error: error, window: window)
            }
        }
    }

    static func decode(contentsOf url: URL) throws -> ImpulsBackupDocument {
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > 10 * 1_024 * 1_024 {
            throw BackupError.fileTooLarge
        }
        return try ImpulsBackupDocument.decode(Data(contentsOf: url))
    }

    private static func begin(_ panel: NSSavePanel, from window: NSWindow?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private static func present(_ alert: NSAlert, from window: NSWindow?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private static func showError(_ title: String, error: Error, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: localized("OK"))
        present(alert, from: window) { _ in }
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
