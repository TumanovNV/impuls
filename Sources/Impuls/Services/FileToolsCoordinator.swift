import AppKit
import Foundation
import QuickLookUI

private enum ShelfUndoAction {
    case generated([GeneratedFileRecord])
    case renamed(itemID: UUID, currentURL: URL, originalURL: URL)
}

/// How the coordinator gets one synchronous file operation off the main actor.
///
/// Production is `DetachedFileToolsWorkRunner`, which is the same
/// `Task.detached(priority: .userInitiated)` + `autoreleasepool` this file
/// always used. It exists as a seam because the interesting moment in a
/// cancellable batch is the boundary *between* two items, and a test that has
/// to reach that boundary through a real queue can only do it with a sleep.
/// A test runner parks the work there instead and hands control back, which is
/// what makes "cancel exactly between item 1 and item 2" a fact rather than a
/// race. It replaces the executor, never `FileToolsService` itself: the file
/// work in these tests is the real thing.
protocol FileToolsWorkRunner: Sendable {
    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T
}

struct DetachedFileToolsWorkRunner: FileToolsWorkRunner {
    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        // The pool stays around one item, not around the batch: a run of large
        // images would otherwise hold every decoded bitmap until the last one.
        try await Task.detached(priority: .userInitiated) {
            try autoreleasepool { try work() }
        }.value
    }
}

@MainActor
final class FileToolsCoordinator: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var statusIsError = false
    @Published private(set) var canUndo = false
    /// True only while an operation that can genuinely be stopped is running.
    /// Undo is deliberately excluded — see `undoLastOperation()`.
    @Published private(set) var canCancel = false
    /// True from the moment Cancel is accepted until the operation has finished
    /// draining the item that was already in flight. The UI uses it to stop
    /// offering a decision the user has already taken.
    @Published private(set) var isCancelling = false

    private let shelf: ShelfStore
    private let runner: FileToolsWorkRunner
    private var sharingPicker: NSSharingServicePicker?
    private let quickLook = ShelfQuickLookController()
    private var statusGeneration = 0
    private var undoAction: ShelfUndoAction? {
        didSet { canUndo = undoAction != nil }
    }

    /// Identifies one run of one operation.
    ///
    /// The generation is what makes "the newest operation owns status, Shelf
    /// and Undo" true by construction. Only one operation is ever in flight —
    /// `beginOperation` refuses to start a second — so a superseded completion
    /// is not a routine path; the guard is here so that a later change to that
    /// rule cannot silently turn a straggler into corrupted state.
    private struct OperationContext {
        let generation: Int
        let cancellation: FileToolsCancellation
    }

    private var activeCancellation: FileToolsCancellation?
    private var operationGeneration = 0

    init(shelf: ShelfStore, runner: FileToolsWorkRunner = DetachedFileToolsWorkRunner()) {
        self.shelf = shelf
        self.runner = runner
    }

    func recognizeText(in urls: [URL]) {
        runTextBatch(urls: urls, action: localized("Recognizing Text…")) { url in
            try FileToolsService.recognizeText(in: url)
        }
    }

    func convert(_ urls: [URL], to format: ImageOutputFormat) {
        runFileBatch(urls: urls, action: localized("Converting Image…")) { url in
            try FileToolsService.convertImage(at: url, to: format)
        }
    }

    func resize(_ urls: [URL], preset: ImageResizePreset) {
        runFileBatch(urls: urls, action: localized("Reducing Image…")) { url in
            try FileToolsService.resizeImage(at: url, maxPixelSize: preset.rawValue)
        }
    }

    func combineIntoPDF(_ urls: [URL]) {
        runSingleFile(starting: localized("Creating PDF…")) { cancellation in
            try FileToolsService.combineImagesIntoPDF(urls) { cancellation.isCancelled }
        }
    }

    func removeBackground(from urls: [URL]) {
        runFileBatch(urls: urls, action: localized("Removing Background…")) { url in
            try FileToolsService.removeBackground(from: url)
        }
    }

    /// Asks the running operation to stop at its next safe boundary.
    ///
    /// This is cooperative on purpose. A convert, resize, background removal or
    /// text recognition is one synchronous ImageIO/Vision call per file, and no
    /// public API stops one of those mid-write without risking a truncated
    /// result. So Cancel means: do not begin another item, and let the one
    /// already running finish so it can leave a valid file behind. Only the PDF
    /// has an interruptible interior, between pages.
    ///
    /// Repeat presses are no-ops — the flag only moves one way, and
    /// `isCancelling` keeps the UI from re-announcing a decision already taken.
    func cancelActiveOperation() {
        guard isWorking, !isCancelling, let cancellation = activeCancellation else { return }
        cancellation.cancel()
        isCancelling = true
        showStatus(localized("Cancelling…"), automaticallyClear: false)
    }

    func quickLook(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        quickLook.show(urls)
    }

    func copyPath(_ urls: [URL]) {
        let value = urls.map(\.path).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(Data(), forType: .impulsInternal)
        pasteboard.setString(value, forType: .string)
        showStatus(urls.count == 1 ? localized("Path Copied") : localized("Paths Copied"))
    }

    func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            showError(FileToolsError.sharingUnavailable)
            return
        }
        service.perform(withItems: urls.map { $0 as NSURL })
    }

    func share(_ urls: [URL]) {
        guard let view = NSApp.keyWindow?.contentView
                ?? NSApp.windows.first(where: { $0.isVisible })?.contentView else {
            showError(FileToolsError.sharingUnavailable)
            return
        }
        let picker = NSSharingServicePicker(items: urls.map { $0 as NSURL })
        sharingPicker = picker
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func requestRename(_ item: ShelfItem) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = localized("Rename File")
        alert.informativeText = localized("The extension will be preserved and an existing file will never be replaced.")
        let field = NSTextField(string: item.url.deletingPathExtension().lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: localized("Rename"))
        alert.addButton(withTitle: localized("Cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let originalURL = item.url
            let updated = try shelf.rename(item, baseName: field.stringValue)
            if updated.url != originalURL {
                undoAction = .renamed(
                    itemID: updated.id,
                    currentURL: updated.url,
                    originalURL: originalURL
                )
            }
            showStatus(localized("Renamed to %@", updated.name))
        } catch {
            showError(error)
        }
    }

    /// Undo is deliberately **not** cancellable.
    ///
    /// It moves an already-verified set of generated files to the Trash after a
    /// complete preflight, so stopping it halfway is the one outcome nobody
    /// wants: a batch half-undone. It is also short — a trash move, not a
    /// re-encode. Mixing it into the operation cancellation would buy nothing
    /// and would put a Cancel button on the one operation where a partial
    /// result is genuinely worse than either end state.
    func undoLastOperation() {
        guard let action = undoAction else { return }
        guard let context = beginOperation(cancellable: false) else { return }
        showStatus(localized("Undoing File Operation…"), automaticallyClear: false)
        Task {
            do {
                switch action {
                case .generated(let records):
                    try await runner.run {
                        try FileToolsService.moveGeneratedFilesToTrash(records)
                    }
                    guard isCurrent(context) else { return }
                    shelf.remove(urls: records.map(\.url))
                    showStatus(localized("Generated Files Moved to Trash"))
                case .renamed(let itemID, let currentURL, let originalURL):
                    _ = try shelf.restoreName(
                        itemID: itemID,
                        currentURL: currentURL,
                        originalURL: originalURL
                    )
                    guard isCurrent(context) else { return }
                    showStatus(localized("Original File Name Restored"))
                }
                undoAction = nil
            } catch {
                guard isCurrent(context) else { return }
                showError(error)
            }
            endOperation(context)
        }
    }

    // MARK: - Operation lifecycle

    /// Claims the single operation slot, or returns `nil` if one is already
    /// running. One slot is the whole concurrency model here: this change is
    /// about stopping work safely, not about running more of it at once.
    private func beginOperation(cancellable: Bool) -> OperationContext? {
        guard !isWorking else { return nil }
        operationGeneration += 1
        let context = OperationContext(
            generation: operationGeneration,
            cancellation: FileToolsCancellation()
        )
        activeCancellation = context.cancellation
        isWorking = true
        isCancelling = false
        canCancel = cancellable
        return context
    }

    private func isCurrent(_ context: OperationContext) -> Bool {
        context.generation == operationGeneration
    }

    private func endOperation(_ context: OperationContext) {
        guard isCurrent(context) else { return }
        activeCancellation = nil
        isWorking = false
        isCancelling = false
        canCancel = false
    }

    // MARK: - Batches

    /// Text recognition over a batch. The result is one pasteboard write, which
    /// is why its cancellation policy differs from the file batches below.
    private func runTextBatch(
        urls: [URL],
        action: String,
        operation: @escaping @Sendable (URL) throws -> String
    ) {
        guard !urls.isEmpty else { return }
        guard let context = beginOperation(cancellable: true) else { return }
        showProgress(action: action, completed: 0, total: urls.count)
        Task {
            var recognized: [(URL, String)] = []
            var failures: [Error] = []
            var notStarted = 0

            for (index, url) in urls.enumerated() {
                if context.cancellation.isCancelled {
                    notStarted = urls.count - index
                    break
                }
                do {
                    recognized.append((url, try await runner.run { try operation(url) }))
                } catch is FileToolsCancelled {
                    notStarted = urls.count - index
                    break
                } catch {
                    failures.append(error)
                }
                guard isCurrent(context) else { return }
                // Read again before reporting: progress must not tick past the
                // point where the user's cancellation was accepted.
                if context.cancellation.isCancelled {
                    notStarted = urls.count - (index + 1)
                    break
                }
                showProgress(action: action, completed: index + 1, total: urls.count)
            }

            guard isCurrent(context) else { return }

            if notStarted > 0 {
                // Cancelling a text batch leaves the pasteboard exactly as the
                // user left it, and the status says so.
                //
                // A generated file is additive: it is new, valid on its own,
                // sits beside its source and can be undone. The pasteboard is
                // none of those. It has one slot, so writing a partial
                // transcript into it destroys whatever the user was holding
                // there — to deliver a result they just said they no longer
                // wanted, with no Undo to take it back. Discarding recognised
                // text is the cheaper mistake, and the user can re-run over a
                // smaller selection.
                showStatus(localized("Cancelled · Clipboard Unchanged"))
            } else if !recognized.isEmpty {
                let text = recognized.count == 1
                    ? recognized[0].1
                    : recognized.map { "\($0.0.lastPathComponent)\n\($0.1)" }.joined(separator: "\n\n")
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setData(Data(), forType: .impulsInternal)
                pasteboard.setString(text, forType: .string)
                finishBatch(successes: recognized.count, failures: failures)
            } else {
                showError(failures.first ?? FileToolsError.noTextFound)
            }
            endOperation(context)
        }
    }

    /// A batch that writes one new file per source.
    ///
    /// Each item is atomic by the time the coordinator sees it: the service
    /// writes to a unique URL beside the source and removes its own partial
    /// output if the write throws. So an item that finished produced a complete,
    /// valid file, and cancelling keeps it — all-or-nothing here would throw
    /// away correct work the user already paid for.
    private func runFileBatch(
        urls: [URL],
        action: String,
        operation: @escaping @Sendable (URL) throws -> URL
    ) {
        guard !urls.isEmpty else { return }
        guard let context = beginOperation(cancellable: true) else { return }
        undoAction = nil
        showProgress(action: action, completed: 0, total: urls.count)
        Task {
            var outputs: [URL] = []
            var records: [GeneratedFileRecord] = []
            var failures: [Error] = []
            var notStarted = 0

            for (index, url) in urls.enumerated() {
                if context.cancellation.isCancelled {
                    notStarted = urls.count - index
                    break
                }
                do {
                    let generated = try await runner.run { () -> (URL, GeneratedFileRecord?) in
                        let output = try operation(url)
                        return (output, try? GeneratedFileRecord.capture(output))
                    }
                    outputs.append(generated.0)
                    if let record = generated.1 { records.append(record) }
                } catch is FileToolsCancelled {
                    notStarted = urls.count - index
                    break
                } catch {
                    failures.append(error)
                }
                guard isCurrent(context) else { return }
                if context.cancellation.isCancelled {
                    notStarted = urls.count - (index + 1)
                    break
                }
                showProgress(action: action, completed: index + 1, total: urls.count)
            }

            guard isCurrent(context) else { return }

            if !outputs.isEmpty {
                shelf.add(outputs)
                // Unchanged and still conservative: Undo is offered only when
                // every kept output has a verified record behind it. A partial
                // batch is no reason to relax that — it is a reason to keep it.
                undoAction = records.count == outputs.count ? .generated(records) : nil
            }
            finishOperation(
                context,
                successes: outputs.count,
                failures: failures,
                notStarted: notStarted,
                emptyError: FileToolsError.couldNotWriteImage
            )
        }
    }

    /// One long operation producing one file. Only the PDF uses this today, and
    /// it is the only operation with an interruptible interior, so the
    /// cancellation flag is handed to the work itself.
    private func runSingleFile(
        starting message: String,
        operation: @escaping @Sendable (FileToolsCancellation) throws -> URL
    ) {
        guard let context = beginOperation(cancellable: true) else { return }
        undoAction = nil
        showStatus(message, automaticallyClear: false)
        Task {
            let cancellation = context.cancellation
            do {
                let generated = try await runner.run { () -> (URL, GeneratedFileRecord?) in
                    let url = try operation(cancellation)
                    return (url, try? GeneratedFileRecord.capture(url))
                }
                guard isCurrent(context) else { return }
                shelf.add([generated.0])
                if let record = generated.1 {
                    undoAction = .generated([record])
                }
                showStatus(localized("Processed: %d", 1))
            } catch is FileToolsCancelled {
                guard isCurrent(context) else { return }
                // The work stopped between two pages and deleted its own
                // partial file, so there is nothing to shelve and nothing to
                // undo — and nothing that belongs in the error channel either.
                showStatus(localized("Cancelled"))
            } catch {
                guard isCurrent(context) else { return }
                showError(error)
            }
            endOperation(context)
        }
    }

    // MARK: - Status

    private func showProgress(action: String, completed: Int, total: Int) {
        showStatus(
            localized("%@ %d of %d", action, completed, total),
            automaticallyClear: false
        )
    }

    private func finishOperation(
        _ context: OperationContext,
        successes: Int,
        failures: [Error],
        notStarted: Int,
        emptyError: @autoclosure () -> Error
    ) {
        if notStarted > 0 {
            showCancelled(successes: successes, failures: failures.count)
        } else if successes > 0 {
            finishBatch(successes: successes, failures: failures)
        } else {
            showError(failures.first ?? emptyError())
        }
        endOperation(context)
    }

    /// Cancellation is an outcome, not a failure, so the message always leads
    /// with it. The warning styling appears only when files genuinely failed,
    /// and then it belongs to those files — never to the act of cancelling.
    private func showCancelled(successes: Int, failures: Int) {
        if failures > 0 {
            showStatus(
                localized("Cancelled · Processed: %d · Skipped: %d", successes, failures),
                isError: true
            )
        } else if successes > 0 {
            showStatus(localized("Cancelled · Processed: %d", successes))
        } else {
            showStatus(localized("Cancelled"))
        }
    }

    private func finishBatch(successes: Int, failures: [Error]) {
        if failures.isEmpty {
            showStatus(localized("Processed: %d", successes))
        } else {
            showStatus(
                localized("Processed: %d · Skipped: %d", successes, failures.count),
                isError: true
            )
        }
    }

    private func showError(_ error: Error) {
        showStatus(error.localizedDescription, isError: true)
    }

    private func showStatus(
        _ message: String,
        isError: Bool = false,
        automaticallyClear: Bool = true
    ) {
        statusGeneration += 1
        let generation = statusGeneration
        statusMessage = message
        statusIsError = isError
        guard automaticallyClear else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard generation == statusGeneration else { return }
            statusMessage = nil
            statusIsError = false
        }
    }
}

@MainActor
private final class ShelfQuickLookController: NSObject,
    @preconcurrency QLPreviewPanelDataSource,
    QLPreviewPanelDelegate {
    private var urls: [URL] = []

    func show(_ urls: [URL]) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }
}
