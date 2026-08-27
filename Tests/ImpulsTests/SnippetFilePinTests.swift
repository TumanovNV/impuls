import AppKit
import XCTest
@testable import ImpulsCore

/// Records what would have been put on the pasteboard.
///
/// The point of the seam: a test that copied for real would overwrite whatever
/// the person running the suite had on their clipboard. Nothing here touches
/// `NSPasteboard.general`.
@MainActor
private final class FakePasteboard: FilePasteboardWriting {
    private(set) var written: [URL] = []
    var succeeds = true
    @discardableResult
    func writeFile(_ url: URL) -> Bool {
        guard succeeds else { return false }
        written.append(url)
        return true
    }
}

/// Records opens and reveals instead of launching Preview, TextEdit or Finder.
@MainActor
private final class FakeWorkspace: FileOpening {
    private(set) var opened: [URL] = []
    private(set) var revealed: [URL] = []
    func open(_ url: URL) { opened.append(url) }
    func revealInFinder(_ url: URL) { revealed.append(url) }
}

/// A resolver that can be held open, so a test can observe the exact moment
/// between "resolution started" and "resolution finished" without measuring
/// wall-clock time — which is what makes the ordering assertion reliable in CI
/// rather than a flaky "must finish within N milliseconds".
private actor ResolverGate: SnippetFileResolving {
    private let result: SnippetFileResolution
    private var isOpen: Bool
    private var called = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releases: [CheckedContinuation<Void, Never>] = []

    init(result: SnippetFileResolution, openImmediately: Bool = false) {
        self.result = result
        self.isOpen = openImmediately
    }

    private(set) var urgencies: [SnippetFileResolver.Urgency] = []
    private(set) var callCount = 0

    func resolve(
        path: String,
        bookmark: Data?,
        urgency: SnippetFileResolver.Urgency
    ) async -> SnippetFileResolution {
        called = true
        callCount += 1
        urgencies.append(urgency)
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        if !isOpen {
            await withCheckedContinuation { releases.append($0) }
        }
        return result
    }

    func observedUrgencies() -> [SnippetFileResolver.Urgency] { urgencies }
    func observedCallCount() -> Int { callCount }

    /// Returns once `resolve` has been entered.
    func waitUntilCalled() async {
        guard !called else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Lets the in-flight resolution finish.
    func release() {
        isOpen = true
        releases.forEach { $0.resume() }
        releases.removeAll()
    }
}

@MainActor
final class SnippetFilePinTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnippetFilePinTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func makeFile(_ name: String, contents: String = "fixture") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeStore() -> SnippetStore {
        SnippetStore(fileURL: directory.appendingPathComponent("snippets.json"))
    }

    private func makeInteraction(
        _ store: SnippetStore,
        pasteboard: FakePasteboard,
        workspace: FakeWorkspace,
        resolver: SnippetFileResolving = LiveSnippetFileResolver(),
        snippet: Snippet? = nil
    ) -> SnippetFilePinInteraction {
        SnippetFilePinInteraction(
            actions: SnippetFileActions(pasteboard: pasteboard, workspace: workspace),
            resolver: resolver,
            onRefreshedReference: { url, bookmark in
                guard let snippet else { return }
                store.updateFileReference(for: snippet, resolvedURL: url, bookmark: bookmark)
            }
        )
    }

    // MARK: - Backward compatibility

    /// The whole point of the optional `file` key: a `snippets.json` written
    /// before 1.4.16 has to keep working, and keep meaning the same thing.
    func testSnippetsWrittenBeforeFilePinsStillDecode() throws {
        let json = """
        [
          {"label": "Office", "text": "info@example.com"},
          {"text": "https://example.com"},
          {"label": "Mobile", "text": "+7 900 000-00-00"}
        ]
        """
        let decoded = try JSONDecoder().decode([Snippet].self, from: Data(json.utf8))

        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded.map(\.text), ["info@example.com", "https://example.com", "+7 900 000-00-00"])
        XCTAssertEqual(decoded[1].label, "", "an absent label still means unnamed")
        for snippet in decoded {
            XCTAssertFalse(snippet.isFile, "nothing written before IMP-39 is a file pin")
            XCTAssertNil(snippet.file)
        }
    }

    /// A file of text snippets must encode exactly as it did before, or every
    /// existing user's hand-edited file gains a key the format never had.
    func testATextSnippetStillEncodesWithoutAFileKey() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode([Snippet(label: "Office", text: "info@example.com")])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(text, #"[{"label":"Office","text":"info@example.com"}]"#)
        XCTAssertFalse(text.contains("file"))
    }

    func testAFilePinRoundTripsThroughTheStoredFormat() throws {
        let url = try makeFile("report.pdf")
        let store = makeStore()
        XCTAssertTrue(store.addFile(url))

        let encoded = try JSONEncoder().encode(store.items)
        let decoded = try JSONDecoder().decode([Snippet].self, from: encoded)

        let pin = try XCTUnwrap(decoded.first)
        XCTAssertTrue(pin.isFile)
        XCTAssertEqual(pin.text, url.path, "the readable path stays in `text`")
        XCTAssertEqual(pin.fileName, "report.pdf")
        XCTAssertNotNil(pin.file?.bookmark)
    }

    /// A hand-written entry with a path and no bookmark is a supported way to
    /// add a pin, because the file is documented as user-editable.
    func testAHandWrittenFilePinWithoutABookmarkResolves() throws {
        let url = try makeFile("hand-written.txt")
        let json = #"[{"text": "\#(url.path)", "file": {}}]"#
        let decoded = try JSONDecoder().decode([Snippet].self, from: Data(json.utf8))
        let pin = try XCTUnwrap(decoded.first)

        XCTAssertTrue(pin.isFile)
        XCTAssertNil(pin.file?.bookmark)
        guard case .resolved(let resolved, let refreshed) = SnippetFileResolver.resolve(
            path: pin.text, bookmark: pin.file?.bookmark
        ) else { return XCTFail("a readable path alone must resolve") }
        XCTAssertEqual(resolved.standardizedFileURL, url.standardizedFileURL)
        XCTAssertNotNil(refreshed, "a bookmark is minted so the next move survives")
    }

    // MARK: - Resolution

    func testAMissingFileResolvesToUnavailableRatherThanGuessing() throws {
        let url = try makeFile("gone.txt")
        let bookmark = SnippetFileResolver.makeBookmark(for: url)
        try FileManager.default.removeItem(at: url)

        XCTAssertEqual(SnippetFileResolver.resolve(path: url.path, bookmark: bookmark), .unavailable)
        XCTAssertEqual(SnippetFileResolver.resolve(path: url.path, bookmark: nil), .unavailable)
    }

    /// Corrupt bytes must fail closed and fall back to the path, never trap.
    func testACorruptBookmarkFallsBackToThePathAndThenFailsClosed() throws {
        let url = try makeFile("intact.txt")
        let corrupt = Data([0x00, 0x01, 0x02, 0x03, 0x04])

        guard case .resolved(let resolved, _) = SnippetFileResolver.resolve(
            path: url.path, bookmark: corrupt
        ) else { return XCTFail("the path is still good, so the pin still works") }
        XCTAssertEqual(resolved.standardizedFileURL, url.standardizedFileURL)

        XCTAssertEqual(
            SnippetFileResolver.resolve(path: directory.appendingPathComponent("nope").path, bookmark: corrupt),
            .unavailable
        )
    }

    /// A rename is the case a bare path cannot survive and a bookmark can.
    func testARenamedFileIsFollowedAndTheReferenceIsRefreshed() throws {
        let original = try makeFile("before.txt")
        let store = makeStore()
        XCTAssertTrue(store.addFile(original))
        let pin = try XCTUnwrap(store.items.first)

        let renamed = directory.appendingPathComponent("after.txt")
        try FileManager.default.moveItem(at: original, to: renamed)

        guard case .resolved(let resolved, let refreshed) = SnippetFileResolver.resolve(
            path: pin.text, bookmark: pin.file?.bookmark
        ) else {
            return XCTFail("a renamed file should still resolve through its bookmark")
        }
        XCTAssertEqual(resolved.standardizedFileURL, renamed.standardizedFileURL)
        XCTAssertNotNil(refreshed, "the stale bookmark is refreshed so the next launch works too")
    }

    func testADirectoryIsNotAcceptedAsAFilePin() throws {
        let store = makeStore()
        XCTAssertFalse(store.addFile(directory), "a folder is out of scope, not half-supported")
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(SnippetFileResolver.isReadableRegularFile(directory))
    }

    // MARK: - Click matrix

    /// The click contract, stated once and in one place.
    ///
    /// A first click copies, a second opens, and nothing beyond that acts. The
    /// previous contract deferred the copy by `NSEvent.doubleClickInterval`
    /// (500 ms on the machine this was measured on) so a double click could
    /// avoid copying; real-Mac QA rejected that as unusably slow, and a double
    /// click copying once then opening once is the accepted trade.
    func testAClickMeansTheClickItIsWithNoDeferral() {
        XCTAssertEqual(SnippetFilePinInteraction.effect(forClickCount: 1), .copy)
        XCTAssertEqual(SnippetFilePinInteraction.effect(forClickCount: 2), .open)
        for count in 3...6 {
            XCTAssertNil(
                SnippetFilePinInteraction.effect(forClickCount: count),
                "a \(count)-click must not act again"
            )
        }
    }

    /// One click on a resolved row: one copy, no open, and — the point of the
    /// fix — synchronously, with no suspension between click and pasteboard.
    func testASingleClickOnAResolvedRowCopiesSynchronouslyAndOpensNothing() async throws {
        let url = try makeFile("single.txt")
        let store = makeStore()
        XCTAssertTrue(store.addFile(url))
        let pin = try XCTUnwrap(store.items.first)

        let pasteboard = FakePasteboard()
        let workspace = FakeWorkspace()
        let interaction = makeInteraction(store, pasteboard: pasteboard, workspace: workspace, snippet: pin)
        // The background probe has run, as it has for any visible row.
        _ = await interaction.resolveAndPerform(nil, for: pin, urgency: .probe)
        XCTAssertTrue(pasteboard.written.isEmpty, "probing must not copy anything")

        let acted = interaction.performIfResolved(.copy, for: pin)

        XCTAssertTrue(acted, "a resolved row acts on the spot rather than suspending")
        XCTAssertEqual(pasteboard.written.map(\.standardizedFileURL), [url.standardizedFileURL])
        XCTAssertTrue(workspace.opened.isEmpty, "a single click must never open the file")
    }

    /// The whole double-click sequence AppKit delivers: clickCount 1, then 2.
    /// One copy and one open, each exactly once.
    func testADoubleClickCopiesOnceThenOpensOnce() async throws {
        let url = try makeFile("double.txt")
        let store = makeStore()
        XCTAssertTrue(store.addFile(url))
        let pin = try XCTUnwrap(store.items.first)

        let pasteboard = FakePasteboard()
        let workspace = FakeWorkspace()
        let interaction = makeInteraction(store, pasteboard: pasteboard, workspace: workspace, snippet: pin)
        _ = await interaction.resolveAndPerform(nil, for: pin, urgency: .probe)

        for count in [1, 2] {
            let effect = try XCTUnwrap(SnippetFilePinInteraction.effect(forClickCount: count))
            XCTAssertTrue(interaction.performIfResolved(effect, for: pin))
        }

        XCTAssertEqual(pasteboard.written.count, 1, "exactly one copy")
        XCTAssertEqual(workspace.opened.count, 1, "exactly one open")
        XCTAssertEqual(workspace.opened.first?.standardizedFileURL, url.standardizedFileURL)
    }

    /// A third click must add nothing — no second open, no extra copy.
    func testATripleClickAddsNothingBeyondTheDoubleClick() async throws {
        let url = try makeFile("triple.txt")
        let store = makeStore()
        XCTAssertTrue(store.addFile(url))
        let pin = try XCTUnwrap(store.items.first)

        let pasteboard = FakePasteboard()
        let workspace = FakeWorkspace()
        let interaction = makeInteraction(store, pasteboard: pasteboard, workspace: workspace, snippet: pin)
        _ = await interaction.resolveAndPerform(nil, for: pin, urgency: .probe)

        for count in [1, 2, 3, 4] {
            guard let effect = SnippetFilePinInteraction.effect(forClickCount: count) else { continue }
            XCTAssertTrue(interaction.performIfResolved(effect, for: pin))
        }

        XCTAssertEqual(pasteboard.written.count, 1)
        XCTAssertEqual(workspace.opened.count, 1)
    }

    /// The architecture guard: with an unresolved row the side effect must not
    /// happen until resolution has finished, and resolution must not run on the
    /// caller. The fake resolver suspends until released, so this is provable
    /// without timing anything.
    func testAnUnresolvedRowActsOnlyAfterResolutionCompletes() async throws {
        let url = try makeFile("miss.txt")
        let store = makeStore()
        XCTAssertTrue(store.addFile(url))
        let pin = try XCTUnwrap(store.items.first)

        let pasteboard = FakePasteboard()
        let workspace = FakeWorkspace()
        let gate = ResolverGate(result: .resolved(url: url, refreshedBookmark: nil))
        let interaction = makeInteraction(
            store, pasteboard: pasteboard, workspace: workspace, resolver: gate, snippet: pin
        )

        // Nothing is cached, so the synchronous path must decline outright.
        XCTAssertFalse(
            interaction.performIfResolved(.copy, for: pin),
            "a cache miss must not be served synchronously"
        )

        let work = Task { await interaction.resolveAndPerform(.copy, for: pin, urgency: .userAction) }
        await gate.waitUntilCalled()
        XCTAssertTrue(pasteboard.written.isEmpty, "nothing may be written while resolution is still in flight")

        await gate.release()
        _ = await work.value

        XCTAssertEqual(pasteboard.written.count, 1, "and exactly one write once it completes")
        XCTAssertTrue(
            interaction.performIfResolved(.open, for: pin),
            "the resolution is now cached, so the next click is synchronous"
        )
        XCTAssertEqual(workspace.opened.count, 1)
    }

    /// A resolution that fails caches nothing, so a later click cannot be
    /// served from a stale entry.
    func testAFailedResolutionLeavesNothingCached() async throws {
        let store = makeStore()
        let pasteboard = FakePasteboard()
        let workspace = FakeWorkspace()
        let gate = ResolverGate(result: .unavailable, openImmediately: true)
        let interaction = makeInteraction(store, pasteboard: pasteboard, workspace: workspace, resolver: gate)

        let ghost = Snippet(text: "/nowhere/gone.txt", file: SnippetFileReference())
        let url = await interaction.resolveAndPerform(.copy, for: ghost, urgency: .userAction)

        XCTAssertNil(url)
        XCTAssertTrue(pasteboard.written.isEmpty)
        XCTAssertTrue(workspace.opened.isEmpty)
        XCTAssertFalse(interaction.hasResolved(reference: ghost.text))
        XCTAssertFalse(interaction.performIfResolved(.copy, for: ghost))
    }

    /// The cache is keyed by the reference it came from, so a pin that now
    /// points somewhere else can never be served the previous file.
    func testTheCacheIsKeyedSoAReSelectedPinCannotServeTheOldFile() async throws {
        let original = try makeFile("original.txt")
        let replacement = try makeFile("replacement.txt")
        let store = makeStore()
        XCTAssertTrue(store.addFile(original))
        let pin = try XCTUnwrap(store.items.first)

        let pasteboard = FakePasteboard()
        let workspace = FakeWorkspace()
        let interaction = makeInteraction(store, pasteboard: pasteboard, workspace: workspace, snippet: pin)
        _ = await interaction.resolveAndPerform(nil, for: pin, urgency: .probe)
        XCTAssertTrue(interaction.hasResolved(reference: original.path))

        // The pin is re-pointed; the row now carries a different reference.
        XCTAssertTrue(store.replaceFile(pin, with: replacement))
        let updated = try XCTUnwrap(store.items.first)
        XCTAssertEqual(updated.text, replacement.path)

        XCTAssertFalse(
            interaction.performIfResolved(.copy, for: updated),
            "the cached entry belongs to the old reference and must not be used"
        )
        XCTAssertTrue(pasteboard.written.isEmpty, "so nothing was copied from the previous file")

        _ = await interaction.resolveAndPerform(.copy, for: updated, urgency: .userAction)
        XCTAssertEqual(
            pasteboard.written.map(\.standardizedFileURL), [replacement.standardizedFileURL],
            "and the new file is what gets copied"
        )
    }

    func testExplicitCopyOpenAndRevealEachActOnce() async throws {
        let url = try makeFile("explicit.txt")
        let store = makeStore()
        XCTAssertTrue(store.addFile(url))
        let pin = try XCTUnwrap(store.items.first)

        let pasteboard = FakePasteboard()
        let workspace = FakeWorkspace()
        let interaction = makeInteraction(store, pasteboard: pasteboard, workspace: workspace, snippet: pin)
        _ = await interaction.resolveAndPerform(nil, for: pin, urgency: .probe)

        // The context menu and the accessibility actions take this same path.
        for effect in [SnippetFileActions.Effect.copy, .open, .reveal] {
            XCTAssertTrue(interaction.performIfResolved(effect, for: pin))
        }

        XCTAssertEqual(pasteboard.written.count, 1)
        XCTAssertEqual(workspace.opened.count, 1)
        XCTAssertEqual(workspace.revealed.count, 1)
        XCTAssertEqual(workspace.revealed.first?.standardizedFileURL, url.standardizedFileURL)
    }

    /// Fail closed: a pin whose file is gone performs no side effect at all.
    func testAnUnavailableFileNeitherCopiesNorOpensNorReveals() async throws {
        let url = try makeFile("vanishing.txt")
        let store = makeStore()
        XCTAssertTrue(store.addFile(url))
        let pin = try XCTUnwrap(store.items.first)
        try FileManager.default.removeItem(at: url)

        let pasteboard = FakePasteboard()
        let workspace = FakeWorkspace()
        let interaction = makeInteraction(store, pasteboard: pasteboard, workspace: workspace, snippet: pin)

        for effect in [SnippetFileActions.Effect.copy, .open, .reveal] {
            XCTAssertFalse(interaction.performIfResolved(effect, for: pin))
            let url = await interaction.resolveAndPerform(effect, for: pin, urgency: .userAction)
            XCTAssertNil(url)
        }

        XCTAssertTrue(pasteboard.written.isEmpty)
        XCTAssertTrue(workspace.opened.isEmpty)
        XCTAssertTrue(workspace.revealed.isEmpty)
        XCTAssertEqual(store.items.count, 1, "the pin stays; it is unavailable, not deleted")
    }

    /// A click arriving while the row's own probe is still running must ride
    /// that probe rather than issuing a second resolve and queueing behind it.
    func testAClickDuringAnInFlightProbeSharesItRatherThanResolvingTwice() async throws {
        let url = try makeFile("shared-probe.txt")
        let store = makeStore()
        XCTAssertTrue(store.addFile(url))
        let pin = try XCTUnwrap(store.items.first)

        let pasteboard = FakePasteboard()
        let workspace = FakeWorkspace()
        let gate = ResolverGate(result: .resolved(url: url, refreshedBookmark: nil))
        let interaction = makeInteraction(
            store, pasteboard: pasteboard, workspace: workspace, resolver: gate, snippet: pin
        )

        // The background probe starts first and is held open.
        let probe = Task { await interaction.resolveAndPerform(nil, for: pin, urgency: .probe) }
        await gate.waitUntilCalled()
        // Then the user clicks, before the probe has landed.
        let click = Task { await interaction.resolveAndPerform(.copy, for: pin, urgency: .userAction) }

        await gate.release()
        _ = await probe.value
        _ = await click.value

        let calls = await gate.observedCallCount()
        XCTAssertEqual(calls, 1, "the click must share the in-flight probe, not start a second resolve")
        XCTAssertEqual(pasteboard.written.count, 1, "and it still copies exactly once")
    }

    /// A user-initiated resolve must not be scheduled as speculative work; it
    /// has its own queue so it is never behind other rows' probes.
    func testAUserActionResolvesWithUserActionUrgency() async throws {
        let url = try makeFile("urgent.txt")
        let store = makeStore()
        XCTAssertTrue(store.addFile(url))
        let pin = try XCTUnwrap(store.items.first)

        let gate = ResolverGate(result: .resolved(url: url, refreshedBookmark: nil), openImmediately: true)
        let interaction = makeInteraction(
            store, pasteboard: FakePasteboard(), workspace: FakeWorkspace(), resolver: gate, snippet: pin
        )

        _ = await interaction.resolveAndPerform(nil, for: pin, urgency: .probe)
        let afterProbe = await gate.observedUrgencies()
        XCTAssertEqual(afterProbe, [.probe])

        // A different reference, so the cache cannot serve it.
        let other = Snippet(text: url.path + ".other", file: SnippetFileReference())
        _ = await interaction.resolveAndPerform(.copy, for: other, urgency: .userAction)
        let all = await gate.observedUrgencies()
        XCTAssertEqual(all, [.probe, .userAction], "a click resolves as a user action")
    }

    /// A text snippet has no file. The guard used to live only in the view,
    /// where no test could reach it.
    func testATextSnippetIsNeverTreatedAsAFile() async throws {
        let store = makeStore()
        store.add(label: "Office", text: "info@example.com")
        let snippet = try XCTUnwrap(store.items.first)

        let pasteboard = FakePasteboard()
        let workspace = FakeWorkspace()
        let interaction = makeInteraction(store, pasteboard: pasteboard, workspace: workspace)

        for effect in [SnippetFileActions.Effect.copy, .open, .reveal] {
            XCTAssertFalse(interaction.performIfResolved(effect, for: snippet))
            let url = await interaction.resolveAndPerform(effect, for: snippet, urgency: .userAction)
            XCTAssertNil(url, "a snippet's body must never be resolved as a path")
        }
        XCTAssertTrue(pasteboard.written.isEmpty)
        XCTAssertTrue(workspace.opened.isEmpty)
        XCTAssertTrue(workspace.revealed.isEmpty)
    }

    /// `clearContents()` runs before the write, so a refused write leaves the
    /// clipboard emptied. Reporting "Copied" over that would be a lie.
    func testARefusedPasteboardWriteIsNotReportedAsACopy() async throws {
        let url = try makeFile("refused.txt")
        let store = makeStore()
        XCTAssertTrue(store.addFile(url))
        let pin = try XCTUnwrap(store.items.first)

        let pasteboard = FakePasteboard()
        pasteboard.succeeds = false
        let workspace = FakeWorkspace()
        let interaction = makeInteraction(store, pasteboard: pasteboard, workspace: workspace, snippet: pin)
        _ = await interaction.resolveAndPerform(nil, for: pin, urgency: .probe)

        XCTAssertFalse(
            interaction.performIfResolved(.copy, for: pin),
            "a refused write must not report success"
        )
        XCTAssertTrue(pasteboard.written.isEmpty)

        // Open and reveal are unaffected — only a copy can fail this way.
        XCTAssertTrue(interaction.performIfResolved(.open, for: pin))
        XCTAssertEqual(workspace.opened.count, 1)
    }

    // MARK: - Re-select

    func testChoosingTheFileAgainUpdatesTheSamePinAndKeepsItsPlace() throws {
        let store = makeStore()
        let first = try makeFile("first.txt")
        let second = try makeFile("second.txt")
        let replacement = try makeFile("replacement.txt")

        XCTAssertTrue(store.addFile(first))
        XCTAssertTrue(store.addFile(second))
        // Newest first, so `second` is at index 0 and `first` at index 1.
        let target = try XCTUnwrap(store.items.last)
        XCTAssertEqual(target.fileName, "first.txt")

        XCTAssertTrue(store.replaceFile(target, with: replacement))

        XCTAssertEqual(store.items.count, 2, "re-select edits a pin; it never adds one")
        XCTAssertEqual(store.items[1].fileName, "replacement.txt", "and it stays where it was")
        XCTAssertEqual(store.items[0].fileName, "second.txt", "the other pins are untouched")
    }

    func testReSelectingWithAnUnusableFileChangesNothing() throws {
        let url = try makeFile("kept.txt")
        let store = makeStore()
        XCTAssertTrue(store.addFile(url))
        let pin = try XCTUnwrap(store.items.first)

        XCTAssertFalse(store.replaceFile(pin, with: directory), "a folder is not a replacement")
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.fileName, "kept.txt")
    }

    /// The adversarial review's find: `replaceFile` wrote the new reference
    /// without deduping, so pointing one pin at a file another pin already held
    /// produced two rows with the same derived id — and `remove` deletes by id,
    /// so deleting one silently deleted both.
    func testReSelectingOntoAFileAnotherPinHoldsDoesNotProduceTwoRowsWithOneIdentity() throws {
        let shared = try makeFile("shared.txt")
        let other = try makeFile("other.txt")
        let store = makeStore()

        XCTAssertTrue(store.addFile(shared))
        XCTAssertTrue(store.addFile(other))
        let target = try XCTUnwrap(store.items.first { $0.fileName == "other.txt" })

        XCTAssertTrue(store.replaceFile(target, with: shared))

        let ids = store.items.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "two rows must never share an identity")
        XCTAssertEqual(store.items.count, 1, "the duplicate replaces the older entry")

        // And the surviving row is still deletable without taking anything else.
        store.remove(try XCTUnwrap(store.items.first))
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    /// `isRegularFileKey` reports on the link itself, so without resolving it
    /// first a perfectly good symlink to a readable file was refused.
    func testALiveSymlinkIsAcceptedAndADeadOneIsNot() throws {
        let target = try makeFile("target.txt")
        let live = directory.appendingPathComponent("live.link")
        try FileManager.default.createSymbolicLink(at: live, withDestinationURL: target)
        let dead = directory.appendingPathComponent("dead.link")
        try FileManager.default.createSymbolicLink(
            at: dead, withDestinationURL: directory.appendingPathComponent("nothing.txt")
        )

        XCTAssertTrue(SnippetFileResolver.isReadableRegularFile(live))
        XCTAssertFalse(SnippetFileResolver.isReadableRegularFile(dead))

        let store = makeStore()
        XCTAssertTrue(store.addFile(live), "a working symlink points at a real file")
        XCTAssertFalse(store.addFile(dead))
    }

    /// A file package is a directory. It is out of scope, and it has to be
    /// refused rather than half-pinned.
    func testAFilePackageIsRejected() throws {
        let package = directory.appendingPathComponent("Document.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try "body".write(to: package.appendingPathComponent("TXT.rtf"), atomically: true, encoding: .utf8)

        XCTAssertFalse(SnippetFileResolver.isReadableRegularFile(package))
        let store = makeStore()
        XCTAssertFalse(store.addFile(package))
        XCTAssertTrue(store.items.isEmpty)
    }

    /// A zero-byte file is still a file. Nothing reads its contents, so there is
    /// no reason to refuse it.
    func testAZeroByteFileIsAcceptable() throws {
        let empty = try makeFile("empty.txt", contents: "")
        XCTAssertTrue(SnippetFileResolver.isReadableRegularFile(empty))
        let store = makeStore()
        XCTAssertTrue(store.addFile(empty))
    }

    // MARK: - Removal safety

    /// The safety regression that matters most: removing a pin removes a row,
    /// and the user's file stays exactly where it was.
    func testRemovingAPinLeavesTheRealFileOnDisk() throws {
        let url = try makeFile("precious.txt", contents: "do not delete me")
        let store = makeStore()
        XCTAssertTrue(store.addFile(url))
        let pin = try XCTUnwrap(store.items.first)

        store.remove(pin)

        XCTAssertTrue(store.items.isEmpty, "the row is gone")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "removing a pin must never delete, trash or move the user's file"
        )
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "do not delete me")
    }

    /// A bookmark carries the volume name, the volume UUID and the inode, and
    /// a backup is portable by definition. It has to be dropped on the way out
    /// — the path is the part that can meaningfully transfer.
    func testABackupCarriesThePathButNeverTheBookmark() throws {
        let url = try makeFile("exported.txt")
        let store = makeStore()
        XCTAssertTrue(store.addFile(url))
        let pin = try XCTUnwrap(store.items.first)
        XCTAssertNotNil(pin.file?.bookmark, "the live pin does have one")

        let document = ImpulsBackupDocument(
            settings: ImpulsSettingsSnapshot(
                hotKey: .optionShiftSpace,
                activationMode: .hoverAndShortcut,
                openDelay: .balanced,
                panelSize: .compact,
                selectedDisplayID: nil,
                modules: [],
                saveClipboardImages: false,
                persistClipboardHistory: false,
                clipboardRetention: .sevenDays,
                excludedClipboardBundleIdentifiers: []
            ),
            snippets: store.items,
            notes: []
        )

        let exported = try XCTUnwrap(document.snippets.first)
        XCTAssertTrue(exported.isFile, "it is still a file pin")
        XCTAssertEqual(exported.text, url.path, "the readable path travels")
        XCTAssertNil(exported.file?.bookmark, "the machine-local blob does not")

        // And nothing of it survives in the encoded bytes either.
        let encoded = try JSONEncoder().encode(document)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("bookmark"), "no bookmark key reaches the file")

        // The live store is untouched by having been exported.
        XCTAssertNotNil(store.items.first?.file?.bookmark)
    }

    /// The rename write-back path had no assertions at all: it is what keeps a
    /// moved file working on the next launch, and it applies the same identity
    /// rule as re-select.
    func testTheRenameWriteBackUpdatesInPlaceAndCannotDuplicateAnIdentity() throws {
        let first = try makeFile("one.txt")
        let second = try makeFile("two.txt")
        let store = makeStore()
        XCTAssertTrue(store.addFile(first))
        XCTAssertTrue(store.addFile(second))

        let target = try XCTUnwrap(store.items.first { $0.fileName == "one.txt" })
        let index = try XCTUnwrap(store.items.firstIndex { $0.id == target.id })
        let bookmark = try XCTUnwrap(SnippetFileResolver.makeBookmark(for: first))

        // Point it at a path another pin already holds — the collision case.
        store.updateFileReference(for: target, resolvedURL: second, bookmark: bookmark)

        let ids = store.items.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "no two rows may share an identity")
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items[0].fileName, "two.txt")
        XCTAssertEqual(index, 1)
    }

    /// The other half of the write-back's contract, and the half the collision
    /// case cannot show: with no duplicate to collapse, the row must be rewritten
    /// where it stands rather than removed and re-inserted.
    func testTheRenameWriteBackKeepsTheRowWhereItWas() throws {
        let first = try makeFile("alpha.txt")
        let second = try makeFile("beta.txt")
        let renamed = try makeFile("beta-renamed.txt")
        let store = makeStore()
        XCTAssertTrue(store.addFile(first))
        XCTAssertTrue(store.addFile(second))
        XCTAssertEqual(store.items.map(\.fileName), ["beta.txt", "alpha.txt"])

        let target = try XCTUnwrap(store.items.first { $0.fileName == "beta.txt" })
        let bookmark = try XCTUnwrap(SnippetFileResolver.makeBookmark(for: renamed))
        store.updateFileReference(for: target, resolvedURL: renamed, bookmark: bookmark)

        XCTAssertEqual(
            store.items.map(\.fileName), ["beta-renamed.txt", "alpha.txt"],
            "the rewritten row keeps its position and the others do not move"
        )
        XCTAssertEqual(store.items[0].file?.bookmark, bookmark)
    }

    // MARK: - Persistence across a relaunch

    func testAFilePinSurvivesAStoreBeingRecreated() throws {
        let url = try makeFile("persisted.txt")
        let storeURL = directory.appendingPathComponent("snippets.json")

        let first = SnippetStore(fileURL: storeURL)
        XCTAssertTrue(first.addFile(url))
        first.flushSynchronously()

        let second = SnippetStore(fileURL: storeURL)
        second.reload()

        XCTAssertEqual(second.items.count, 1)
        let pin = try XCTUnwrap(second.items.first)
        XCTAssertTrue(pin.isFile)
        XCTAssertEqual(pin.fileName, "persisted.txt")
        guard case .resolved(let resolved, _) = SnippetFileResolver.resolve(
            path: pin.text, bookmark: pin.file?.bookmark
        ) else {
            return XCTFail("a reloaded pin should still resolve")
        }
        XCTAssertEqual(resolved.standardizedFileURL, url.standardizedFileURL)
    }

    /// Mixed old and new content in one file, which is what an upgraded user
    /// actually has.
    func testAFileOfTextSnippetsAndFilePinsLoadsTogether() throws {
        let url = try makeFile("mixed.txt")
        let storeURL = directory.appendingPathComponent("snippets.json")

        let first = SnippetStore(fileURL: storeURL)
        first.add(label: "Office", text: "info@example.com")
        XCTAssertTrue(first.addFile(url))
        first.add(label: "Portal", text: "https://example.com")
        first.flushSynchronously()

        let second = SnippetStore(fileURL: storeURL)
        second.reload()

        XCTAssertEqual(second.items.count, 3)
        XCTAssertEqual(second.items.filter(\.isFile).count, 1)
        XCTAssertEqual(second.items.filter { !$0.isFile }.map(\.text).sorted(),
                       ["https://example.com", "info@example.com"])
    }
}
