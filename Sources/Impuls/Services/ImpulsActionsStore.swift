import Combine
import Foundation

enum ImpulsActionSource: String, CaseIterable, Hashable {
    case clipboard
    case snippets
    case notes

    var title: String {
        switch self {
        case .clipboard: return localized("Clipboard")
        case .snippets: return localized("Snippets")
        case .notes: return localized("Notes")
        }
    }

    var symbol: String {
        switch self {
        case .clipboard: return "list.clipboard"
        case .snippets: return "pin"
        case .notes: return "note.text"
        }
    }
}

enum ImpulsActionValue: Equatable {
    case text(String)
    case file(URL)

    var text: String? {
        guard case .text(let value) = self else { return nil }
        return value
    }
}

enum ImpulsActionOrigin: Hashable {
    case clipboard(UUID)
    case snippet(String)
    case note(UUID)
}

enum ImpulsActionCommand: String, CaseIterable, Hashable, Identifiable {
    case copy
    case saveSnippet
    case createNote
    case translate
    case open
    case email
    case call
    case formatJSON
    case pin
    case unpin
    case reveal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copy: return localized("Copy")
        case .saveSnippet: return localized("To Snippets")
        case .createNote: return localized("To Notes")
        case .translate: return localized("Translate")
        case .open: return localized("Open")
        case .email: return localized("New Email")
        case .call: return localized("Call")
        case .formatJSON: return localized("Format JSON")
        case .pin: return localized("Pin")
        case .unpin: return localized("Unpin")
        case .reveal: return localized("Show in Finder")
        }
    }

    var symbol: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .saveSnippet: return "pin"
        case .createNote: return "note.text.badge.plus"
        case .translate: return "translate"
        case .open: return "arrow.up.forward.app"
        case .email: return "envelope"
        case .call: return "phone"
        case .formatJSON: return "curlybraces"
        case .pin: return "pin"
        case .unpin: return "pin.slash"
        case .reveal: return "folder"
        }
    }
}

struct ImpulsActionResult: Identifiable, Equatable {
    let origin: ImpulsActionOrigin
    let source: ImpulsActionSource
    let title: String
    let detail: String
    let value: ImpulsActionValue
    let contentKind: ClipboardContentKind
    let isPinned: Bool

    var id: String {
        switch origin {
        case .clipboard(let id): return "clipboard:\(id.uuidString)"
        case .snippet(let id): return "snippet:\(id)"
        case .note(let id): return "note:\(id.uuidString)"
        }
    }

    var commands: [ImpulsActionCommand] {
        var available: [ImpulsActionCommand]
        switch value {
        case .file:
            available = [.copy, .open, .reveal]
        case .text:
            available = [.copy]
            if source != .snippets { available.append(.saveSnippet) }
            if source != .notes { available.append(.createNote) }
            available.append(.translate)
            switch contentKind {
            case .link: available.append(.open)
            case .email: available.append(.email)
            case .phone: available.append(.call)
            case .json: available.append(.formatJSON)
            default: break
            }
        }
        if case .clipboard = origin {
            available.append(isPinned ? .unpin : .pin)
        }
        return available
    }

    var externalURL: URL? {
        guard case .text(let text) = value else {
            guard case .file(let url) = value else { return nil }
            return url
        }
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch contentKind {
        case .link: return ClipboardContentClassifier.webURL(from: candidate)
        case .email: return ClipboardContentClassifier.emailURL(from: candidate)
        case .phone: return ClipboardContentClassifier.phoneURL(from: candidate)
        default: return nil
        }
    }
}

/// Local search over content that Impuls already owns. It builds results from
/// the live stores instead of maintaining another search database.
@MainActor
final class ImpulsActionsStore: ObservableObject {
    static let maximumSearchCharacters = 16 * 1_024
    static let maximumSummaryCharacters = 160
    static let maximumQueryCharacters = 256

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

    private struct Ranked {
        let result: ImpulsActionResult
        let score: Int
        let order: Int
    }

    /// One searchable row, with its three match fields already case- and
    /// diacritic-folded.
    private struct FoldedResult {
        let result: ImpulsActionResult
        let title: String
        let content: String
        let kind: String
    }

    private var corpus: [FoldedResult]?

    /// How many times the folded corpus has been built. The saving is "not
    /// rebuilt per keystroke", which is a statement about how often this runs,
    /// so it is the thing a test can hold to.
    private(set) var corpusBuildCount = 0

    /// Drops the folded corpus so the next search rebuilds it.
    ///
    /// Called from `NotchViewModel` when clipboard, snippets or notes announce
    /// a change. `objectWillChange` fires before the value lands, so the cache
    /// is already gone by the time anything can read the new one — the next
    /// search sees the new data, never the old.
    func invalidateCorpus() {
        corpus = nil
    }

    /// The folded corpus for a non-empty query, rebuilt only when the sources
    /// have changed rather than on every keystroke.
    ///
    /// Searching folded every row's title, searchable value and kind — three
    /// `String.folding` calls per row, each allocating, over up to 16 KiB — and
    /// did it again for every letter typed. Typing is exactly when it happened,
    /// and the pane calls this from `body`.
    ///
    /// The count check is a safety net, not the mechanism: invalidation is
    /// driven by the stores' own announcements, and a corpus that disagrees
    /// with the arrays it was handed is rebuilt rather than trusted.
    private func foldedCorpus(
        clipboard: [ClipItem],
        snippets: [Snippet],
        notes: [Note]
    ) -> [FoldedResult] {
        let expected = clipboard.count + snippets.count + notes.count
        if let corpus, corpus.count == expected { return corpus }

        let built = makeResults(clipboard: clipboard, snippets: snippets, notes: notes).map {
            FoldedResult(
                result: $0,
                title: Self.fold($0.title),
                content: Self.fold(Self.searchableValue(of: $0)),
                kind: Self.fold($0.contentKind.title)
            )
        }
        corpus = built
        corpusBuildCount += 1
        return built
    }

    func results(
        clipboard: [ClipItem],
        snippets: [Snippet],
        notes: [Note]
    ) -> [ImpulsActionResult] {
        let needle = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))

        guard !needle.isEmpty else {
            // The landing state shows ten rows. Building and classifying every
            // note and snippet here made merely opening Actions proportional
            // to the entire local store.
            let recentNotes = notes.lazy
                .filter { !BoundedText.firstLine($0.text, maximumCharacters: 1).isEmpty }
                .prefix(3)
            return makeResults(
                clipboard: Array(clipboard.prefix(4)),
                snippets: Array(snippets.prefix(3)),
                notes: Array(recentNotes)
            )
        }

        let all = foldedCorpus(clipboard: clipboard, snippets: snippets, notes: notes)
        let tokens = needle.split(whereSeparator: \Character.isWhitespace).map(String.init)
        return all.enumerated().compactMap { order, folded -> Ranked? in
            let result = folded.result
            let title = folded.title
            let content = folded.content
            let kind = folded.kind
            guard tokens.allSatisfy({ token in
                title.contains(token) || content.contains(token) || kind.contains(token)
            }) else { return nil }

            var score = sourcePriority(result.source) + (result.isPinned ? 500 : 0)
            if title == needle { score += 1_000 }
            else if title.hasPrefix(needle) { score += 700 }
            else if title.contains(needle) { score += 450 }
            if content.hasPrefix(needle) { score += 300 }
            else if content.contains(needle) { score += 180 }
            if kind == needle { score += 220 }
            score += tokens.reduce(0) { partial, token in
                partial + (title.hasPrefix(token) ? 80 : title.contains(token) ? 40 : 10)
            }
            return Ranked(result: result, score: score, order: order)
        }
        .sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.order < rhs.order : lhs.score > rhs.score
        }
        .prefix(30)
        .map(\.result)
    }

    private func makeResults(
        clipboard: [ClipItem],
        snippets: [Snippet],
        notes: [Note]
    ) -> [ImpulsActionResult] {
        let clips = clipboard.map { item in
            let value: ImpulsActionValue
            let title: String
            let detail: String
            switch item.payload {
            case .text(let text):
                value = .text(text)
                title = Self.summary(text)
                detail = item.contentKind.title
            case .file(let url):
                value = .file(url)
                title = url.lastPathComponent
                detail = url.deletingLastPathComponent().path
            }
            return ImpulsActionResult(
                origin: .clipboard(item.id),
                source: .clipboard,
                title: title,
                detail: detail,
                value: value,
                contentKind: item.contentKind,
                isPinned: item.isPinned
            )
        }

        // A pinned file (IMP-39) is deliberately absent from Actions search.
        // Not because Actions cannot carry a file — `ImpulsActionValue.file`
        // exists and clipboard file items already use it — but because a pin
        // means more here than "a file": it also has Open, Reveal, re-select
        // and an unavailable state, none of which an Actions row expresses.
        // Surfacing half of that under the same name is worse than leaving the
        // pin where its full behaviour lives. 1.4.16 keeps it in its own pane.
        let saved = snippets.filter { !$0.isFile }.map { snippet in
            let kind = ClipboardContentClassifier.kind(for: snippet.text)
            return ImpulsActionResult(
                origin: .snippet(snippet.id),
                source: .snippets,
                title: snippet.displayLabel.isEmpty ? Self.summary(snippet.text) : snippet.displayLabel,
                detail: snippet.displayLabel.isEmpty ? kind.title : Self.summary(snippet.text),
                value: .text(snippet.text),
                contentKind: kind,
                isPinned: false
            )
        }

        let drafts = notes.compactMap { note -> ImpulsActionResult? in
            guard !BoundedText.firstLine(note.text, maximumCharacters: 1).isEmpty else { return nil }
            let kind = ClipboardContentClassifier.kind(for: note.text)
            return ImpulsActionResult(
                origin: .note(note.id),
                source: .notes,
                title: Self.summary(note.text),
                detail: kind.title,
                value: .text(note.text),
                contentKind: kind,
                isPinned: false
            )
        }

        return clips + saved + drafts
    }

    static func searchableValue(of result: ImpulsActionResult) -> String {
        switch result.value {
        case .text(let text): return boundedSearchValue(detail: result.detail, value: text)
        case .file(let url): return boundedSearchValue(detail: result.detail, value: url.path)
        }
    }

    private static func boundedSearchValue(detail: String, value: String) -> String {
        var output = String(detail.prefix(maximumSearchCharacters))
        guard output.count < maximumSearchCharacters else { return output }
        output.append("\n")
        let remaining = maximumSearchCharacters - output.count
        if remaining > 0 { output.append(contentsOf: value.prefix(remaining)) }
        return output
    }

    private func sourcePriority(_ source: ImpulsActionSource) -> Int {
        switch source {
        case .snippets: return 30
        case .notes: return 20
        case .clipboard: return 10
        }
    }

    private static func summary(_ text: String) -> String {
        let oneLine = BoundedText.firstLine(text, maximumCharacters: maximumSummaryCharacters)
        return oneLine.isEmpty ? localized("Untitled") : oneLine
    }

    private static func fold(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale.current
        )
    }
}
