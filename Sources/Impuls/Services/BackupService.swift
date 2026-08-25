import AppKit
import UniformTypeIdentifiers

struct ImpulsBackupDocument: Codable, Equatable {
    static let currentSchemaVersion = 2
    static let supportedSchemaVersions = 1...currentSchemaVersion
    static let maximumEncodedBytes = 10 * 1_024 * 1_024

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
        guard data.count <= maximumEncodedBytes else { throw BackupError.fileTooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ImpulsBackupDocument.self, from: data)
        guard supportedSchemaVersions.contains(document.schemaVersion) else {
            throw BackupError.unsupportedSchema(document.schemaVersion)
        }
        guard document.notes.count <= 5_000, document.snippets.count <= 5_000 else {
            throw BackupError.tooManyItems
        }
        return document
    }
}

enum BackupError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case fileTooLarge
    case tooManyItems
    case unsupportedFileType

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return localized("This backup format is not supported (version %d).", version)
        case .fileTooLarge:
            return localized("The selected backup is larger than 10 MB.")
        case .tooManyItems:
            return localized("The selected backup contains too many notes or snippets.")
        case .unsupportedFileType:
            return localized("The selected item is not a regular file.")
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
            // Same reason as the import side: this closure runs on the main
            // actor, and encoding up to 10 MB of JSON and writing it to a
            // volume that may be slow or remote is not work the UI thread
            // should be doing. Only the failure alert comes back here.
            Task { @MainActor in
                do {
                    try await store(document, to: url)
                } catch {
                    showError(localized("Could Not Export Data"), error: error, window: window)
                }
            }
        }
    }

    /// Runs the blocking part of an export off the main actor.
    ///
    /// `Task.detached` for the same reason as `loadDocument(at:)`: in Swift 5
    /// language mode a plain `Task { }` started from a main-actor context is
    /// not guaranteed to leave it, which would move nothing.
    private static func store(_ document: ImpulsBackupDocument, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try write(document, to: url)
        }.value
    }

    /// Encodes and writes a backup. `nonisolated` so it cannot be pulled back
    /// onto the main actor by the enclosing annotation.
    ///
    /// The encoder settings and `.atomic` are unchanged: the file format, key
    /// order and replace-or-nothing write semantics are exactly what they were.
    nonisolated static func write(_ document: ImpulsBackupDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    static func importData(from window: NSWindow?, completion: @escaping (ImpulsBackupDocument) -> Void) {
        let panel = NSOpenPanel()
        panel.title = localized("Import Impuls Data")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        begin(panel, from: window) { response in
            guard response == .OK, let url = panel.url else { return }
            // The panel hands back a path, not a promise that reading it is
            // quick. A network volume that has stopped answering, or a file
            // being written by another process, makes the read take as long as
            // the filesystem wants — and this closure runs on the main actor,
            // so doing it here is what froze the UI. Everything up to and
            // including the decode now happens off the main actor; only the
            // alert and the completion come back to it.
            Task { @MainActor in
                do {
                    let document = try await loadDocument(at: url)
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
    }

    /// Runs the blocking part of an import off the main actor.
    ///
    /// `Task.detached` rather than a plain `Task`: this target builds in Swift 5
    /// language mode, where an unstructured `Task { }` started from a main-actor
    /// context is not guaranteed to leave that actor — which would move the
    /// blocking read nowhere at all. Detaching states the boundary instead of
    /// inferring it, and matches how `FileToolsCoordinator` already gets file
    /// work off the main actor.
    ///
    /// `ImpulsBackupDocument` is a tree of value types, so it is already
    /// implicitly `Sendable` and crosses back without any `@unchecked` help.
    private static func loadDocument(at url: URL) async throws -> ImpulsBackupDocument {
        try await Task.detached(priority: .userInitiated) {
            try decode(contentsOf: url)
        }.value
    }

    /// Reads and decodes a backup. `nonisolated`, so it never runs on the main
    /// actor merely because `BackupService` is annotated with it — the whole
    /// point of this path is that it must not.
    nonisolated static func decode(contentsOf url: URL) throws -> ImpulsBackupDocument {
        let data: Data
        do {
            data = try BoundedFileReader.read(
                from: url,
                maximumBytes: ImpulsBackupDocument.maximumEncodedBytes
            )
        } catch BoundedDataError.limitExceeded {
            throw BackupError.fileTooLarge
        } catch BoundedDataError.notARegularFile {
            throw BackupError.unsupportedFileType
        }
        return try ImpulsBackupDocument.decode(data)
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
