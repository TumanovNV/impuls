import AppKit
import ImageIO

struct ClipItem: Identifiable, Codable, Equatable {
    enum Payload: Codable, Equatable {
        case text(String)
        case file(URL)

        private enum CodingKeys: String, CodingKey { case type, text, url }
        private enum Kind: String, Codable { case text, file }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .type) {
            case .text: self = .text(try container.decode(String.self, forKey: .text))
            case .file: self = .file(try container.decode(URL.self, forKey: .url))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode(Kind.text, forKey: .type)
                try container.encode(text, forKey: .text)
            case .file(let url):
                try container.encode(Kind.file, forKey: .type)
                try container.encode(url, forKey: .url)
            }
        }
    }

    let id: UUID
    let payload: Payload
    var date: Date
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        payload: Payload,
        date: Date,
        isPinned: Bool = false
    ) {
        self.id = id
        self.payload = payload
        self.date = date
        self.isPinned = isPinned
    }

    var preview: String {
        switch payload {
        case .text(let string): return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case .file(let url): return url.lastPathComponent
        }
    }

    var contentKind: ClipboardContentKind {
        switch payload {
        case .text(let string): return ClipboardContentClassifier.kind(for: string)
        case .file(let url): return ClipboardContentClassifier.kind(for: url)
        }
    }

    var symbol: String { contentKind.symbol }

    static func == (lhs: ClipItem, rhs: ClipItem) -> Bool { lhs.payload == rhs.payload }
}

/// Polls the general pasteboard's change counter. Cheap: one integer read
/// twice a second, and nothing at all is read until the counter moves.
@MainActor
final class ClipboardStore: ObservableObject {
    static let maximumTextBytes = 512 * 1_024
    static let maximumImageBytes = 64 * 1_024 * 1_024

    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var isPaused = false

    /// The saved PNG URL lets the clipboard keep an image entry while the
    /// shelf remains the owner of the actual file.
    var onImage: ((Data) -> URL?)?
    var wantsImages: () -> Bool = { true }
    var isApplicationExcluded: (String) -> Bool = { _ in false }

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private let limit = 100
    private let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private let persistence: ClipboardHistoryPersistence?
    private var persistenceEnabled = false
    private var retentionInterval: TimeInterval = SettingsStore.ClipboardRetention.sevenDays.timeInterval

    init(persistence: ClipboardHistoryPersistence? = ClipboardHistoryPersistence()) {
        self.persistence = persistence
    }

    func configurePersistence(enabled: Bool, retention: SettingsStore.ClipboardRetention) {
        let wasEnabled = persistenceEnabled
        persistenceEnabled = enabled
        retentionInterval = retention.timeInterval

        if enabled, !wasEnabled {
            let restored = persistence?.load() ?? []
            merge(restored)
            prune()
            persist()
        } else if enabled {
            prune()
            persist()
        } else if wasEnabled {
            persistence?.delete()
        }
    }

    func start() {
        stop()
        prune()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        persist()
    }

    func togglePause() {
        isPaused.toggle()
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func clear() {
        items.removeAll()
        persist()
    }

    func clearUnpinned() {
        items.removeAll { !$0.isPinned }
        persist()
    }

    func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func setPinned(id: UUID, pinned: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned = pinned
        sortItems()
        persist()
    }

    func togglePinned(_ item: ClipItem) {
        setPinned(id: item.id, pinned: !item.isPinned)
    }

    /// Puts an entry back on the pasteboard without re-recording it.
    func copy(_ item: ClipItem) {
        writeToPasteboard(item.payload)
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].date = Date()
            sortItems()
            persist()
        }
    }

    func copy(_ payload: ClipItem.Payload) {
        writeToPasteboard(payload)
    }

    private func writeToPasteboard(_ payload: ClipItem.Payload) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch payload {
        case .text(let string): pasteboard.setString(string, forType: .string)
        case .file(let url): pasteboard.writeObjects([url as NSURL])
        }
        lastChangeCount = pasteboard.changeCount
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        if isPaused {
            lastChangeCount = pasteboard.changeCount
            return
        }
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        guard pasteboard.data(forType: concealed) == nil else { return }
        guard pasteboard.data(forType: .impulsInternal) == nil else { return }

        let sourceBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let sourceBundleIdentifier, isApplicationExcluded(sourceBundleIdentifier) { return }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           let url = urls.first {
            record(ClipItem(
                payload: .file(url),
                date: Date()
            ))
            return
        }

        if wantsImages() {
            if let png = pngFromPasteboard(pasteboard), let url = onImage?(png) {
                record(ClipItem(
                    payload: .file(url),
                    date: Date()
                ))
                return
            }

            if pasteboard.availableType(from: [.png, .tiff]) != nil {
                awaitImage(at: pasteboard.changeCount, attempt: 0)
                return
            }
        }

        guard let string = pasteboard.string(forType: .string),
              Self.isTextPayloadAllowed(string),
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        record(ClipItem(
            payload: .text(string),
            date: Date()
        ))
    }

    private func awaitImage(at changeCount: Int, attempt: Int) {
        guard attempt < 12 else {
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == changeCount,
                  let string = pasteboard.string(forType: .string),
                  Self.isTextPayloadAllowed(string),
                  !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            record(ClipItem(
                payload: .text(string),
                date: Date()
            ))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pasteboard = NSPasteboard.general
                guard pasteboard.changeCount == changeCount else { return }
                if let png = self.pngFromPasteboard(pasteboard), let url = self.onImage?(png) {
                    self.record(ClipItem(
                        payload: .file(url),
                        date: Date()
                    ))
                    return
                }
                self.awaitImage(
                    at: changeCount,
                    attempt: attempt + 1
                )
            }
        }
    }

    private func pngFromPasteboard(_ pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png), Self.isImagePayloadAllowed(png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff),
              Self.isImagePayloadAllowed(tiff),
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]),
              png.count <= Self.maximumImageBytes else { return nil }
        return png
    }

    /// Internal so the deterministic history rules can be exercised without
    /// mutating the real system pasteboard in XCTest.
    func record(_ item: ClipItem) {
        guard Self.isPayloadAllowed(item.payload) else { return }
        let existing = items.first(where: { $0 == item })
        var replacement = item
        if let existing {
            replacement = ClipItem(
                id: existing.id,
                payload: item.payload,
                date: item.date,
                isPinned: existing.isPinned
            )
        }
        items.removeAll { $0 == item }
        items.append(replacement)
        sortItems()
        prune()
        persist()
    }

    func prune(at now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-retentionInterval)
        items.removeAll { !$0.isPinned && $0.date < cutoff }
        if items.count > limit {
            let pinned = Array(items.filter(\.isPinned).prefix(limit))
            let recent = Array(items.filter { !$0.isPinned }.prefix(max(0, limit - pinned.count)))
            items = pinned + recent
        }
        sortItems()
    }

    private func merge(_ restored: [ClipItem]) {
        for item in restored where Self.isPayloadAllowed(item.payload)
            && !items.contains(where: { $0 == item }) {
            items.append(item)
        }
        sortItems()
    }

    static func isTextPayloadAllowed(_ text: String) -> Bool {
        text.lengthOfBytes(using: .utf8) <= maximumTextBytes
    }

    static func isImagePayloadAllowed(_ data: Data) -> Bool {
        guard data.count <= maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return (try? FileToolsService.validateImageDimensions(in: source)) != nil
    }

    private static func isPayloadAllowed(_ payload: ClipItem.Payload) -> Bool {
        switch payload {
        case .text(let text): return isTextPayloadAllowed(text)
        case .file: return true
        }
    }

    private func sortItems() {
        items.sort {
            if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
            return $0.date > $1.date
        }
    }

    private func persist() {
        guard persistenceEnabled else { return }
        persistence?.save(items)
    }
}
