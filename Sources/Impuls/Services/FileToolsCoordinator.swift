import AppKit
import Foundation
import QuickLookUI

private enum ShelfUndoAction {
    case generated([GeneratedFileRecord])
    case renamed(itemID: UUID, currentURL: URL, originalURL: URL)
}

@MainActor
final class FileToolsCoordinator: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var statusIsError = false
    @Published private(set) var canUndo = false

    private let shelf: ShelfStore
    private var sharingPicker: NSSharingServicePicker?
    private let quickLook = ShelfQuickLookController()
    private var statusGeneration = 0
    private var undoAction: ShelfUndoAction? {
        didSet { canUndo = undoAction != nil }
    }

    init(shelf: ShelfStore) {
        self.shelf = shelf
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
        runSingleFile(
            starting: localized("Creating PDF…")
        ) {
            try FileToolsService.combineImagesIntoPDF(urls)
        }
    }

    func removeBackground(from urls: [URL]) {
        runFileBatch(urls: urls, action: localized("Removing Background…")) { url in
            try FileToolsService.removeBackground(from: url)
        }
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

    func undoLastOperation() {
        guard !isWorking, let action = undoAction else { return }
        isWorking = true
        showStatus(localized("Undoing File Operation…"), automaticallyClear: false)
        Task {
            do {
                switch action {
                case .generated(let records):
                    try await Task.detached(priority: .userInitiated) {
                        try autoreleasepool {
                            try FileToolsService.moveGeneratedFilesToTrash(records)
                        }
                    }.value
                    shelf.remove(urls: records.map(\.url))
                    showStatus(localized("Generated Files Moved to Trash"))
                case .renamed(let itemID, let currentURL, let originalURL):
                    _ = try shelf.restoreName(
                        itemID: itemID,
                        currentURL: currentURL,
                        originalURL: originalURL
                    )
                    showStatus(localized("Original File Name Restored"))
                }
                undoAction = nil
            } catch {
                showError(error)
            }
            isWorking = false
        }
    }

    private func runTextBatch(
        urls: [URL],
        action: String,
        operation: @escaping @Sendable (URL) throws -> String
    ) {
        guard !urls.isEmpty else { return }
        guard !isWorking else { return }
        isWorking = true
        showProgress(action: action, completed: 0, total: urls.count)
        Task {
            var recognized: [(URL, String)] = []
            var failures: [Error] = []
            for (index, url) in urls.enumerated() {
                do {
                    let text = try await Task.detached(priority: .userInitiated) {
                        try autoreleasepool { try operation(url) }
                    }.value
                    recognized.append((url, text))
                } catch {
                    failures.append(error)
                }
                showProgress(action: action, completed: index + 1, total: urls.count)
            }

            if !recognized.isEmpty {
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
            isWorking = false
        }
    }

    private func runFileBatch(
        urls: [URL],
        action: String,
        operation: @escaping @Sendable (URL) throws -> URL
    ) {
        guard !urls.isEmpty else { return }
        guard !isWorking else { return }
        isWorking = true
        undoAction = nil
        showProgress(action: action, completed: 0, total: urls.count)
        Task {
            var outputs: [URL] = []
            var failures: [Error] = []
            for (index, url) in urls.enumerated() {
                do {
                    let output = try await Task.detached(priority: .userInitiated) {
                        try autoreleasepool { try operation(url) }
                    }.value
                    outputs.append(output)
                } catch {
                    failures.append(error)
                }
                showProgress(action: action, completed: index + 1, total: urls.count)
            }

            if !outputs.isEmpty {
                shelf.add(outputs)
                let records = outputs.compactMap { try? GeneratedFileRecord.capture($0) }
                undoAction = records.count == outputs.count ? .generated(records) : nil
                finishBatch(successes: outputs.count, failures: failures)
            } else {
                showError(failures.first ?? FileToolsError.couldNotWriteImage)
            }
            isWorking = false
        }
    }

    private func runSingleFile(
        starting message: String,
        operation: @escaping @Sendable () throws -> URL
    ) {
        guard !isWorking else { return }
        isWorking = true
        undoAction = nil
        showStatus(message, automaticallyClear: false)
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try autoreleasepool { try operation() }
                }.value
                shelf.add([url])
                if let record = try? GeneratedFileRecord.capture(url) {
                    undoAction = .generated([record])
                }
                showStatus(localized("Processed: %d", 1))
            } catch {
                showError(error)
            }
            isWorking = false
        }
    }

    private func showProgress(action: String, completed: Int, total: Int) {
        showStatus(
            localized("%@ %d of %d", action, completed, total),
            automaticallyClear: false
        )
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
