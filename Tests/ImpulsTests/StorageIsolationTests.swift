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
        // Snippets write from their own queue, as notes do; `flushSynchronously`
        // is the shutdown path that makes the pending snapshot land.
        store.flushSynchronously()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let reopened = SnippetStore(fileURL: url)
        reopened.reload()
        XCTAssertEqual(reopened.items.map(\.text), ["value"])
    }

    /// The default is still the real path — the point was to make the location a
    /// dependency, not to move the app's data.
    ///
    /// This asks the two stores where they would keep their files and checks the
    /// shape of the answer. It opens nothing, and since resolution is pure it
    /// creates nothing either: see `testResolvingALocationCreatesNothing`.
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

    /// The Actions corpus is cached, and `NotchViewModel` is what invalidates
    /// it. The unit tests drive `invalidateCorpus()` directly, so this pins the
    /// wiring that calls it: without this subscription the cache would be a
    /// stale-results bug rather than an optimisation.
    func testMutatingASourceStoreInvalidatesTheActionsCorpusThroughTheViewModel() throws {
        let suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(
            defaults: defaults,
            lowBatteryAlerts: LowBatteryAlertService(
                engine: LowBatteryAlertEngine(store: MemoryDisplayAlertStore(), now: Date()),
                delivery: SilentDisplayAlertDelivery()
            )
        )
        let vm = NotchViewModel(settings: settings, storage: environment())

        // An edit rather than an addition, deliberately: the row count does not
        // move, so the corpus size still agrees with its sources and the safety
        // net inside the store cannot notice. Only the subscription can. This is
        // the case that would ship stale search results if the wiring were lost.
        let id = vm.notes.add(text: "the original wording")
        vm.actions.query = "original"
        XCTAssertEqual(
            vm.actions.results(
                clipboard: vm.clipboard.items,
                snippets: vm.snippets.items,
                notes: vm.notes.notes
            ).count,
            1
        )

        vm.notes.update(id, text: "the rewritten wording")

        vm.actions.query = "rewritten"
        XCTAssertEqual(
            vm.actions.results(
                clipboard: vm.clipboard.items,
                snippets: vm.snippets.items,
                notes: vm.notes.notes
            ).count,
            1,
            "the edited text has to be searchable at once"
        )
        vm.actions.query = "original"
        XCTAssertTrue(
            vm.actions.results(
                clipboard: vm.clipboard.items,
                snippets: vm.snippets.items,
                notes: vm.notes.notes
            ).isEmpty,
            "and the wording it replaced must not still be matching"
        )
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

    /// The same claim from the other side, and without going anywhere near the
    /// real file.
    ///
    /// A sentinel stands in for it: a second temporary directory laid out like
    /// `Application Support/Impuls`, which the harness is not told about. A
    /// display session then writes a note and flushes it. If any path in the
    /// chain ever falls back to a location the harness did not choose, the
    /// sentinel is where a regression would land — and the assertion that the
    /// note went to the harness's own file would fail first.
    ///
    /// The earlier version of this test read the bytes and modification date of
    /// the user's own `notes.json` to prove they had not changed. It never wrote
    /// anything, but proving a test does not touch private notes by opening them
    /// is not a proof anybody should accept.
    func testAMultiDisplaySessionWritesNowhereButItsOwnStorage() throws {
        let elsewhere = folder.appendingPathComponent("not-the-harness", isDirectory: true)
        let sentinel = ApplicationSupport.file(named: "notes.json", in: elsewhere)
        ApplicationSupport.ensureParentDirectory(for: sentinel)
        let untouched = Data("[]".utf8)
        try untouched.write(to: sentinel)

        let harness = DisplayHarness(
            displays: [DisplayLayout.macBook, DisplayLayout.monitor],
            pointer: DisplayLayout.onMonitor
        )
        harness.install()
        harness.controller.toggleFromKeyboard()
        harness.vm.select(.notes)
        harness.vm.notes.add(text: "belongs to the harness")
        harness.vm.notes.flushSynchronously()

        XCTAssertEqual(try Data(contentsOf: sentinel), untouched)
        XCTAssertTrue(
            try String(contentsOf: harness.notesFile, encoding: .utf8)
                .contains("belongs to the harness")
        )

        harness.tearDown()
        XCTAssertEqual(try Data(contentsOf: sentinel), untouched)
    }

    // MARK: - The gate

    /// Resolving a path must create nothing.
    ///
    /// This is the regression gate for the whole hardening pass, and it works on
    /// a base directory that does not exist rather than on the real one — so it
    /// fails loudly if `createDirectory` ever creeps back into path resolution,
    /// instead of passing quietly on a machine where the folder happens to be
    /// there already.
    func testResolvingALocationCreatesNothing() {
        let base = folder.appendingPathComponent("never-created", isDirectory: true)
        let file = ApplicationSupport.file(named: "notes.json", in: base)

        XCTAssertEqual(file.lastPathComponent, "notes.json")
        XCTAssertEqual(file.deletingLastPathComponent().lastPathComponent, "Impuls")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path),
            "resolving a path created a directory"
        )

        // And the writer's side of the split still makes it.
        ApplicationSupport.ensureParentDirectory(for: file)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: file.deletingLastPathComponent().path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// The store creates its own folder on the first write, so a clean install
    /// does not depend on anything having resolved a path earlier.
    func testTheFirstNoteCreatesTheFolderItLivesIn() throws {
        let base = folder.appendingPathComponent("clean-install", isDirectory: true)
        let file = ApplicationSupport.file(named: "notes.json", in: base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))

        let store = NoteStore(fileURL: file)
        XCTAssertTrue(store.notes.isEmpty)
        store.add(text: "first note on a new Mac")
        store.flushSynchronously()

        XCTAssertTrue(
            try String(contentsOf: file, encoding: .utf8).contains("first note on a new Mac")
        )
    }

    func testTheFirstSnippetCreatesTheFolderItLivesIn() throws {
        let base = folder.appendingPathComponent("clean-install-snippets", isDirectory: true)
        let file = ApplicationSupport.file(named: "snippets.json", in: base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))

        let store = SnippetStore(fileURL: file)
        store.add(label: "first", text: "value")
        store.flushSynchronously()

        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("value"))
    }
}
