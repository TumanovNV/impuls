import AppKit
import Combine
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import ImpulsCore

/// Cancellation of long file operations (IMP-15).
///
/// Everything here drives the real `FileToolsService`: the images are real, the
/// conversions are real, and the files these tests assert about are the files
/// Impuls actually wrote. The only thing replaced is *when* an item is allowed
/// to leave the main actor — `ManualFileToolsWorkGate` parks it there — because
/// the whole contract lives on the boundary between two items, and reaching
/// that boundary through a real queue needs a sleep, which is how a test both
/// flakes and enshrines the wrong answer.
@MainActor
final class FileToolsCancellationTests: XCTestCase {
    private var directory: URL!
    private var defaultsSuite: String!
    private var defaults: UserDefaults!
    private var shelf: ShelfStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImpulsCancellationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Its own defaults suite, so a test can never persist a card into the
        // shelf of the Impuls running on the developer's Mac.
        defaultsSuite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        shelf = ShelfStore(defaults: defaults)
    }

    override func tearDownWithError() throws {
        shelf = nil
        defaults.removePersistentDomain(forName: defaultsSuite)
        defaults = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: - Cancelling before anything starts

    /// `Task { }` created from a main-actor method does not run until the
    /// current turn yields, so cancelling on the very next line is genuinely
    /// "before the first item started" rather than an approximation of it.
    func testCancellingBeforeTheFirstItemStartsProcessesNothing() async throws {
        let sources = try makeImages(count: 3)
        let gate = ManualFileToolsWorkGate()
        let tools = FileToolsCoordinator(shelf: shelf, runner: gate)

        tools.convert(sources, to: .jpeg)
        XCTAssertTrue(tools.isWorking)
        XCTAssertTrue(tools.canCancel)
        tools.cancelActiveOperation()
        XCTAssertTrue(tools.isCancelling)

        await waitUntilIdle(tools)

        XCTAssertEqual(gate.arrivedCount, 0, "not one item may be handed to the executor")
        XCTAssertEqual(tools.statusMessage, localized("Cancelled"))
        XCTAssertFalse(tools.statusIsError, "a deliberate stop is not a failure")
        XCTAssertFalse(tools.canUndo, "nothing was created, so there is nothing to undo")
        XCTAssertTrue(shelf.items.isEmpty)
        XCTAssertEqual(try producedFiles(besides: sources), [])
        assertSourcesIntact(sources)
    }

    // MARK: - Cancelling between items

    func testCancellingBetweenItemsKeepsFinishedOutputsAndNeverStartsTheRest() async throws {
        let sources = try makeImages(count: 4)
        let gate = ManualFileToolsWorkGate()
        let tools = FileToolsCoordinator(shelf: shelf, runner: gate)

        tools.convert(sources, to: .jpeg)
        await gate.waitForArrivals(1)
        // The first item is already in flight. Cancelling now is the real
        // case: it must be allowed to finish, and item two must never begin.
        tools.cancelActiveOperation()
        gate.releaseAll()
        await waitUntilIdle(tools)

        XCTAssertEqual(gate.arrivedCount, 1, "the remaining three items must not start")

        let produced = try producedFiles(besides: sources)
        XCTAssertEqual(produced.count, 1, "the item already running finishes rather than being abandoned")
        let output = try XCTUnwrap(produced.first)
        XCTAssertEqual(output.pathExtension, "jpg")
        XCTAssertNotNil(
            CGImageSourceCreateWithURL(output as CFURL, nil),
            "an output kept after cancellation has to be a valid image, not a truncated one"
        )

        // `ShelfStore` resolves symlinks, so the temporary directory comes back
        // as `/private/var/...` where the directory listing says `/var/...`.
        XCTAssertEqual(
            shelf.items.map(\.url.lastPathComponent),
            [output.lastPathComponent],
            "only completed outputs reach the Shelf"
        )
        XCTAssertEqual(tools.statusMessage, localized("Cancelled · Processed: %d", 1))
        XCTAssertFalse(tools.statusIsError)
        XCTAssertTrue(tools.canUndo, "one completed output with a captured record is undoable")
        assertSourcesIntact(sources)
    }

    /// Progress must not tick past the point where cancellation was accepted.
    func testProgressStopsAtTheItemWhereCancellationWasAccepted() async throws {
        let sources = try makeImages(count: 5)
        let gate = ManualFileToolsWorkGate()
        let tools = FileToolsCoordinator(shelf: shelf, runner: gate)

        tools.convert(sources, to: .png)
        await gate.waitForArrivals(1)
        gate.releaseNext()
        await gate.waitForArrivals(2)
        XCTAssertEqual(
            tools.statusMessage,
            localized("%@ %d of %d", localized("Converting Image…"), 1, 5)
        )

        tools.cancelActiveOperation()
        XCTAssertEqual(tools.statusMessage, localized("Cancelling…"))
        gate.releaseNext()
        await waitUntilIdle(tools)

        XCTAssertEqual(gate.arrivedCount, 2)
        XCTAssertEqual(tools.statusMessage, localized("Cancelled · Processed: %d", 2))
    }

    /// Cancel arriving while the *last* item is in flight skips nothing, so the
    /// honest report is ordinary completion — not "Cancelled".
    func testCancelThatRacesNormalCompletionReportsCompletion() async throws {
        let sources = try makeImages(count: 1)
        let gate = ManualFileToolsWorkGate()
        let tools = FileToolsCoordinator(shelf: shelf, runner: gate)

        tools.convert(sources, to: .jpeg)
        await gate.waitForArrivals(1)
        tools.cancelActiveOperation()
        gate.releaseAll()
        await waitUntilIdle(tools)

        XCTAssertEqual(tools.statusMessage, localized("Processed: %d", 1))
        XCTAssertFalse(tools.statusIsError)
        XCTAssertEqual(try producedFiles(besides: sources).count, 1)
    }

    // MARK: - Failures alongside cancellation

    func testFailuresAndCancellationAreReportedTogetherAndLedByCancellation() async throws {
        let images = try makeImages(count: 1)
        let notAnImage = directory.appendingPathComponent("notes.txt")
        try Data("plain text".utf8).write(to: notAnImage)
        let sources = images + [notAnImage] + (try makeImages(count: 2, startingAt: 10))

        let gate = ManualFileToolsWorkGate()
        let tools = FileToolsCoordinator(shelf: shelf, runner: gate)

        tools.convert(sources, to: .jpeg)
        await gate.waitForArrivals(1)
        gate.releaseNext()                 // image converts
        await gate.waitForArrivals(2)
        tools.cancelActiveOperation()
        gate.releaseNext()                 // text file fails
        await waitUntilIdle(tools)

        XCTAssertEqual(gate.arrivedCount, 2, "the last two sources never start")
        XCTAssertEqual(
            tools.statusMessage,
            localized("Cancelled · Processed: %d · Skipped: %d", 1, 1)
        )
        // The warning styling belongs to the file that genuinely failed. The
        // message still leads with "Cancelled", so the stop itself is not
        // presented as the failure.
        XCTAssertTrue(tools.statusIsError)
        assertSourcesIntact(sources)
    }

    // MARK: - State after cancellation

    func testCancellationResetsWorkingStateAndLetsTheNextOperationRun() async throws {
        let sources = try makeImages(count: 3)
        let gate = ManualFileToolsWorkGate()
        let tools = FileToolsCoordinator(shelf: shelf, runner: gate)

        tools.convert(sources, to: .jpeg)
        await gate.waitForArrivals(1)
        tools.cancelActiveOperation()
        gate.releaseAll()
        await waitUntilIdle(tools)

        XCTAssertFalse(tools.isWorking)
        XCTAssertFalse(tools.isCancelling)
        XCTAssertFalse(tools.canCancel)

        // A second operation must behave as if nothing had been cancelled.
        gate.releaseEverythingFromNowOn()
        tools.convert(sources, to: .heic)
        await waitUntilIdle(tools)

        XCTAssertEqual(tools.statusMessage, localized("Processed: %d", 3))
        XCTAssertFalse(tools.statusIsError)
        XCTAssertFalse(tools.isWorking)
    }

    func testRepeatedCancelIsIdempotentAndCancellingWhenIdleDoesNothing() async throws {
        let tools = FileToolsCoordinator(shelf: shelf, runner: ManualFileToolsWorkGate())

        // Idle: no operation to cancel, and no status invented for one.
        tools.cancelActiveOperation()
        XCTAssertFalse(tools.isCancelling)
        XCTAssertNil(tools.statusMessage)

        let sources = try makeImages(count: 3)
        let gate = ManualFileToolsWorkGate()
        let running = FileToolsCoordinator(shelf: shelf, runner: gate)
        running.convert(sources, to: .jpeg)
        await gate.waitForArrivals(1)

        running.cancelActiveOperation()
        running.cancelActiveOperation()
        running.cancelActiveOperation()
        XCTAssertTrue(running.isCancelling)
        XCTAssertEqual(running.statusMessage, localized("Cancelling…"))

        gate.releaseAll()
        await waitUntilIdle(running)
        XCTAssertEqual(running.statusMessage, localized("Cancelled · Processed: %d", 1))
    }

    /// While the in-flight item is still draining the operation slot is still
    /// taken, so a second operation cannot start behind the first one's back
    /// and inherit its Shelf writes, status or Undo.
    func testASecondOperationIsRefusedWhileTheCancelledOneIsStillDraining() async throws {
        let sources = try makeImages(count: 3)
        let gate = ManualFileToolsWorkGate()
        let tools = FileToolsCoordinator(shelf: shelf, runner: gate)

        tools.convert(sources, to: .jpeg)
        await gate.waitForArrivals(1)
        tools.cancelActiveOperation()

        tools.resize(sources, preset: .pixels800)
        XCTAssertEqual(
            tools.statusMessage,
            localized("Cancelling…"),
            "the refused operation must not take over the status line"
        )

        gate.releaseAll()
        await waitUntilIdle(tools)

        XCTAssertEqual(gate.arrivedCount, 1, "the refused resize never ran an item")
        let produced = try producedFiles(besides: sources)
        XCTAssertEqual(produced.count, 1)
        XCTAssertEqual(produced.first?.pathExtension, "jpg", "only the first operation wrote anything")
    }

    /// A status auto-clear scheduled by a finished operation must not wipe the
    /// status of the operation that came after it.
    func testAStaleStatusClearCannotWipeANewerOperationsStatus() async throws {
        let sources = try makeImages(count: 1)
        let gate = ManualFileToolsWorkGate()
        gate.releaseEverythingFromNowOn()
        let tools = FileToolsCoordinator(shelf: shelf, runner: gate)

        tools.convert(sources, to: .jpeg)
        await waitUntilIdle(tools)
        XCTAssertEqual(tools.statusMessage, localized("Processed: %d", 1))

        // The finished operation left a 3-second clear pending. A new operation
        // starting inside that window owns the status line from here on.
        tools.copyPath(sources)
        XCTAssertEqual(tools.statusMessage, localized("Path Copied"))
    }

    // MARK: - Undo

    func testUndoAfterAPartialBatchTrashesExactlyTheFilesThatWereCreated() async throws {
        let sources = try makeImages(count: 3)
        let gate = ManualFileToolsWorkGate()
        let tools = FileToolsCoordinator(shelf: shelf, runner: gate)

        tools.convert(sources, to: .jpeg)
        await gate.waitForArrivals(1)
        tools.cancelActiveOperation()
        gate.releaseAll()
        await waitUntilIdle(tools)

        let produced = try producedFiles(besides: sources)
        XCTAssertEqual(produced.count, 1)
        XCTAssertTrue(tools.canUndo)

        gate.releaseEverythingFromNowOn()
        tools.undoLastOperation()
        await waitUntilIdle(tools)

        XCTAssertEqual(tools.statusMessage, localized("Generated Files Moved to Trash"))
        XCTAssertFalse(tools.statusIsError)
        XCTAssertFalse(tools.canUndo)
        XCTAssertTrue(shelf.items.isEmpty)
        XCTAssertEqual(try producedFiles(besides: sources), [], "the one generated file left the folder")
        assertSourcesIntact(sources)
    }

    /// Undo stays conservative after a partial batch: a result the user edited
    /// afterwards blocks the whole undo rather than being trashed anyway.
    func testUndoRefusesWhenAKeptOutputChangedAfterTheOperation() async throws {
        let sources = try makeImages(count: 3)
        let gate = ManualFileToolsWorkGate()
        let tools = FileToolsCoordinator(shelf: shelf, runner: gate)

        tools.convert(sources, to: .jpeg)
        await gate.waitForArrivals(1)
        tools.cancelActiveOperation()
        gate.releaseAll()
        await waitUntilIdle(tools)

        let output = try XCTUnwrap(try producedFiles(besides: sources).first)
        try Data([9, 9, 9]).write(to: output)

        gate.releaseEverythingFromNowOn()
        tools.undoLastOperation()
        await waitUntilIdle(tools)

        XCTAssertTrue(tools.statusIsError)
        XCTAssertEqual(
            tools.statusMessage,
            FileToolsError.generatedFileChanged.errorDescription
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    /// Undo is deliberately not offered a Cancel: stopping a trash sweep
    /// halfway is the one outcome worse than either end state.
    func testUndoIsNotPresentedAsACancellableOperation() async throws {
        let sources = try makeImages(count: 1)
        let gate = ManualFileToolsWorkGate()
        gate.releaseEverythingFromNowOn()
        let tools = FileToolsCoordinator(shelf: shelf, runner: gate)

        tools.convert(sources, to: .jpeg)
        await waitUntilIdle(tools)
        XCTAssertTrue(tools.canUndo)

        let undoGate = ManualFileToolsWorkGate()
        let undoing = FileToolsCoordinator(shelf: shelf, runner: undoGate)
        undoing.convert(sources, to: .png)
        await undoGate.waitForArrivals(1)
        undoGate.releaseAll()
        await waitUntilIdle(undoing)

        undoing.undoLastOperation()
        XCTAssertTrue(undoing.isWorking)
        XCTAssertFalse(undoing.canCancel, "Undo runs to completion or not at all")
        undoGate.releaseEverythingFromNowOn()
        await waitUntilIdle(undoing)
    }

    // MARK: - Text batch clipboard policy

    /// Cancelling a text batch leaves the pasteboard exactly as the user left
    /// it, even when some pages were already recognised.
    ///
    /// The gate substitutes the recognised string so the assertion is about the
    /// coordinator's policy rather than about whether Vision reads a synthetic
    /// bitmap. The pasteboard is checked by `changeCount` and never written to:
    /// a test must not clobber the clipboard of the person running it.
    func testCancellingATextBatchLeavesTheClipboardUntouched() async throws {
        let sources = try makeImages(count: 3)
        let gate = ManualFileToolsWorkGate()
        gate.substituteResult = "RECOGNISED TEXT"
        let tools = FileToolsCoordinator(shelf: shelf, runner: gate)

        let changeCountBefore = NSPasteboard.general.changeCount

        tools.recognizeText(in: sources)
        await gate.waitForArrivals(1)
        gate.releaseNext()                 // page one is recognised successfully
        await gate.waitForArrivals(2)
        tools.cancelActiveOperation()
        gate.releaseNext()
        await waitUntilIdle(tools)

        XCTAssertEqual(gate.arrivedCount, 2, "the third image never starts")
        XCTAssertEqual(tools.statusMessage, localized("Cancelled · Clipboard Unchanged"))
        XCTAssertFalse(tools.statusIsError)
        XCTAssertEqual(
            NSPasteboard.general.changeCount,
            changeCountBefore,
            "recognised text is discarded rather than overwriting what the user was holding"
        )
        XCTAssertTrue(shelf.items.isEmpty)
        assertSourcesIntact(sources)
    }

    // MARK: - PDF, page by page

    func testCancellingAPDFBetweenPagesLeavesNoPartialDocument() throws {
        let sources = try makeImages(count: 4)
        let pages = Counter()

        XCTAssertThrowsError(
            // False for the first page, true from the second on: one page is
            // drawn and the document is then abandoned mid-way, which is the
            // only state in which Impuls can produce an incomplete file.
            try FileToolsService.combineImagesIntoPDF(sources) { pages.next() > 0 }
        ) { error in
            XCTAssertTrue(error is FileToolsCancelled)
        }

        XCTAssertEqual(
            try producedFiles(besides: sources),
            [],
            "an unfinished PDF is deleted rather than handed over as a short document"
        )
        assertSourcesIntact(sources)
    }

    func testCancellingAPDFBeforeTheFirstPageLeavesNoFile() throws {
        let sources = try makeImages(count: 3)

        XCTAssertThrowsError(try FileToolsService.combineImagesIntoPDF(sources) { true }) { error in
            XCTAssertTrue(error is FileToolsCancelled)
        }
        XCTAssertEqual(try producedFiles(besides: sources), [])
    }

    func testAnUncancelledPDFStillProducesEveryPage() throws {
        let sources = try makeImages(count: 3)
        let output = try FileToolsService.combineImagesIntoPDF(sources)
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 3)
        assertSourcesIntact(sources)
    }

    func testCancellingAPDFThroughTheCoordinatorIsNotReportedAsAnError() async throws {
        let sources = try makeImages(count: 3)
        let gate = ManualFileToolsWorkGate()
        let tools = FileToolsCoordinator(shelf: shelf, runner: gate)

        tools.combineIntoPDF(sources)
        XCTAssertTrue(tools.canCancel)
        tools.cancelActiveOperation()
        // The work has not reached the gate yet — the operation task has not
        // had a turn — so it is let through rather than released.
        gate.releaseEverythingFromNowOn()
        await waitUntilIdle(tools)

        XCTAssertEqual(tools.statusMessage, localized("Cancelled"))
        XCTAssertFalse(tools.statusIsError)
        XCTAssertFalse(tools.canUndo, "no document was produced, so there is nothing to undo")
        XCTAssertTrue(shelf.items.isEmpty)
        XCTAssertEqual(try producedFiles(besides: sources), [])
    }

    // MARK: - Helpers

    /// Waits for the operation to finish by observing the state it publishes,
    /// rather than by sleeping long enough to be probably right.
    private func waitUntilIdle(
        _ tools: FileToolsCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        guard tools.isWorking else { return }
        let finished = expectation(description: "file operation finished")
        var token: AnyCancellable?
        token = tools.$isWorking
            .dropFirst()
            .sink { working in if !working { finished.fulfill() } }
        await fulfillment(of: [finished], timeout: 10)
        token?.cancel()
    }

    private func makeImages(count: Int, startingAt offset: Int = 0) throws -> [URL] {
        try (0..<count).map { try makeImage(named: "source-\($0 + offset).png") }
    }

    private func makeImage(named name: String, width: Int = 64, height: Int = 48) throws -> URL {
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
        let url = directory.appendingPathComponent(name)
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

    /// Everything the operations wrote into the working directory, which is the
    /// only place they are allowed to write.
    private func producedFiles(besides sources: [URL]) throws -> [URL] {
        let known = Set(sources.map(\.lastPathComponent))
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { !known.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func assertSourcesIntact(
        _ sources: [URL],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for source in sources {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: source.path),
                "a source file must never be moved or deleted by a file operation",
                file: file,
                line: line
            )
        }
    }
}

/// A counter a `@Sendable` predicate can carry across the boundary.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// Returns the number of calls *before* this one.
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}

/// Parks each operation at the moment it would leave the main actor.
///
/// This is the same idea as `ManualRestoreGate`: the contract lives in a window
/// that a real queue only passes through, so the test holds the window open
/// instead of racing it. It replaces the executor, not `FileToolsService` — the
/// work released through it is the real conversion.
final class ManualFileToolsWorkGate: FileToolsWorkRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0
    private var freeRunning = false
    private var arrivalWaiter: (target: Int, continuation: CheckedContinuation<Void, Never>)?

    /// When set, the gate returns this instead of running the work.
    ///
    /// Used only where the assertion is about the coordinator's own policy and
    /// the operation's real implementation would drag a framework — Vision —
    /// into a test that is not about it.
    var substituteResult: (any Sendable)? {
        get { lock.lock(); defer { lock.unlock() }; return substitute }
        set { lock.lock(); defer { lock.unlock() }; substitute = newValue }
    }

    private var substitute: (any Sendable)?

    /// How many items have been handed to the executor. The count that proves
    /// "the remaining items never started".
    var arrivedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return arrivals
    }

    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        await park()
        if let substitute = substituteResult as? T { return substitute }
        return try work()
    }

    private func park() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            arrivals += 1
            let waiter = takeSatisfiedWaiterLocked()
            if freeRunning {
                lock.unlock()
                waiter?.resume()
                continuation.resume()
                return
            }
            parked.append(continuation)
            lock.unlock()
            waiter?.resume()
        }
    }

    /// Suspends until `count` items have reached the gate.
    func waitForArrivals(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if arrivals >= count {
                lock.unlock()
                continuation.resume()
                return
            }
            precondition(arrivalWaiter == nil, "one waiter at a time")
            arrivalWaiter = (count, continuation)
            lock.unlock()
        }
    }

    func releaseNext() {
        lock.lock()
        let next = parked.isEmpty ? nil : parked.removeFirst()
        lock.unlock()
        next?.resume()
    }

    func releaseAll() {
        lock.lock()
        let all = parked
        parked = []
        lock.unlock()
        all.forEach { $0.resume() }
    }

    /// Stops parking. Used for the parts of a test that are only setup.
    func releaseEverythingFromNowOn() {
        lock.lock()
        freeRunning = true
        let all = parked
        parked = []
        lock.unlock()
        all.forEach { $0.resume() }
    }

    private func takeSatisfiedWaiterLocked() -> CheckedContinuation<Void, Never>? {
        guard let waiter = arrivalWaiter, arrivals >= waiter.target else { return nil }
        arrivalWaiter = nil
        return waiter.continuation
    }
}
