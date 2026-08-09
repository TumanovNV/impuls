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
    @Published var query = ""

    private struct Ranked {
        let result: ImpulsActionResult
        let score: Int
        let order: Int
    }

    func results(
        clipboard: [ClipItem],
        snippets: [Snippet],
        notes: [Note]
    ) -> [ImpulsActionResult] {
        let all = makeResults(clipboard: clipboard, snippets: snippets, notes: notes)
        let needle = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))

        guard !needle.isEmpty else {
            return Array(all.filter { $0.source == .clipboard }.prefix(4))
                + Array(all.filter { $0.source == .snippets }.prefix(3))
                + Array(all.filter { $0.source == .notes }.prefix(3))
        }

        let tokens = needle.split(whereSeparator: \Character.isWhitespace).map(String.init)
        return all.enumerated().compactMap { order, result -> Ranked? in
            let title = Self.fold(result.title)
            let content = Self.fold(searchableValue(of: result))
            let kind = Self.fold(result.contentKind.title)
            let haystack = title + "\n" + content + "\n" + kind
            guard tokens.allSatisfy({ haystack.contains($0) }) else { return nil }

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

        let saved = snippets.map { snippet in
            let kind = ClipboardContentClassifier.kind(for: snippet.text)
            return ImpulsActionResult(
                origin: .snippet(snippet.id),
                source: .snippets,
                title: snippet.label.isEmpty ? Self.summary(snippet.text) : snippet.label,
                detail: snippet.label.isEmpty ? kind.title : snippet.text,
                value: .text(snippet.text),
                contentKind: kind,
                isPinned: false
            )
        }

        let drafts = notes.compactMap { note -> ImpulsActionResult? in
            let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let kind = ClipboardContentClassifier.kind(for: text)
            return ImpulsActionResult(
                origin: .note(note.id),
                source: .notes,
                title: Self.summary(text),
                detail: kind.title,
                value: .text(note.text),
                contentKind: kind,
                isPinned: false
            )
        }

        return clips + saved + drafts
    }

    private func searchableValue(of result: ImpulsActionResult) -> String {
        switch result.value {
        case .text(let text): return result.detail + "\n" + text
        case .file(let url): return result.detail + "\n" + url.path
        }
    }

    private func sourcePriority(_ source: ImpulsActionSource) -> Int {
        switch source {
        case .snippets: return 30
        case .notes: return 20
        case .clipboard: return 10
        }
    }

    private static func summary(_ text: String) -> String {
        let oneLine = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first ?? ""
        return oneLine.isEmpty ? localized("Untitled") : oneLine
    }

    private static func fold(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale.current
        )
    }
}
