import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Marker Impuls puts on pasteboard writes of its own.
    static let impulsInternal = NSPasteboard.PasteboardType("io.tumanov.impuls.internal")
}

struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    /// Starts as the file-type icon and is replaced by a real preview once
    /// QuickLook renders one — a shelf of identical PNG icons is useless when
    /// what it holds is screenshots.
    var icon: NSImage
    var name: String { url.lastPathComponent }
    var isImage: Bool { ClipboardContentClassifier.kind(for: url) == .image }

    static func == (lhs: ShelfItem, rhs: ShelfItem) -> Bool { lhs.url == rhs.url }
}

/// Drop zone contents. Files are referenced, never copied — the shelf is a
/// holding area, so moving the original away simply removes it from the shelf.
@MainActor
final class ShelfStore: ObservableObject {
    private static let maximumInlinePasteboardBytes = 64 * 1_024 * 1_024

    @Published private(set) var items: [ShelfItem] = []
    /// Cards picked for a group drag. Empty means "drag whatever is grabbed".
    @Published private(set) var selection: Set<UUID> = []

    private let defaultsKey = "shelf.urls"
    /// Where the shelf remembers itself. Handed in rather than reaching for
    /// `.standard` so that one Impuls — the app, or a test — writes to exactly
    /// one place. The app passes the same store `SettingsStore` uses, which is
    /// `.standard`, so nothing about the shipped behaviour changes.
    private let defaults: UserDefaults
    /// Generous, because saved screenshots accumulate here and nothing is
    /// deleted behind the user's back. Cards past the limit leave the shelf,
    /// but their files stay in the folder.
    private let limit = 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() {
        let paths = defaults.stringArray(forKey: defaultsKey) ?? []
        items = paths
            .map(URL.init(fileURLWithPath:))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { ShelfItem(url: $0, icon: NSWorkspace.shared.icon(forFile: $0.path)) }
        items.forEach(loadThumbnail)
    }

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            let item = ShelfItem(url: url, icon: NSWorkspace.shared.icon(forFile: url.path))
            items.insert(item, at: 0)
            loadThumbnail(item)
        }
        if items.count > limit { items.removeLast(items.count - limit) }
        persist()
    }

    private func loadThumbnail(_ item: ShelfItem) {
        // A square box QuickLook fits the content into, whatever its shape.
        // Generous enough that a landscape screenshot still lands above the
        // card's pixel size once it has been fitted.
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: 96, height: 96),
            scale: 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return }
            // `nsImage` already carries the right point size for the
            // representation; deriving one from `contentRect` risks describing
            // a shape the bitmap does not have.
            let image = rep.nsImage
            Task { @MainActor in
                guard let self, let index = self.items.firstIndex(where: { $0.url == item.url }) else { return }
                self.items[index].icon = image
            }
        }
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        selection.remove(item.id)
        persist()
    }

    func clear() {
        items.removeAll()
        selection.removeAll()
        persist()
    }

    func remove(urls: [URL]) {
        let removed = Set(urls)
        let removedIDs = Set(items.filter { removed.contains($0.url) }.map(\.id))
        items.removeAll { removed.contains($0.url) }
        selection.subtract(removedIDs)
        persist()
    }

    /// Files an operation started on `item` should use. It mirrors Finder:
    /// when the card belongs to the current selection the operation applies to
    /// the whole selection, otherwise only to the card that opened the menu.
    func operationURLs(startingAt item: ShelfItem) -> [URL] {
        guard selection.contains(item.id) else { return [item.url] }
        return items.filter { selection.contains($0.id) }.map(\.url)
    }

    var selectedURLs: [URL] {
        items.filter { selection.contains($0.id) }.map(\.url)
    }

    // MARK: - Selection

    /// Plain click replaces the selection; ⌘ or ⇧ adds to it, matching Finder.
    func select(_ item: ShelfItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            if selection.contains(item.id) {
                selection.remove(item.id)
            } else {
                selection.insert(item.id)
            }
        } else if selection == [item.id] {
            selection.removeAll()
        } else {
            selection = [item.id]
        }
    }

    func isSelected(_ item: ShelfItem) -> Bool { selection.contains(item.id) }

    func clearSelection() { selection.removeAll() }

    func selectAll() { selection = Set(items.map(\.id)) }

    /// Files a drag started on `item` should carry: the whole selection when
    /// the grabbed card belongs to it, otherwise just that card.
    func dragURLs(startingAt item: ShelfItem) -> [URL] {
        guard selection.contains(item.id) else { return [item.url] }
        return items.filter { selection.contains($0.id) }.map(\.url)
    }

    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// Puts the card back on the pasteboard. Images go as image data as well as
    /// a file reference, so pasting works both in Finder and in an editor.
    func copy(_ item: ShelfItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Tells ClipboardStore this change came from us, so a copied screenshot
        // is not saved to disk a second time.
        pasteboard.setData(Data(), forType: .impulsInternal)
        pasteboard.writeObjects([item.url as NSURL])
        if let type = UTType(filenameExtension: item.url.pathExtension),
           type.conforms(to: .image),
           let data = try? BoundedFileReader.read(
               from: item.url,
               maximumBytes: Self.maximumInlinePasteboardBytes
           ) {
            pasteboard.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
    }

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(item.url)
    }

    /// Renames a file without allowing a path escape, extension change, or
    /// overwrite. The file keeps its place and selection on the shelf.
    @discardableResult
    func rename(_ item: ShelfItem, baseName proposedBaseName: String) throws -> ShelfItem {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else {
            throw ShelfRenameError.itemMissing
        }
        let target = try Self.safeRenameTarget(for: item.url, baseName: proposedBaseName)
        guard target != item.url else { return items[index] }

        try FileManager.default.moveItem(at: item.url, to: target)
        items[index].url = target
        items[index].icon = NSWorkspace.shared.icon(forFile: target.path)
        let updated = items[index]
        loadThumbnail(updated)
        persist()
        return updated
    }

    /// Reverses a rename only while the card still references the renamed file
    /// and the original path remains free. File contents are preserved.
    @discardableResult
    func restoreName(itemID: UUID, currentURL: URL, originalURL: URL) throws -> ShelfItem {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].url.standardizedFileURL == currentURL.standardizedFileURL,
              FileManager.default.fileExists(atPath: currentURL.path) else {
            throw ShelfRenameError.itemMissing
        }
        guard !FileManager.default.fileExists(atPath: originalURL.path) else {
            throw ShelfRenameError.alreadyExists
        }

        try FileManager.default.moveItem(at: currentURL, to: originalURL)
        items[index].url = originalURL
        items[index].icon = NSWorkspace.shared.icon(forFile: originalURL.path)
        let restored = items[index]
        loadThumbnail(restored)
        persist()
        return restored
    }

    nonisolated static func safeRenameTarget(for source: URL, baseName proposedBaseName: String) throws -> URL {
        let baseName = proposedBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseName.isEmpty else { throw ShelfRenameError.emptyName }
        guard baseName != ".", baseName != "..",
              !baseName.contains("/"), !baseName.contains("\\"), !baseName.contains(":") else {
            throw ShelfRenameError.invalidName
        }

        let ext = source.pathExtension
        let fileName = ext.isEmpty ? baseName : "\(baseName).\(ext)"
        let target = source.deletingLastPathComponent().appendingPathComponent(fileName)
        if target.standardizedFileURL == source.standardizedFileURL { return source }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw ShelfRenameError.alreadyExists
        }
        return target
    }

    private func persist() {
        defaults.set(items.map(\.url.path), forKey: defaultsKey)
    }
}

enum ShelfRenameError: LocalizedError, Equatable {
    case itemMissing
    case emptyName
    case invalidName
    case alreadyExists

    var errorDescription: String? {
        switch self {
        case .itemMissing: return localized("The shelf item is no longer available.")
        case .emptyName: return localized("Enter a file name.")
        case .invalidName: return localized("The file name contains invalid characters.")
        case .alreadyExists: return localized("A file with this name already exists.")
        }
    }
}
