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
    /// Present only on a pinned file (IMP-39). `nil` is an ordinary text
    /// snippet, which is what every entry written before 1.4.16 decodes as —
    /// the key is absent from those files and absent from what they encode
    /// back, so an existing `snippets.json` round-trips unchanged.
    ///
    /// For a file pin the readable path lives in `text`, so the file stays
    /// hand-editable and the value stays searchable; this holds only the
    /// opaque bookmark.
    let file: SnippetFileReference?

    private enum CodingKeys: String, CodingKey { case label, text, file }

    init(label: String = "", text: String, file: SnippetFileReference? = nil) {
        self.id = Self.makeIdentifier(label: label, text: text)
        self.label = label
        self.text = text
        self.file = file
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        let text = try container.decode(String.self, forKey: .text)
        let file = try container.decodeIfPresent(SnippetFileReference.self, forKey: .file)
        self.init(label: label, text: text, file: file)
    }

    /// True when this pin points at a file rather than carrying text.
    var isFile: Bool { file != nil }

    /// The same pin with its bookmark dropped, keeping the readable path.
    ///
    /// A bookmark is machine-and-volume specific — it carries the volume name,
    /// the volume UUID and the inode — so it is both useless on another Mac and
    /// more than a path's worth of information to hand over. A backup is
    /// portable by definition, so it takes the path and leaves the blob behind.
    var strippingFileBookmark: Snippet {
        guard isFile else { return self }
        return Snippet(label: label, text: text, file: SnippetFileReference())
    }

    /// What the row shows for a file: the name, not the whole path.
    var fileName: String { URL(fileURLWithPath: text).lastPathComponent }

    var displayLabel: String {
        BoundedText.firstLine(label, maximumCharacters: 160)
    }

    var preview: String {
        BoundedText.firstLine(text, maximumCharacters: 240)
    }

    /// Guessed from the value, so a row is recognisable before it is read.
    var symbol: String {
        // A pinned file is named by its type rather than guessed at from the
        // path, reusing the classifier the clipboard already uses.
        if isFile { return ClipboardContentClassifier.kind(for: URL(fileURLWithPath: text)).symbol }
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
        // Written only for a file pin, so a file of text snippets encodes
        // byte-for-byte as it did before 1.4.16.
        if let file { try container.encode(file, forKey: .file) }
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
    /// Resolved, not created: see `ApplicationSupport`. Only
    /// `StorageEnvironment.live` and `reveal()` read it.
    nonisolated static var defaultFileURL: URL { ApplicationSupport.file(named: "snippets.json") }

    /// The file this store owns; see `StorageEnvironment` for why it is a
    /// property. Entering the Snippets or Actions tab reloads it, so as a
    /// constant on the type it was read by any test that switched tabs.
    let fileURL: URL

    /// No default, for the same reason as `NoteStore`.
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private struct FileSignature: Equatable {
        let size: UInt64
        let modificationDate: Date
        let resourceIdentifier: String?
    }

    private static let writeQueue = DispatchQueue(
        label: "io.tumanov.impuls.snippets.writer",
        qos: .utility
    )

    private var hasLoaded = false
    private var loadedSignature: FileSignature?
    private var writeGeneration = 0
    /// True between handing a snapshot to the writer and that write landing.
    /// The file is behind the list in memory for that moment, and re-reading it
    /// would undo the change that is still on its way to disk.
    private var pendingWrite = false

    /// Re-read on every visit to the tab. The file is edited from outside the
    /// app, so the only sensible moment to trust what is in memory is the
    /// moment before it is shown.
    func reload() {
        // A write is still on its way to disk, so the file is behind the list in
        // memory. Reading it here would publish the state this store is in the
        // middle of replacing.
        guard !pendingWrite else { return }

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
                // An editor replacing the file mid-read is exactly what the
                // retry is for, and it surfaces as a read or decode failure
                // rather than as a clean signature mismatch. Returning here
                // meant the one case the loop was written for never retried.
                // A file that did not move underneath us has a real problem.
                guard fileSignature() != before else {
                    NSLog("Impuls: snippets.json is not readable: \(error.localizedDescription)")
                    return
                }
                continue
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

    /// Pins a local file (IMP-39).
    ///
    /// Nothing is read from the file — not its bytes, not a preview. Only its
    /// path and a bookmark are kept, and the file itself stays exactly where
    /// the user put it. Rejects anything that is not a readable regular file,
    /// so a directory or a dead symlink never becomes a half-working pin.
    @discardableResult
    func addFile(_ url: URL, label: String = "") -> Bool {
        guard SnippetFileResolver.isReadableRegularFile(url) else { return false }
        let reference = SnippetFileReference(bookmark: SnippetFileResolver.makeBookmark(for: url))
        let snippet = Snippet(
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            text: url.path,
            file: reference
        )
        reload()
        items.removeAll { $0.id == snippet.id }
        items.insert(snippet, at: 0)
        persist()
        return true
    }

    /// "Choose File Again" for a pin whose file has gone.
    ///
    /// Replaces the reference on the *existing* row rather than adding a second
    /// one, and keeps its position in the list: re-pointing a pin is editing it,
    /// not creating a new one. Returns false when the row is gone or the chosen
    /// file is not usable, in which case nothing is written.
    @discardableResult
    func replaceFile(_ snippet: Snippet, with url: URL) -> Bool {
        guard snippet.isFile, SnippetFileResolver.isReadableRegularFile(url) else { return false }
        reload()
        guard let index = items.firstIndex(where: { $0.id == snippet.id }) else { return false }
        let reference = SnippetFileReference(bookmark: SnippetFileResolver.makeBookmark(for: url))
        let replacement = Snippet(label: items[index].label, text: url.path, file: reference)
        items[index] = replacement
        // Identity is derived from label and value, so re-pointing one pin at a
        // file another pin already holds would produce two rows sharing an id —
        // and `remove` deletes by id, so deleting one would delete both. The
        // module's identity rule is that a duplicate replaces the older entry.
        dropDuplicatesKeeping(index: index, id: replacement.id)
        persist()
        return true
    }

    /// Writes back a reference that resolution had to refresh — a file that was
    /// renamed or moved. In place and without reordering: the user did not ask
    /// for anything to change, so nothing visible should.
    func updateFileReference(for snippet: Snippet, resolvedURL: URL, bookmark: Data) {
        guard let index = items.firstIndex(where: { $0.id == snippet.id }) else { return }
        guard items[index].isFile else { return }
        let refreshed = Snippet(
            label: items[index].label,
            text: resolvedURL.path,
            file: SnippetFileReference(bookmark: bookmark)
        )
        items[index] = refreshed
        // Following a rename can land on a path another pin already holds; the
        // same identity rule applies as in `replaceFile`.
        dropDuplicatesKeeping(index: index, id: refreshed.id)
        persist()
    }

    /// Keeps the entry at `index` and drops any other row that now shares its
    /// identity, so an `Identifiable` list never holds two rows with one id.
    private func dropDuplicatesKeeping(index: Int, id: String) {
        items = items.enumerated().filter { offset, item in
            item.id != id || offset == index
        }.map(\.element)
    }

    /// Resolution for one pin. Lazy by construction: nothing calls this on a
    /// timer, so a pin costs nothing until it is shown or used.
    func resolveFile(_ snippet: Snippet) -> SnippetFileResolution {
        guard let file = snippet.file else { return .unavailable }
        return SnippetFileResolver.resolve(path: snippet.text, bookmark: file.bookmark)
    }

    /// Removes the row and nothing else.
    ///
    /// For a file pin this deletes the *reference*. The file on disk is never
    /// touched: there is no `FileManager.removeItem`, no trash call and no move
    /// anywhere on this path, and a test asserts the fixture still exists after
    /// the pin is gone.
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

    /// Hands the snapshot to the writer and returns.
    ///
    /// Encoding up to 5 000 snippets and writing them atomically used to happen
    /// on the main actor, on every add, remove and import — the interface waited
    /// for the disk. `NoteStore` already writes from its own queue; this is the
    /// same arrangement, without the typing debounce, because a snippet changes
    /// on a deliberate action rather than on every keystroke.
    ///
    /// While a write is in flight the copy in memory is newer than the file, so
    /// `reload()` must not read over it — see `pendingWrite`.
    private func persist() {
        writeGeneration += 1
        let generation = writeGeneration
        pendingWrite = true
        let snapshot = items
        let fileURL = self.fileURL

        Self.writeQueue.async { [weak self] in
            let signature = Self.write(snapshot, to: fileURL)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.writeGeneration == generation else { return }
                    self.pendingWrite = false
                    self.hasLoaded = true
                    self.loadedSignature = signature
                }
            }
        }
    }

    /// Shutdown is the one path where durability outranks a short wait. The
    /// serial queue drains older snapshots first, then this one lands before the
    /// process exits.
    func flushSynchronously() {
        writeGeneration += 1
        let snapshot = items
        let fileURL = self.fileURL
        Self.writeQueue.sync { _ = Self.write(snapshot, to: fileURL) }
        pendingWrite = false
    }

    /// Pretty-printed, and slashes left alone: the file is meant to be opened
    /// and edited by hand, and `\/` in every URL would be the app making that
    /// harder for its own convenience.
    nonisolated private static func write(_ snippets: [Snippet], to fileURL: URL) -> FileSignature? {
        ApplicationSupport.ensureParentDirectory(for: fileURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        do {
            try encoder.encode(snippets).write(to: fileURL, options: .atomic)
            return fileSignature(of: fileURL)
        } catch {
            NSLog("Impuls: cannot write snippets.json: \(error.localizedDescription)")
            return nil
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

    /// The one place a folder is created without anything being written to it,
    /// and deliberately: the menu item exists so that somebody can go and edit
    /// the file by hand, and revealing nothing at all would be a worse answer
    /// than revealing an empty folder. This is a person asking for the folder,
    /// which is not the same as code asking where it is.
    static func reveal() {
        let file = defaultFileURL
        ApplicationSupport.ensureParentDirectory(for: file)
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    private func fileSignature() -> FileSignature? { Self.fileSignature(of: fileURL) }

    nonisolated private static func fileSignature(of file: URL) -> FileSignature? {
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
