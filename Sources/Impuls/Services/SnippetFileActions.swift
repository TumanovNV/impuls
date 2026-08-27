import AppKit

/// The side effects a pinned file supports.
///
/// Separated from resolution on purpose. `SnippetFileActions` takes a URL and
/// performs one effect with it; it has no way to reach the filesystem, so a
/// later edit cannot put a blocking resolve back in front of a click without
/// changing this type's shape. Resolution lives behind `SnippetFileResolving`
/// and is asynchronous by construction.
///
/// The first version of this feature had the opposite arrangement — every
/// action resolved first, on the main actor, behind a deliberate
/// double-click-interval delay — and that is what made the pointer feel frozen.
@MainActor
final class SnippetFileActions {
    enum Effect: Equatable {
        case copy
        case open
        case reveal
    }

    private let pasteboard: FilePasteboardWriting
    private let workspace: FileOpening

    /// No defaults for the two system seams on purpose: a default would let a
    /// future call site reach the real pasteboard and the real Finder by
    /// omission, which is exactly what the seams exist to prevent.
    init(pasteboard: FilePasteboardWriting, workspace: FileOpening) {
        self.pasteboard = pasteboard
        self.workspace = workspace
    }

    /// Performs one effect on an already-resolved URL.
    ///
    /// Synchronous, and that is the point: for a row whose file the background
    /// probe has already resolved, a click is a pasteboard write and nothing
    /// else — no filesystem call, no suspension between the click and the
    /// effect.
    /// Returns whether the effect took. Only a copy can fail — the pasteboard
    /// can refuse the write, and `clearContents()` has already run by then, so
    /// showing "Copied" over that would be a lie about the clipboard's state.
    @discardableResult
    func apply(_ effect: Effect, to url: URL) -> Bool {
        switch effect {
        case .copy: return pasteboard.writeFile(url)
        case .open: workspace.open(url); return true
        case .reveal: workspace.revealInFinder(url); return true
        }
    }
}

/// One row's interaction state: what its file resolved to, and how a click
/// turns into an effect.
///
/// Extracted from the view so the whole contract is testable — the click
/// mapping, the synchronous fast path, the asynchronous miss, and the cache's
/// invalidation rule — rather than only the pieces that happened to be reachable.
@MainActor
final class SnippetFilePinInteraction {
    private let actions: SnippetFileActions
    private let resolver: SnippetFileResolving
    private let onRefreshedReference: (URL, Data) -> Void

    /// The resolved URL together with the reference it came from.
    ///
    /// Keyed rather than bare, and that is the whole staleness rule: after a
    /// re-select, a rename write-back or a row being reused for another pin,
    /// the key no longer matches and the cache is simply not used. Transient
    /// runtime state — `Snippet.text` plus `Snippet.file` remain the only
    /// stored source of truth.
    private var cache: (reference: String, url: URL)?

    /// The resolution currently in flight, if any, keyed by its reference.
    ///
    /// Without this a click arriving while the row's own background probe was
    /// still running would issue a second, redundant resolve for the same file
    /// and then queue behind the first. Sharing the task means the click rides
    /// the probe already under way and acts the moment it lands.
    private var inFlight: (reference: String, task: Task<URL?, Never>)?

    init(
        actions: SnippetFileActions,
        resolver: SnippetFileResolving,
        onRefreshedReference: @escaping (URL, Data) -> Void
    ) {
        self.actions = actions
        self.resolver = resolver
        self.onRefreshedReference = onRefreshedReference
    }

    /// What a click of this count means.
    ///
    /// A first click copies and a second opens, each acting on the click it is.
    /// The first click cannot know whether a second is coming, and the earlier
    /// design answered that by waiting out `NSEvent.doubleClickInterval` before
    /// copying — half a second of nothing happening, to buy a double click that
    /// never copies. A double click copying once and then opening once is the
    /// accepted trade. Three clicks and beyond mean nothing, so leaning on the
    /// mouse cannot produce a storm.
    static func effect(forClickCount count: Int) -> SnippetFileActions.Effect? {
        switch count {
        case 1: return .copy
        case 2: return .open
        default: return nil
        }
    }

    /// The fast path: acts synchronously when this reference is already
    /// resolved, and reports whether it did. No filesystem call, no suspension
    /// — for a visible row a click is a pasteboard write and nothing else.
    @discardableResult
    func performIfResolved(_ effect: SnippetFileActions.Effect, for snippet: Snippet) -> Bool {
        // A text snippet has no file to act on. The guard lives here rather than
        // only in the view so it is reachable by a test, and so a future call
        // site cannot resolve a snippet's body as if it were a path.
        guard snippet.isFile else { return false }
        guard let cache, cache.reference == snippet.text else { return false }
        return actions.apply(effect, to: cache.url)
    }

    /// The miss path, and the probe. Resolves off the main actor and then acts;
    /// pass `nil` to resolve without acting, which is what the background probe
    /// does to fill the cache before anybody clicks.
    ///
    /// Returns the resolved URL, or nil when the file is gone — in which case
    /// nothing acted.
    @discardableResult
    func resolveAndPerform(
        _ effect: SnippetFileActions.Effect?,
        for snippet: Snippet,
        urgency: SnippetFileResolver.Urgency
    ) async -> URL? {
        guard snippet.isFile else { return nil }
        let reference = snippet.text
        let url = await resolvedURL(reference: reference, bookmark: snippet.file?.bookmark, urgency: urgency)
        guard let url else { return nil }
        if let effect, !actions.apply(effect, to: url) { return nil }
        return url
    }

    /// One resolution per reference at a time, shared by everyone who asks for
    /// it while it is running.
    private func resolvedURL(reference: String, bookmark: Data?, urgency: SnippetFileResolver.Urgency) async -> URL? {
        if let inFlight, inFlight.reference == reference {
            return await inFlight.task.value
        }
        let task = Task { [resolver, onRefreshedReference] () -> URL? in
            let outcome = await resolver.resolve(path: reference, bookmark: bookmark, urgency: urgency)
            guard case .resolved(let url, let refreshed) = outcome else { return nil }
            if let refreshed { onRefreshedReference(url, refreshed) }
            return url
        }
        inFlight = (reference, task)
        let url = await task.value
        if inFlight?.reference == reference { inFlight = nil }
        cache = url.map { (reference, $0) }
        return url
    }

    /// True when this reference is already resolved, so the row can skip
    /// re-probing one it has seen.
    func hasResolved(reference: String) -> Bool { cache?.reference == reference }
}
