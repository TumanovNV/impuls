import Combine
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import ImpulsCore

final class FileToolsServiceTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImpulsFileToolsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testUniqueOutputNeverReplacesAnExistingFile() throws {
        let first = temporaryDirectory.appendingPathComponent("photo-png.png")
        try Data([0]).write(to: first)

        let output = FileToolsService.uniqueOutputURL(
            directory: temporaryDirectory,
            stem: "photo-png",
            fileExtension: "png"
        )

        XCTAssertEqual(output.lastPathComponent, "photo-png-2.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    func testConversionAndResizeCreateNewReadableImages() throws {
        let source = try makeImage(named: "source.png", width: 120, height: 60)

        let jpeg = try FileToolsService.convertImage(at: source, to: .jpeg)
        let resized = try FileToolsService.resizeImage(at: source, maxPixelSize: 40)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(jpeg.pathExtension, "jpg")
        XCTAssertNotNil(CGImageSourceCreateWithURL(jpeg as CFURL, nil))

        let resizedSource = try XCTUnwrap(CGImageSourceCreateWithURL(resized as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(resizedSource, 0, nil) as? [CFString: Any]
        )
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? NSNumber)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? NSNumber)
        XCTAssertLessThanOrEqual(max(width.intValue, height.intValue), 40)
    }

    func testCombiningImagesProducesOnePagePerInput() throws {
        let first = try makeImage(named: "first.png", width: 40, height: 30)
        let second = try makeImage(named: "second.png", width: 30, height: 40)

        let output = try FileToolsService.combineImagesIntoPDF([first, second])
        let document = try XCTUnwrap(PDFDocument(url: output))

        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testSafeRenamePreservesExtensionAndRejectsEscapesAndCollisions() throws {
        let source = try makeImage(named: "original.png", width: 10, height: 10)
        let target = try ShelfStore.safeRenameTarget(for: source, baseName: "renamed")
        XCTAssertEqual(target.lastPathComponent, "renamed.png")

        XCTAssertThrowsError(try ShelfStore.safeRenameTarget(for: source, baseName: "../escape"))

        try Data([0]).write(to: target)
        XCTAssertThrowsError(try ShelfStore.safeRenameTarget(for: source, baseName: "renamed"))
    }

    func testResizeRefusesToUpscale() throws {
        let source = try makeImage(named: "small.png", width: 20, height: 10)
        XCTAssertThrowsError(try FileToolsService.resizeImage(at: source, maxPixelSize: 40)) { error in
            XCTAssertEqual(error as? FileToolsError, .imageAlreadyFits)
        }
    }

    func testFullImageDecodeHasAPixelSafetyLimit() throws {
        XCTAssertNoThrow(try FileToolsService.validateImageDimensions(width: 8_000, height: 8_000))
        XCTAssertThrowsError(
            try FileToolsService.validateImageDimensions(width: 10_000, height: 10_000)
        ) { error in
            XCTAssertEqual(error as? FileToolsError, .imageTooLarge)
        }
        XCTAssertThrowsError(try FileToolsService.validateImageDimensions(width: 0, height: 100))
    }

    func testPlayerArtworkIsDownsampledToItsDisplayBudget() throws {
        let source = try makeImage(named: "artwork.png", width: 2_000, height: 1_000)
        let data = try Data(contentsOf: source)
        let image = try XCTUnwrap(PlayerBridge.thumbnailArtwork(from: data))

        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), CGFloat(PlayerBridge.artworkPixelSize))
    }

    func testGeneratedFileRecordDetectsAChangedFile() throws {
        let output = temporaryDirectory.appendingPathComponent("generated.bin")
        try Data([0]).write(to: output)
        let record = try GeneratedFileRecord.capture(output)

        XCTAssertTrue(record.matchesCurrentFile())

        try Data([0, 1, 2]).write(to: output)
        XCTAssertFalse(record.matchesCurrentFile())
    }

    func testGeneratedFileRecordDetectsSameSizeChangeWithRestoredTimestamp() throws {
        let output = temporaryDirectory.appendingPathComponent("generated-same-size.bin")
        try Data([0, 1, 2]).write(to: output)
        let record = try GeneratedFileRecord.capture(output)

        try Data([2, 1, 0]).write(to: output)
        try FileManager.default.setAttributes(
            [.modificationDate: record.modificationDate],
            ofItemAtPath: output.path
        )

        XCTAssertFalse(record.matchesCurrentFile())
    }

    func testRenameCanBeRestoredAndSelectionSurvives() async throws {
        let source = try makeImage(named: "restore-me.png", width: 10, height: 10)
        try await MainActor.run {
            // Its own defaults suite. This used to clear `shelf.urls` in
            // `UserDefaults.standard` before and after, which is where the
            // running Impuls keeps its shelf: the test emptied the developer's
            // real one to make room for a picture of its own.
            let suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }

            let store = ShelfStore(defaults: defaults)
            store.add([source])
            let original = try XCTUnwrap(store.items.first)
            store.selectAll()

            let renamed = try store.rename(original, baseName: "renamed")
            XCTAssertEqual(renamed.name, "renamed.png")

            let restored = try store.restoreName(
                itemID: renamed.id,
                currentURL: renamed.url,
                originalURL: source
            )
            XCTAssertEqual(restored.url, source)
            XCTAssertTrue(store.selection.contains(restored.id))
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            store.clear()
        }
    }

    // MARK: - The shelf across an asynchronous restore
    //
    // `load()` stats remembered paths off the main actor, so there is a window
    // in which the shelf is `items` plus a tail the sweep has not produced yet.
    // These four pin what may happen in that window. The gate holds it open on
    // purpose — the previous version of this test raced a real queue with a
    // sleep, and asserted the loss it was supposed to catch as correct.

    /// A: a card added mid-restore survives, and so does everything the restore
    /// had not got to yet. This is the regression: the drop used to retire the
    /// sweep, and the remembered list was written away by the drop's own
    /// `persist()` — eight cards gone, from `defaults` as well as the shelf.
    func testACardAddedDuringRestoreJoinsTheRememberedShelfRatherThanReplacingIt() async throws {
        let remembered = try (0..<8).map { try makeImage(named: "remembered-\($0).png", width: 4, height: 4) }
        let dropped = try makeImage(named: "dropped-during-restore.png", width: 4, height: 4)
        defer { (remembered + [dropped]).forEach { try? FileManager.default.removeItem(at: $0) } }

        let (defaults, suite) = try Self.temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(remembered.map(\.path), forKey: "shelf.urls")

        let gate = ManualRestoreGate()
        let store = await MainActor.run { ShelfStore(defaults: defaults, scheduleRestore: gate.schedule) }

        await MainActor.run {
            store.load()
            store.add([dropped])
            XCTAssertEqual(store.items.map(\.url), [dropped], "the sweep has not run yet")
            XCTAssertEqual(
                defaults.stringArray(forKey: "shelf.urls"),
                [dropped.path] + remembered.map(\.path),
                "a persist during the restore has to carry the tail it cannot see yet"
            )
        }

        await Self.runGateAndDrain(gate, in: self)

        await MainActor.run {
            XCTAssertEqual(
                store.items.map(\.url),
                [dropped] + remembered,
                "the new card stays on top and every remembered card comes back below it"
            )
            XCTAssertEqual(defaults.stringArray(forKey: "shelf.urls"), ([dropped] + remembered).map(\.path))
            store.clear()
        }
    }

    /// B: the other direction. A card the user removes mid-restore must not be
    /// handed back by the sweep that was already stating it.
    func testACardRemovedDuringRestoreIsNotResurrectedByTheSweep() async throws {
        let remembered = try (0..<4).map { try makeImage(named: "kept-or-removed-\($0).png", width: 4, height: 4) }
        defer { remembered.forEach { try? FileManager.default.removeItem(at: $0) } }

        let (defaults, suite) = try Self.temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(remembered.map(\.path), forKey: "shelf.urls")

        let gate = ManualRestoreGate()
        let store = await MainActor.run { ShelfStore(defaults: defaults, scheduleRestore: gate.schedule) }

        await MainActor.run {
            store.load()
            // The card is not in `items` yet, so removal has to reach the
            // restore's tail rather than the card list.
            store.remove(urls: [remembered[1]])
        }

        await Self.runGateAndDrain(gate, in: self)

        await MainActor.run {
            XCTAssertEqual(
                store.items.map(\.url),
                [remembered[0], remembered[2], remembered[3]],
                "a removal during the restore is a removal, not a pause"
            )
            XCTAssertFalse(defaults.stringArray(forKey: "shelf.urls")!.contains(remembered[1].path))
            store.clear()
        }
    }

    /// C: a sweep superseded by a later `load()` must not apply. Only `load()`
    /// advances the generation now, so this is the case that still has to hold.
    func testAStaleRestoreCompletionCannotOverwriteNewerState() async throws {
        let first = try (0..<3).map { try makeImage(named: "first-load-\($0).png", width: 4, height: 4) }
        let second = try makeImage(named: "second-load.png", width: 4, height: 4)
        defer { (first + [second]).forEach { try? FileManager.default.removeItem(at: $0) } }

        let (defaults, suite) = try Self.temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(first.map(\.path), forKey: "shelf.urls")

        let gate = ManualRestoreGate()
        let store = await MainActor.run { ShelfStore(defaults: defaults, scheduleRestore: gate.schedule) }

        await MainActor.run {
            store.load()
            defaults.set([second.path], forKey: "shelf.urls")
            store.load()
        }

        // Both sweeps run, oldest first. The first is already superseded.
        await Self.runGateAndDrain(gate, in: self)

        await MainActor.run {
            XCTAssertEqual(
                store.items.map(\.url),
                [second],
                "the retired sweep must not put the first load's shelf back"
            )
            store.clear()
        }
    }

    /// D: `add` clamped to the limit and `load` did not, so a remembered shelf
    /// longer than the limit came back in full — and paid for an icon and a
    /// thumbnail request for every one of those cards on the main actor. The
    /// limit still holds through the reconciled restore.
    func testRestoringAnOverlongShelfClampsToTheLimitAndHealsWhatItRemembers() async throws {
        let files = try (0..<70).map { try makeImage(named: "shelf-\($0).png", width: 4, height: 4) }
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }

        let (defaults, suite) = try Self.temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(files.map(\.path), forKey: "shelf.urls")

        let gate = ManualRestoreGate()
        let store = await MainActor.run { ShelfStore(defaults: defaults, scheduleRestore: gate.schedule) }
        await MainActor.run { store.load() }
        await Self.runGateAndDrain(gate, in: self)

        await MainActor.run {
            XCTAssertEqual(store.items.count, 60, "the limit has to hold on the way back in, not only on the way in")
            XCTAssertEqual(
                defaults.stringArray(forKey: "shelf.urls")?.count,
                60,
                "the trimmed shelf is written back, so it is not re-clamped on every launch"
            )
            store.clear()
        }
    }

    /// A card whose remembered file has gone still leaves the shelf — the
    /// reason `reloadShelf()` exists after the screenshots folder is emptied.
    /// Reconciling rather than assigning must not cost that.
    func testARestoreStillDropsCardsWhoseFilesAreGone() async throws {
        let kept = try makeImage(named: "still-there.png", width: 4, height: 4)
        let deleted = try makeImage(named: "deleted-before-reload.png", width: 4, height: 4)
        defer { try? FileManager.default.removeItem(at: kept) }

        let (defaults, suite) = try Self.temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([kept.path, deleted.path], forKey: "shelf.urls")

        let gate = ManualRestoreGate()
        let store = await MainActor.run { ShelfStore(defaults: defaults, scheduleRestore: gate.schedule) }
        await MainActor.run { store.load() }
        await Self.runGateAndDrain(gate, in: self)
        await MainActor.run { XCTAssertEqual(store.items.map(\.url), [kept, deleted]) }

        try FileManager.default.removeItem(at: deleted)
        await MainActor.run { store.load() }
        await Self.runGateAndDrain(gate, in: self)

        await MainActor.run {
            XCTAssertEqual(store.items.map(\.url), [kept], "a card whose file is gone leaves on reload")
            XCTAssertEqual(defaults.stringArray(forKey: "shelf.urls"), [kept.path])
            store.clear()
        }
    }

    private static func temporaryDefaults() throws -> (UserDefaults, String) {
        let suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    /// Runs the sweeps the gate is holding, then waits for their main-queue
    /// completions. The main queue is FIFO, so a block enqueued after them runs
    /// after them — no sleep, and nothing to race.
    private static func runGateAndDrain(_ gate: ManualRestoreGate, in testCase: XCTestCase) async {
        gate.runPending()
        let drained = testCase.expectation(description: "restore completions ran")
        DispatchQueue.main.async { drained.fulfill() }
        await testCase.fulfillment(of: [drained], timeout: 5)
    }

    private func makeImage(named name: String, width: Int, height: Int) throws -> URL {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let image = try XCTUnwrap(context.makeImage())
        let url = temporaryDirectory.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}

/// Holds the shelf's existence sweep until a test lets it through.
///
/// The window between `load()` and its completion is where the restore
/// contract lives. Racing a real queue for it needs a sleep, and a sleep is
/// how the previous test both flaked and enshrined the wrong answer.
final class ManualRestoreGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@Sendable () -> Void] = []

    /// Matches `ShelfRestoreScheduler`.
    var schedule: ShelfRestoreScheduler {
        { [self] work in
            lock.lock()
            pending.append(work)
            lock.unlock()
        }
    }

    /// Runs everything held, oldest first, on the calling thread.
    func runPending() {
        lock.lock()
        let work = pending
        pending = []
        lock.unlock()
        work.forEach { $0() }
    }
}
