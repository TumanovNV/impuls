import AppKit

/// The reference a pinned file keeps between launches.
///
/// The readable half lives in `Snippet.text`, which holds the path. This type
/// carries only the opaque half, because `snippets.json` is documented as
/// user-editable and human-readable: a person can hand-write
/// `{"text": "/Users/me/report.pdf", "file": {}}` and it resolves by path
/// alone. The bookmark is what makes a rename or a move survive; it is an
/// optimisation over the path, never a replacement for it.
///
/// File **contents** are never stored, and nothing here is ever sent anywhere.
struct SnippetFileReference: Codable, Equatable, Sendable {
    /// Opaque bookmark bytes. Optional so a hand-written entry still works, and
    /// so a reference whose bookmark could not be minted is still usable.
    var bookmark: Data?

    init(bookmark: Data? = nil) {
        self.bookmark = bookmark
    }
}

/// What resolving a pinned file produced.
enum SnippetFileResolution: Equatable {
    /// The file is there. `refreshedBookmark` is non-nil only when the stored
    /// bookmark was stale or missing and a fresh one should be written back.
    case resolved(url: URL, refreshedBookmark: Data?)
    /// The file could not be resolved. Impuls does not guess where it went.
    case unavailable
}

/// Turns a stored reference back into a URL, and nothing more.
///
/// Deliberately incapable of searching. There is no recursive scan, no
/// Spotlight query, no filename match and no inode guessing: a reference that
/// does not resolve produces `.unavailable`, and the user is asked to choose
/// the file again. Guessing at a file the user did not point at is how a
/// "helpful" pin ends up copying the wrong document.
enum SnippetFileResolver {
    /// `withoutMounting` is the load-bearing option, not a detail. Resolving a
    /// bookmark that points at an unmounted volume will otherwise try to mount
    /// it — which can block for as long as the volume takes to answer, on
    /// whatever thread asked. With it, an ejected disk answers "unavailable"
    /// immediately, which is exactly what the pin should say. `withoutUI` stops
    /// the same call putting a system dialog in front of the user.
    static let resolutionOptions: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]

    /// Bookmarks are minted without security scope on purpose: Impuls is not
    /// sandboxed (`Impuls.entitlements` carries no `app-sandbox` key), so a
    /// security-scoped bookmark would add ceremony that buys nothing and
    /// implies a containment story the app does not have.
    static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(path: String, bookmark: Data?) -> SnippetFileResolution {
        if let bookmark, let resolved = resolveBookmark(bookmark) {
            return resolved
        }
        // No bookmark, or one that no longer resolves: fall back to the path
        // the file was pinned at. This is the hand-written case too.
        let url = URL(fileURLWithPath: path)
        guard isReadableRegularFile(url) else { return .unavailable }
        // Mint a bookmark so the next rename or move is survivable.
        return .resolved(url: url, refreshedBookmark: makeBookmark(for: url))
    }

    private static func resolveBookmark(_ bookmark: Data) -> SnippetFileResolution? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: resolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        guard isReadableRegularFile(url) else { return nil }
        // A stale bookmark still resolved — it just needs rewriting. Refreshing
        // it in place is what keeps a moved file working on the launch after
        // next, rather than only on this one.
        return .resolved(url: url, refreshedBookmark: isStale ? makeBookmark(for: url) : nil)
    }

    /// A pin points at one regular file. A directory, a symlink to nowhere, a
    /// socket or a device is not something this feature claims to handle, and
    /// saying so up front is better than half-working on it.
    static func isReadableRegularFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        guard !isDirectory.boolValue else { return false }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile ?? false
    }
}

// MARK: - Injected system seams

/// Writing a file to the system pasteboard.
///
/// A seam rather than a direct `NSPasteboard.general` call for one reason: a
/// unit test that copied for real would overwrite whatever the person running
/// the suite had on their clipboard. Tests get a fake and assert what *would*
/// have been written.
@MainActor
protocol FilePasteboardWriting {
    /// Writes the file itself, as a file object other applications can paste.
    func writeFile(_ url: URL)
}

/// Opening and revealing files.
///
/// Same reasoning as the pasteboard seam: a test that opened for real would
/// launch Preview, TextEdit or Finder on the developer's machine.
@MainActor
protocol FileOpening {
    func open(_ url: URL)
    func revealInFinder(_ url: URL)
}

/// Production pasteboard. Writes the URL as a file object — `writeObjects` with
/// an `NSURL` — so ⌘V in Finder pastes the *file*. Writing `url.path` as a
/// string instead would paste the text of the path, which is not the feature.
///
/// The file is never read, never copied and never duplicated into Impuls
/// storage: only the reference goes on the pasteboard.
@MainActor
struct SystemFilePasteboard: FilePasteboardWriting {
    func writeFile(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }
}

/// Production workspace, through public AppKit only.
@MainActor
struct SystemWorkspace: FileOpening {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
