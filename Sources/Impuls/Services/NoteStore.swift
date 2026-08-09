import AppKit

struct Note: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var text: String
    var edited: Date

    var preview: String {
        BoundedText.firstLine(text, maximumCharacters: 160)
    }
}

/// Scratch notes: somewhere to put a thought down for an hour.
///
/// Deliberately not a notes app. No folders, no formatting, no search — for
/// that there are real editors. This replaces the unsaved buffer people keep
/// in one: a phone number from a call, half a link, a thought to come back to
/// — written fast, then deleted or carried off through the clipboard.
///
/// Everything here is shaped by that shortness of life: notes are created
/// empty and instantly, deleted in one click, and the blank ones sweep
/// themselves out when the tab is left. The file they live in is an
/// implementation detail — unlike the snippets file, nobody is expected to
/// edit it by hand.
@MainActor
final class NoteStore: ObservableObject {
    private static let maximumFileBytes = 10 * 1_024 * 1_024
    private static let maximumItems = 5_000

    @Published private(set) var notes: [Note] = []
    /// Which note the editor shows. Lives here rather than in the pane so the
    /// choice survives the pane being unmounted with the panel.
    @Published var selected: Note.ID?

    private static let file: URL = {
        let fm = FileManager.default
        let folder = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Impuls", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("notes.json")
    }()

    private let writeQueue = DispatchQueue(label: "io.tumanov.impuls.notes.writer", qos: .utility)
    private var saveGeneration = 0

    init() {
        load()
    }

    // MARK: - Editing

    /// A new empty note, selected and ready to type into. Newest on top, and
    /// the order never changes afterwards: a list that reshuffles itself on
    /// every edit loses the reader's place for tidiness nobody asked for.
    @discardableResult
    func add(text: String = "") -> Note.ID {
        let note = Note(id: UUID(), text: text, edited: Date())
        notes.insert(note, at: 0)
        selected = note.id
        scheduleSave()
        return note.id
    }

    func update(_ id: Note.ID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].text = text
        notes[index].edited = Date()
        scheduleSave()
    }

    func remove(_ id: Note.ID) {
        notes.removeAll { $0.id == id }
        if selected == id { selected = notes.first?.id }
        scheduleSave()
    }

    /// Called when the user leaves the tab: notes that never got any text
    /// sweep themselves out. They cost one hover to recreate, and a trail of
    /// blank cards is exactly the clutter a scratchpad exists to avoid.
    func leave() {
        notes.removeAll { !$0.text.contains(where: { !$0.isWhitespace }) }
        if let selected, !notes.contains(where: { $0.id == selected }) {
            self.selected = notes.first?.id
        }
        flush()
    }

    func replace(with imported: [Note]) {
        var seen = Set<Note.ID>()
        notes = imported.filter { seen.insert($0.id).inserted }
        selected = notes.first?.id
        flush()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? BoundedFileReader.read(
                  from: Self.file,
                  maximumBytes: Self.maximumFileBytes
              ),
              let stored = try? JSONDecoder().decode([Note].self, from: data),
              stored.count <= Self.maximumItems else { return }
        notes = stored
        selected = notes.first?.id
    }

    /// A moment after the typing pauses, not on every keystroke: the text
    /// lives in memory either way, and the file only has to be right by the
    /// time somebody could read it.
    private func scheduleSave() {
        saveGeneration += 1
        let generation = saveGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.saveGeneration == generation else { return }
            let snapshot = self.notes
            let fileURL = Self.file
            let queue = self.writeQueue
            queue.async { Self.persist(snapshot, to: fileURL) }
        }
    }

    /// Enqueues the latest snapshot without making the interface wait for JSON
    /// encoding or the atomic disk write.
    func flush() {
        saveGeneration += 1
        let snapshot = notes
        let fileURL = Self.file
        writeQueue.async { Self.persist(snapshot, to: fileURL) }
    }

    /// Shutdown is the one path where durability is more important than a
    /// short wait. The serial queue first drains older snapshots, then writes
    /// the exact final state before the process exits.
    func flushSynchronously() {
        saveGeneration += 1
        let snapshot = notes
        let fileURL = Self.file
        writeQueue.sync { Self.persist(snapshot, to: fileURL) }
    }

    nonisolated private static func persist(_ notes: [Note], to fileURL: URL) {
        do {
            try JSONEncoder().encode(notes).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Impuls: cannot write notes.json: \(error.localizedDescription)")
        }
    }
}
