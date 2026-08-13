import XCTest
@testable import ImpulsCore

/// The suite must not be able to reach the notes, snippets or clipboard archive
/// of whoever is running it.
///
/// This is not a hypothetical. `NotchViewModel` builds every store, and until
/// the file locations became a dependency, a test about displays inherited the
/// real `notes.json` and rewrote it on teardown — `stop()` flushes the notes
/// synchronously so nothing typed is lost on quit, and that path does not know
/// it is in a test. One test left a line of its own text in a real file.
///
/// So these tests do not check that persistence was switched off. They check
/// that the real thing happened somewhere else.
@MainActor
final class StorageIsolationTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("impuls-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        folder = nil
        try super.tearDownWithError()
    }

    private func environment() -> StorageEnvironment {
        StorageEnvironment(
            notes: folder.appendingPathComponent("notes.json"),
            snippets: folder.appendingPathComponent("snippets.json"),
            makeClipboardHistory: { nil }
        )
    }

    // MARK: - The store itself

    /// The full round trip through the file, not through memory: a second store
    /// built on the same URL has to see what the first one flushed.
    func testNoteStorePersistsThroughAnInjectedFileAndReadsItBack() throws {
        let url = folder.appendingPathComponent("notes.json")
        let store = NoteStore(fileURL: url)
        XCTAssertEqual(store.fileURL, url)
        XCTAssertNotEqual(store.fileURL, NoteStore.defaultFileURL)

        let id = store.add(text: "written by a test")
        store.update(id, text: "edited by a test")
        store.flushSynchronously()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let reopened = NoteStore(fileURL: url)
        XCTAssertEqual(reopened.notes.count, 1)
        XCTAssertEqual(reopened.notes.first?.text, "edited by a test")
        XCTAssertEqual(reopened.notes.first?.id, id)
    }

    func testNoteStoreRemovalSurvivesReopening() throws {
        let url = folder.appendingPathComponent("notes.json")
        let store = NoteStore(fileURL: url)
        let kept = store.add(text: "kept")
        let removed = store.add(text: "removed")
        store.remove(removed)
        store.flushSynchronously()

        let reopened = NoteStore(fileURL: url)
        XCTAssertEqual(reopened.notes.map(\.id), [kept])
    }

    func testSnippetStorePersistsThroughAnInjectedFileAndReadsItBack() throws {
        let url = folder.appendingPathComponent("snippets.json")
        let store = SnippetStore(fileURL: url)
        XCTAssertEqual(store.fileURL, url)
        XCTAssertNotEqual(store.fileURL, SnippetStore.defaultFileURL)

        store.add(label: "test", text: "value")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let reopened = SnippetStore(fileURL: url)
        reopened.reload()
        XCTAssertEqual(reopened.items.map(\.text), ["value"])
    }

    /// The default is still the real path — the point was to make the location a
    /// dependency, not to move the app's data.
    func testTheDefaultLocationsAreStillTheApplicationSupportFolder() {
        for url in [NoteStore.defaultFileURL, SnippetStore.defaultFileURL] {
            let folder = url.deletingLastPathComponent()
            XCTAssertEqual(folder.lastPathComponent, "Impuls")
            XCTAssertTrue(
                folder.deletingLastPathComponent().path.hasSuffix("Application Support"),
                "\(url.path) is not under Application Support"
            )
        }
        XCTAssertEqual(NoteStore.defaultFileURL.lastPathComponent, "notes.json")
        XCTAssertEqual(SnippetStore.defaultFileURL.lastPathComponent, "snippets.json")
        XCTAssertEqual(StorageEnvironment.live.notes, NoteStore.defaultFileURL)
        XCTAssertEqual(StorageEnvironment.live.snippets, SnippetStore.defaultFileURL)
    }

    // MARK: - The view model

    func testTheViewModelGivesEveryFileBackedStoreTheInjectedLocation() throws {
        let suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // Seeded before the stores are built, so what they read can only have
        // come from this suite and not from the developer's own preferences.
        defaults.set(MusicSource.youtubeMusic.rawValue, forKey: MediaController.selectedSourceKey)
        defaults.set("de|fr", forKey: Translator.pairKey)
        // The alert service is stubbed for the same reason the display harness
        // stubs it: the real one reaches macOS Notification Center, which
        // aborts outside an app bundle.
        let settings = SettingsStore(
            defaults: defaults,
            lowBatteryAlerts: LowBatteryAlertService(
                engine: LowBatteryAlertEngine(store: MemoryDisplayAlertStore(), now: Date()),
                delivery: SilentDisplayAlertDelivery()
            )
        )
        let vm = NotchViewModel(settings: settings, storage: environment())

        XCTAssertEqual(vm.notes.fileURL, folder.appendingPathComponent("notes.json"))
        XCTAssertEqual(vm.snippets.fileURL, folder.appendingPathComponent("snippets.json"))
        XCTAssertNotEqual(vm.notes.fileURL, NoteStore.defaultFileURL)
        XCTAssertNotEqual(vm.snippets.fileURL, SnippetStore.defaultFileURL)
        // The stores that keep their state in defaults rather than a file —
        // the shelf's cards, the chosen music source, the language pair — are
        // isolated by the settings suite instead. In the app that suite is
        // `.standard`, so nothing moved.
        XCTAssertEqual(settings.defaults, defaults)
        XCTAssertEqual(vm.media.selectedSource, .youtubeMusic)
        XCTAssertEqual(Translator.identifier(of: vm.translator.pair), "de|fr")

        // And the writing direction, for the one of the three that writes.
        let card = folder.appendingPathComponent("card.txt")
        try Data("card".utf8).write(to: card)
        vm.shelf.add([card])
        XCTAssertEqual(defaults.stringArray(forKey: "shelf.urls"), [card.path])
    }

    // MARK: - The multi-display harness

    /// The harness is the thing that leaked, so it is the thing to pin: a note
    /// added through it has to end up in the harness's own file, put there by
    /// the same `stop()` that runs when the app quits.
    func testMultiDisplayHarnessWritesNotesIntoItsOwnTemporaryFile() throws {
        let harness = DisplayHarness(
            displays: [DisplayLayout.macBook, DisplayLayout.monitor],
            pointer: DisplayLayout.onMonitor
        )
        harness.install()

        XCTAssertEqual(harness.vm.notes.fileURL, harness.notesFile)
        XCTAssertEqual(harness.vm.snippets.fileURL, harness.snippetsFile)
        XCTAssertNotEqual(harness.vm.notes.fileURL, NoteStore.defaultFileURL)
        XCTAssertNotEqual(harness.vm.snippets.fileURL, SnippetStore.defaultFileURL)

        harness.vm.notes.add(text: "written inside a display test")
        let file = harness.notesFile
        let folder = harness.storageFolder

        // The shutdown path the app itself runs, flush included — the same call
        // `controller.teardown()` makes. Nothing here is stubbed; it simply
        // lands somewhere else.
        harness.vm.stop()

        let written = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(
            written.contains("written inside a display test"),
            "the note should have been flushed to the harness's own file"
        )

        harness.tearDown()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: folder.path),
            "the harness should take its directory with it"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// Belt and braces on the same claim, from the other side: the real file's
    /// bytes are read before and after a harness runs, and never written by it.
    /// If the injection ever regresses, this fails whatever the harness asserts
    /// about itself.
    func testTheRealNotesFileIsUntouchedByAMultiDisplaySession() throws {
        let real = NoteStore.defaultFileURL
        let before = try? Data(contentsOf: real)
        let stampBefore = try? FileManager.default
            .attributesOfItem(atPath: real.path)[.modificationDate] as? Date

        let harness = DisplayHarness(
            displays: [DisplayLayout.macBook, DisplayLayout.monitor],
            pointer: DisplayLayout.onMonitor
        )
        harness.install()
        harness.controller.toggleFromKeyboard()
        harness.vm.select(.notes)
        harness.vm.notes.add(text: "must never reach the real file")
        harness.vm.notes.flushSynchronously()
        harness.tearDown()

        let after = try? Data(contentsOf: real)
        let stampAfter = try? FileManager.default
            .attributesOfItem(atPath: real.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "the user's real notes.json changed during the test")
        XCTAssertEqual(stampBefore, stampAfter, "the user's real notes.json was rewritten")
        if let after, let text = String(data: after, encoding: .utf8) {
            XCTAssertFalse(text.contains("must never reach the real file"))
        }
    }
}
