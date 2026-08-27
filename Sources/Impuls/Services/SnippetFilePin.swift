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
enum SnippetFileResolution: Equatable, Sendable {
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

    /// One serial queue for every automatic availability probe.
    ///
    /// Not the shared cooperative pool, and deliberately: the path fallback can
    /// block for a mount timeout, and a detached task per row would put N of
    /// those stalls into the pool that `FileTools`, translation and telemetry
    /// also run on. Here a stalled mount occupies exactly this one queue, which
    /// is what "background work has an owner" means.
    private static let probeQueue = DispatchQueue(
        label: "io.tumanov.impuls.snippets.file-probe",
        qos: .utility
    )

    /// The automatic form of `resolve`, off the main actor and serialized.
    static func resolveOffMainActor(path: String, bookmark: Data?) async -> SnippetFileResolution {
        await withCheckedContinuation { continuation in
            probeQueue.async {
                continuation.resume(returning: resolve(path: path, bookmark: bookmark))
            }
        }
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

    /// A pin points at one regular file. A directory, a file package, a dead
    /// symlink, a socket or a device is not something this feature claims to
    /// handle, and saying so up front is better than half-working on it.
    ///
    /// A *live* symlink is accepted: `isRegularFileKey` reports on the link
    /// itself, so the target is what gets asked. Resolving first is what makes
    /// a symlink into a real file behave like the file it points at, which is
    /// what someone who pinned it meant.
    static func isReadableRegularFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let target = url.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            return false
        }
        guard !isDirectory.boolValue else { return false }
        let values = try? target.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile ?? false
    }
}

/// Resolution as an injected, asynchronous seam.
///
/// Asynchronous in the protocol itself, so no conforming type can offer the
/// main actor a synchronous filesystem call — which is how the blocking version
/// got into the click path in the first place. A test fake can also suspend on
/// demand, which is what makes "the side effect happens only after resolution"
/// provable without timing anything.
protocol SnippetFileResolving: Sendable {
    func resolve(path: String, bookmark: Data?) async -> SnippetFileResolution
}

struct LiveSnippetFileResolver: SnippetFileResolving {
    func resolve(path: String, bookmark: Data?) async -> SnippetFileResolution {
        await SnippetFileResolver.resolveOffMainActor(path: path, bookmark: bookmark)
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
    /// The completion-handler form, not `open(_:)`. The synchronous variant
    /// blocks its caller until Launch Services has finished launching the
    /// handler — seconds for an application that is not already running — and
    /// this is called from the main actor on a double click. The panel would
    /// sit frozen for the whole launch. This one returns immediately and the
    /// result is deliberately ignored: the file opens or macOS says why, and
    /// either way there is nothing for the pin to do about it.
    func open(_ url: URL) {
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
