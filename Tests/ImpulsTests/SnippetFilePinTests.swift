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
    func writeFile(_ url: URL) { written.append(url) }
}

/// Records opens and reveals instead of launching Preview, TextEdit or Finder.
@MainActor
private final class FakeWorkspace: FileOpening {
    private(set) var opened: [URL] = []
    private(set) var revealed: [URL] = []
    func open(_ url: URL) { opened.append(url) }
    func revealInFinder(_ url: URL) { revealed.append(url) }
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

    private func makeActions(
        _ store: SnippetStore,
        pasteboard: FakePasteboard,
        workspace: FakeWorkspace
    ) -> SnippetFileActions {
        SnippetFileActions(
            pasteboard: pasteboard,
            workspace: workspace,
            resolve: { store.resolveFile($0) },
            onRefreshedReference: { snippet, url, bookmark in
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

        guard case .resolved(let resolved, let refreshed) = store.resolveFile(pin) else {
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

    func testASingleClickCopiesTheFileAndOpensNothing() throws {
        let url = try makeFile("single.txt")
        let store = makeStore()
        XCTAssertTrue(store.addFile(url))
        let pin = try XCTUnwrap(store.items.first)

        let pasteboard = FakePasteboard()
        let workspace = FakeWorkspace()
        let actions = makeActions(store, pasteboard: pasteboard, workspace: workspace)

        var pending: [() -> Void] = []
        let arbiter = ClickArbiter(interval: { 0.25 }, schedule: { _, work in pending.append(work) })
        arbiter.click(count: 1, single: { actions.copy(pin) }, double: { actions.open(pin) })

        XCTAssertTrue(pasteboard.written.isEmpty, "nothing happens until the double-click window closes")
        pending.forEach { $0() }

        XCTAssertEqual(pasteboard.written.map(\.standardizedFileURL), [url.standardizedFileURL])
        XCTAssertTrue(workspace.opened.isEmpty, "a single click must never open the file")
    }

    /// The regression this whole arbiter exists for: a double click must not
    /// produce copy+open, and must not open twice.
    func testADoubleClickOpensOnceAndNeverCopies() throws {
        let url = try makeFile("double.txt")
        let store = makeStore()
        XCTAssertTrue(store.addFile(url))
        let pin = try XCTUnwrap(store.items.first)

        let pasteboard = FakePasteboard()
        let workspace = FakeWorkspace()
        let actions = makeActions(store, pasteboard: pasteboard, workspace: workspace)

        var pending: [() -> Void] = []
        let arbiter = ClickArbiter(interval: { 0.25 }, schedule: { _, work in pending.append(work) })
        // Exactly what AppKit delivers for a double click: clickCount 1, then 2.
        arbiter.click(count: 1, single: { actions.copy(pin) }, double: { actions.open(pin) })
        arbiter.click(count: 2, single: { actions.copy(pin) }, double: { actions.open(pin) })
        // The first click's pending work still fires; it must find itself stale.
        pending.forEach { $0() }

        XCTAssertEqual(workspace.opened.count, 1, "one double click opens the file exactly once")
        XCTAssertTrue(pasteboard.written.isEmpty, "the cancelled single click must not have copied")
    }

    func testATripleClickStillOpensOnlyOnce() throws {
        let url = try makeFile("triple.txt")
        let store = makeStore()
        XCTAssertTrue(store.addFile(url))
        let pin = try XCTUnwrap(store.items.first)

        let pasteboard = FakePasteboard()
        let workspace = FakeWorkspace()
        let actions = makeActions(store, pasteboard: pasteboard, workspace: workspace)

        var pending: [() -> Void] = []
        let arbiter = ClickArbiter(interval: { 0.25 }, schedule: { _, work in pending.append(work) })
        arbiter.click(count: 1, single: { actions.copy(pin) }, double: { actions.open(pin) })
        arbiter.click(count: 2, single: { actions.copy(pin) }, double: { actions.open(pin) })
        arbiter.click(count: 3, single: { actions.copy(pin) }, double: { actions.open(pin) })
        pending.forEach { $0() }

        XCTAssertEqual(workspace.opened.count, 1, "the third click must not open the file a second time")
        XCTAssertTrue(pasteboard.written.isEmpty)
    }

    func testExplicitCopyOpenAndRevealEachActOnce() throws {
        let url = try makeFile("explicit.txt")
        let store = makeStore()
        XCTAssertTrue(store.addFile(url))
        let pin = try XCTUnwrap(store.items.first)

        let pasteboard = FakePasteboard()
        let workspace = FakeWorkspace()
        let actions = makeActions(store, pasteboard: pasteboard, workspace: workspace)

        XCTAssertTrue(actions.copy(pin))
        XCTAssertTrue(actions.open(pin))
        XCTAssertTrue(actions.reveal(pin))

        XCTAssertEqual(pasteboard.written.count, 1)
        XCTAssertEqual(workspace.opened.count, 1)
        XCTAssertEqual(workspace.revealed.count, 1)
        XCTAssertEqual(workspace.revealed.first?.standardizedFileURL, url.standardizedFileURL)
    }

    /// Fail closed: a pin whose file is gone performs no side effect at all,
    /// rather than copying a stale path or opening whatever is there now.
    func testAnUnavailableFileNeitherCopiesNorOpensNorReveals() throws {
        let url = try makeFile("vanishing.txt")
        let store = makeStore()
        XCTAssertTrue(store.addFile(url))
        let pin = try XCTUnwrap(store.items.first)
        try FileManager.default.removeItem(at: url)

        let pasteboard = FakePasteboard()
        let workspace = FakeWorkspace()
        let actions = makeActions(store, pasteboard: pasteboard, workspace: workspace)

        XCTAssertFalse(actions.copy(pin))
        XCTAssertFalse(actions.open(pin))
        XCTAssertFalse(actions.reveal(pin))
        XCTAssertFalse(actions.isAvailable(pin))

        XCTAssertTrue(pasteboard.written.isEmpty)
        XCTAssertTrue(workspace.opened.isEmpty)
        XCTAssertTrue(workspace.revealed.isEmpty)
        XCTAssertEqual(store.items.count, 1, "the pin stays; it is unavailable, not deleted")
    }

    func testATextSnippetIsNeverTreatedAsAFile() throws {
        let store = makeStore()
        store.add(label: "Office", text: "info@example.com")
        let snippet = try XCTUnwrap(store.items.first)

        let pasteboard = FakePasteboard()
        let workspace = FakeWorkspace()
        let actions = makeActions(store, pasteboard: pasteboard, workspace: workspace)

        XCTAssertFalse(actions.copy(snippet))
        XCTAssertFalse(actions.open(snippet))
        XCTAssertTrue(pasteboard.written.isEmpty)
        XCTAssertTrue(workspace.opened.isEmpty)
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
        guard case .resolved(let resolved, _) = second.resolveFile(pin) else {
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
