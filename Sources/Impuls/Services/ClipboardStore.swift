import AppKit
import ImageIO

struct ClipItem: Identifiable, Codable, Equatable, Sendable {
    enum Payload: Codable, Equatable, Sendable {
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
        case .text(let string): return BoundedText.firstLine(string, maximumCharacters: 240)
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
    // Pure budgets and pure predicates: `nonisolated` so the image conversion
    // can apply them from its own queue rather than hopping back for a bound.
    nonisolated static let maximumTextBytes = 512 * 1_024
    nonisolated static let maximumImageBytes = 64 * 1_024 * 1_024

    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var isPaused = false

    /// The saved PNG URL lets the clipboard keep an image entry while the
    /// shelf remains the owner of the actual file.
    /// Image persistence is deliberately asynchronous. A clipboard image may
    /// be tens of megabytes; writing it from the pasteboard poll used to block
    /// the main thread and the whole panel until the atomic file write ended.
    var onImage: ((Data, Date) -> Void)?
    var wantsImages: () -> Bool = { true }
    var isApplicationExcluded: (String) -> Bool = { _ in false }

    /// Serial: one clipboard image is converted at a time. A burst of copies
    /// should queue behind each other rather than decode several tens of
    /// megabytes at once, and the generation check discards the stale ones.
    private static let conversionQueue = DispatchQueue(
        label: "io.tumanov.impuls.clipboard.image-conversion",
        qos: .userInitiated
    )

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private let limit = 100
    private let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private let persistence: ClipboardHistoryPersistence?
    private var persistenceEnabled = false
    private var retentionInterval: TimeInterval = SettingsStore.ClipboardRetention.sevenDays.timeInterval

    /// No default, for the same reason `NoteStore` has none: `nil` here is a
    /// history that is never written, and the default was the real archive plus
    /// the one login-keychain key that decrypts it. A test that left the
    /// argument off would read the user's clipboard history, and switching
    /// persistence off deletes that key — taking the real archive with it.
    init(persistence: ClipboardHistoryPersistence?) {
        self.persistence = persistence
    }

    func configurePersistence(enabled: Bool, retention: SettingsStore.ClipboardRetention) {
        let wasEnabled = persistenceEnabled
        persistenceEnabled = enabled
        retentionInterval = retention.timeInterval

        if enabled, !wasEnabled {
            restoreFromArchive()
        } else if enabled, persistence?.isBlockedByUnreadableArchive == true {
            // Still latched from an earlier failed read. Retry it here rather
            // than pruning and persisting into a write that cannot land: a
            // login keychain unlocked since launch recovers at the next touch
            // of the clipboard settings instead of staying blocked all session.
            restoreFromArchive()
        } else if enabled {
            prune()
            persist()
        } else if wasEnabled {
            persistence?.delete()
        }
    }

    /// Reads the archive and folds it into whatever is already in memory.
    ///
    /// A read that fails leaves the file exactly as it is.
    /// `ClipboardHistoryPersistence` latches on that failure and refuses every
    /// write until a read succeeds, so neither this call nor any later
    /// clipboard event, prune, retention change or shutdown flush can seal an
    /// empty or partial list over a history this process merely could not open
    /// — a newer build's archive, one over the size budget, a key the process
    /// could not fetch. Items captured meanwhile stay in memory and are written
    /// as soon as a read succeeds, which is what makes this the recovery path
    /// rather than only a guard.
    ///
    /// `merge` is the existing union by payload equality, so recovery adds the
    /// restored rows to the session's own without inventing a reconciliation
    /// rule: the archive wins nothing, the session loses nothing.
    private func restoreFromArchive() {
        let restored = persistence?.load() ?? .loaded([])
        merge(restored.items)
        prune()
        guard !restored.isUnreadable else { return }
        persist()
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
        // A read that failed at launch can succeed now — a login keychain
        // unlocked during the session is the ordinary case. One last attempt,
        // so this session's items are folded into the archive instead of being
        // dropped at quit. Still unreadable means `persist`/`flush` below write
        // nothing, which is the point: shutdown is not the moment the latch
        // quietly gives up.
        if persistence?.isBlockedByUnreadableArchive == true { restoreFromArchive() }
        persist()
        persistence?.flush()
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

        // Presence is enough. Materialising marker data lets another process
        // force an unnecessary allocation before Impuls has inspected the
        // actual clipboard payload.
        guard pasteboard.availableType(from: [concealed]) == nil else { return }
        guard pasteboard.availableType(from: [.impulsInternal]) == nil else { return }

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

        if wantsImages(), pasteboard.availableType(from: [.png, .tiff]) != nil {
            convertImage(at: pasteboard.changeCount, attempt: 0)
            return
        }

        guard let string = pasteboard.string(forType: .string),
              Self.isTextPayloadAllowed(string),
              string.contains(where: { !$0.isWhitespace }) else { return }
        record(ClipItem(
            payload: .text(string),
            date: Date()
        ))
    }

    /// Takes the bytes off the pasteboard here and converts them elsewhere.
    ///
    /// A copied screenshot can be tens of megabytes, and turning one into PNG
    /// means decoding a TIFF and re-encoding it. That ran inside the twice-a-
    /// second poll, on the main actor, so a large copy froze the panel — and
    /// froze it during the exact animation the copy tends to interrupt. Only
    /// the pasteboard reads stay here, because `NSPasteboard` belongs to the
    /// main thread; the decode does not.
    ///
    /// `changeCount` is the generation. It is re-checked after the hop, so a
    /// conversion that finishes after the user has copied something else is
    /// discarded rather than recorded against the newer clipboard.
    private func convertImage(at changeCount: Int, attempt: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == changeCount else { return }

        // PNG first, and the TIFF representation only if the PNG turns out to
        // be unusable — advertised but oversized, or something ImageIO cannot
        // open. Reading both up front would materialise two copies of a large
        // screenshot for a fallback that almost never runs.
        guard let png = pasteboard.data(forType: .png) else {
            convertTIFF(at: changeCount, attempt: attempt)
            return
        }

        Self.conversionQueue.async { [weak self] in
            let usable = Self.isImagePayloadAllowed(png) ? png : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard NSPasteboard.general.changeCount == changeCount else { return }
                    if let usable, let onImage = self.onImage {
                        onImage(usable, Date())
                        return
                    }
                    self.convertTIFF(at: changeCount, attempt: attempt)
                }
            }
        }
    }

    private func convertTIFF(at changeCount: Int, attempt: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == changeCount,
              let tiff = pasteboard.data(forType: .tiff) else {
            retryOrRecordText(at: changeCount, attempt: attempt)
            return
        }

        Self.conversionQueue.async { [weak self] in
            let converted = Self.pngFromTIFF(tiff)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard NSPasteboard.general.changeCount == changeCount else { return }
                    if let converted, let onImage = self.onImage {
                        onImage(converted, Date())
                        return
                    }
                    self.retryOrRecordText(at: changeCount, attempt: attempt)
                }
            }
        }
    }

    /// An image can be advertised before its data is available, so a failed
    /// conversion is retried a bounded number of times before the clipboard
    /// settles for whatever text came with it.
    private func retryOrRecordText(at changeCount: Int, attempt: Int) {
        guard attempt < 12 else {
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == changeCount,
                  let string = pasteboard.string(forType: .string),
                  Self.isTextPayloadAllowed(string),
                  string.contains(where: { !$0.isWhitespace }) else { return }
            record(ClipItem(
                payload: .text(string),
                date: Date()
            ))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.convertImage(at: changeCount, attempt: attempt + 1)
            }
        }
    }

    /// Runs off the main actor. Takes only the bytes, so nothing it touches is
    /// owned by another thread. This is the expensive half: a decode of the
    /// TIFF and a re-encode to PNG, both bounded.
    nonisolated private static func pngFromTIFF(_ tiff: Data) -> Data? {
        guard isImagePayloadAllowed(tiff),
              let rep = NSBitmapImageRep(data: tiff),
              let converted = rep.representation(using: .png, properties: [:]),
              converted.count <= maximumImageBytes else { return nil }
        return converted
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

    nonisolated static func isImagePayloadAllowed(_ data: Data) -> Bool {
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
