import AppKit

/// Decides whether a click means "copy" or "open", using the system's own
/// double-click interval.
///
/// The problem it solves: a file pin has to copy on one click and open on two,
/// and a naive implementation copies *and then* opens on a double click — or
/// copies twice. Acting on the first click and undoing it later is not
/// possible once the pasteboard has been overwritten, so the single-click
/// action has to wait until it is known that no second click is coming.
///
/// The wait is `NSEvent.doubleClickInterval`, which follows the setting in
/// System Settings, rather than a constant chosen here. A person who has set a
/// slow double-click gets a correspondingly patient pin; a fast one gets a
/// brisk one. Both the interval and the scheduler are injected so tests are
/// deterministic and never wait on real time.
@MainActor
final class ClickArbiter {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void

    private let interval: () -> TimeInterval
    private let schedule: Schedule
    /// Bumped by every click. A pending single-click closure compares it and
    /// does nothing if another click has happened since — which is how the
    /// second click of a double cancels the first click's action.
    private var generation = 0

    init(
        interval: @escaping () -> TimeInterval = { NSEvent.doubleClickInterval },
        schedule: @escaping Schedule = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.interval = interval
        self.schedule = schedule
    }

    /// `count` is `NSEvent.clickCount`, so the second click of a double arrives
    /// as `2` rather than as a second `1`.
    ///
    /// Only the transition to exactly two acts. A triple click arrives as
    /// 1, 2, 3 — treating "two or more" as a double would open the file twice
    /// on the way past, so anything beyond the second click is dropped.
    func click(count: Int, single: @escaping () -> Void, double: @escaping () -> Void) {
        generation += 1
        guard count < 2 else {
            // The pending single, if any, is already cancelled by the bump
            // above, so a double click performs exactly one action.
            if count == 2 { double() }
            return
        }
        let scheduled = generation
        schedule(interval()) { [weak self] in
            guard let self, self.generation == scheduled else { return }
            single()
        }
    }
}

/// Copy, open and reveal for a pinned file.
///
/// Every action resolves the reference first and fails closed: an unavailable
/// file performs no side effect at all rather than copying a stale path or
/// opening whatever now sits where the file used to be. Each returns whether it
/// acted, which is what the tests assert on.
@MainActor
final class SnippetFileActions {
    private let pasteboard: FilePasteboardWriting
    private let workspace: FileOpening
    private let resolve: (Snippet) -> SnippetFileResolution
    /// Called when resolution produced a fresher bookmark, so a moved or
    /// renamed file keeps working on the next launch instead of only this one.
    private let onRefreshedReference: (Snippet, URL, Data) -> Void

    /// No defaults for the two system seams on purpose: a default would let a
    /// future call site reach the real pasteboard and the real Finder by
    /// omission, which is exactly what the seams exist to prevent.
    init(
        pasteboard: FilePasteboardWriting,
        workspace: FileOpening,
        resolve: @escaping (Snippet) -> SnippetFileResolution,
        onRefreshedReference: @escaping (Snippet, URL, Data) -> Void
    ) {
        self.pasteboard = pasteboard
        self.workspace = workspace
        self.resolve = resolve
        self.onRefreshedReference = onRefreshedReference
    }

    @discardableResult
    func copy(_ snippet: Snippet) -> Bool {
        perform(snippet) { pasteboard.writeFile($0) }
    }

    @discardableResult
    func open(_ snippet: Snippet) -> Bool {
        perform(snippet) { workspace.open($0) }
    }

    @discardableResult
    func reveal(_ snippet: Snippet) -> Bool {
        perform(snippet) { workspace.revealInFinder($0) }
    }

    /// Resolution alone, for the row that needs to know whether to draw itself
    /// as available. Performs no action and no write-back.
    func isAvailable(_ snippet: Snippet) -> Bool {
        if case .resolved = resolve(snippet) { return true }
        return false
    }

    private func perform(_ snippet: Snippet, _ action: (URL) -> Void) -> Bool {
        guard snippet.isFile else { return false }
        guard case .resolved(let url, let refreshed) = resolve(snippet) else { return false }
        if let refreshed { onRefreshedReference(snippet, url, refreshed) }
        action(url)
        return true
    }
}
