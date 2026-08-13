import AppKit

struct Snippet: Identifiable, Codable, Equatable {
    /// Compact, process-stable identity. The previous computed ID returned the
    /// full snippet text when no label existed, making SwiftUI repeatedly hash
    /// up to the entire 10 MB store merely to diff a row.
    let id: String
    /// Optional name. Without one the row shows the value itself, which is
    /// usually enough for an address or a phone number.
    let label: String
    let text: String

    private enum CodingKeys: String, CodingKey { case label, text }

    init(label: String = "", text: String) {
        self.id = Self.makeIdentifier(label: label, text: text)
        self.label = label
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        let text = try container.decode(String.self, forKey: .text)
        self.init(label: label, text: text)
    }

    var displayLabel: String {
        BoundedText.firstLine(label, maximumCharacters: 160)
    }

    var preview: String {
        BoundedText.firstLine(text, maximumCharacters: 240)
    }

    /// Guessed from the value, so a row is recognisable before it is read.
    var symbol: String {
        let value = BoundedText.firstLine(text, maximumCharacters: 512)
        if value.contains("@"), !value.contains(" ") { return "at" }
        if value.hasPrefix("http://") || value.hasPrefix("https://") { return "link" }
        let digits = value.filter(\.isNumber).count
        if digits >= 7, value.allSatisfy({ $0.isNumber || " +-()".contains($0) }) { return "phone.fill" }
        return "text.alignleft"
    }

    /// An unnamed snippet is written without the key rather than with an empty
    /// one: the file is documented as taking `label` or leaving it out, and
    /// what the app writes should look like what it asks people to write.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !label.isEmpty { try container.encode(label, forKey: .label) }
        try container.encode(text, forKey: .text)
    }

    private static func makeIdentifier(label: String, text: String) -> String {
        var hasher = Hasher()
        if label.isEmpty {
            hasher.combine(0)
            hasher.combine(text)
        } else {
            hasher.combine(1)
            hasher.combine(label)
        }
        return "snippet:\(UInt(bitPattern: hasher.finalize()))"
    }
}

/// A hand-kept list of things worth not retyping.
///
/// Deliberately not fed by the clipboard: the clipboard is a queue ordered by
/// recency, which loses exactly the entry used once a month, and anything
/// automatic would fill this with whatever happened to pass through. What
/// belongs here is decided by hand — from the panel or in the file, whichever
/// is closer at the time. Both edit the same list.
@MainActor
final class SnippetStore: ObservableObject {
    private static let maximumFileBytes = 10 * 1_024 * 1_024
    private static let maximumItems = 5_000
    static let maximumSearchCharacters = 16 * 1_024
    static let maximumQueryCharacters = 256

    @Published private(set) var items: [Snippet] = []
    @Published var query = "" {
        didSet {
            let end = query.index(
                query.startIndex,
                offsetBy: Self.maximumQueryCharacters,
                limitedBy: query.endIndex
            )
            if let end, end < query.endIndex { query = String(query[..<end]) }
        }
    }

    /// Matches the name and the value alike: one remembers an address either by
    /// what it is called or by what is in it, rarely reliably by both.
    var filtered: [Snippet] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return items }
        return items.filter {
            BoundedText.prefix($0.label, maximumCharacters: Self.maximumSearchCharacters).matches(needle)
                || BoundedText.prefix($0.text, maximumCharacters: Self.maximumSearchCharacters).matches(needle)
        }
    }

    /// `~/Library/Application Support/Impuls/snippets.json`. A plain array of
    /// `{"label": "...", "text": "..."}`, where `label` may be left out.
    nonisolated static let defaultFileURL: URL = {
        let fm = FileManager.default
        let folder = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Impuls", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("snippets.json")
    }()

    /// The file this store owns; see `StorageEnvironment` for why it is a
    /// property. Entering the Snippets or Actions tab reloads it, so as a
    /// constant on the type it was read by any test that switched tabs.
    let fileURL: URL

    init(fileURL: URL = SnippetStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    private struct FileSignature: Equatable {
        let size: UInt64
        let modificationDate: Date
        let resourceIdentifier: String?
    }

    private var hasLoaded = false
    private var loadedSignature: FileSignature?

    /// Re-read on every visit to the tab. The file is edited from outside the
    /// app, so the only sensible moment to trust what is in memory is the
    /// moment before it is shown.
    func reload() {
        let initialSignature = fileSignature()
        if hasLoaded, initialSignature == loadedSignature { return }
        guard initialSignature != nil else {
            items = []
            hasLoaded = true
            loadedSignature = nil
            return
        }

        // The file is intentionally user-editable. Retry once if an editor
        // replaces it during the bounded read, and never publish a mixed or
        // stale snapshot into the UI.
        for _ in 0..<2 {
            guard let before = fileSignature() else { break }
            do {
                let data = try BoundedFileReader.read(
                    from: fileURL,
                    maximumBytes: Self.maximumFileBytes
                )
                let decoded = try JSONDecoder().decode([Snippet].self, from: data)
                guard decoded.count <= Self.maximumItems else {
                    throw SnippetStoreError.tooManyItems
                }
                guard let after = fileSignature(), before == after else { continue }
                items = decoded
                hasLoaded = true
                loadedSignature = after
                return
            } catch {
                NSLog("Impuls: snippets.json is not readable: \(error.localizedDescription)")
                return
            }
        }
        NSLog("Impuls: snippets.json changed while it was being read")
    }

    /// Adds one and writes the file.
    ///
    /// Re-reads first, because the file is also edited by hand and the copy in
    /// memory is only as fresh as the last visit to the tab. Writing over it
    /// blind would silently undo whatever was added in an editor meanwhile.
    func add(label: String, text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let snippet = Snippet(label: label.trimmingCharacters(in: .whitespacesAndNewlines), text: value)
        reload()
        // Identity is the name, or the value when there is no name. Two rows
        // sharing one identity is not a duplicate to tidy up later — SwiftUI
        // lists them by it, so the newer simply replaces the older.
        items.removeAll { $0.id == snippet.id }
        items.insert(snippet, at: 0)
        persist()
    }

    func remove(_ snippet: Snippet) {
        items.removeAll { $0.id == snippet.id }
        persist()
    }

    func replace(with imported: [Snippet]) {
        var seen = Set<String>()
        items = imported.filter { seen.insert($0.id).inserted }
        query = ""
        persist()
    }

    /// Pretty-printed, and slashes left alone: the file is meant to be opened
    /// and edited by hand, and `\/` in every URL would be the app making that
    /// harder for its own convenience.
    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        do {
            try encoder.encode(items).write(to: fileURL, options: .atomic)
            hasLoaded = true
            loadedSignature = fileSignature()
        } catch {
            NSLog("Impuls: cannot write snippets.json: \(error.localizedDescription)")
        }
    }

    /// Puts a snippet on the pasteboard, ready to paste.
    ///
    /// The pasteboard is the only way to hand text to another app without
    /// asking for Accessibility, which this app is built not to do. Whatever
    /// was there is overwritten, and stays available in the clipboard tab.
    func copy(_ snippet: Snippet) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snippet.text, forType: .string)
    }

    static func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([defaultFileURL])
    }

    private func fileSignature() -> FileSignature? { Self.fileSignature(of: fileURL) }

    private static func fileSignature(of file: URL) -> FileSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modificationDate = attributes[.modificationDate] as? Date else { return nil }
        let freshURL = URL(fileURLWithPath: file.path)
        let resourceIdentifier = try? freshURL.resourceValues(
            forKeys: [.fileResourceIdentifierKey]
        ).fileResourceIdentifier
        return FileSignature(
            size: size,
            modificationDate: modificationDate,
            resourceIdentifier: resourceIdentifier.map { String(describing: $0) }
        )
    }
}

private enum SnippetStoreError: LocalizedError {
    case tooManyItems

    var errorDescription: String? {
        "snippets.json contains more than 5,000 items"
    }
}

private extension String {
    /// Case- and accent-blind, so "почта" finds "Почта" and "Nagy" finds "Nagy".
    func matches(_ needle: String) -> Bool {
        range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
