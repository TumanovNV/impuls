import AppKit
import Foundation

@MainActor
final class FileToolsCoordinator: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var statusIsError = false

    private let shelf: ShelfStore
    private var sharingPicker: NSSharingServicePicker?
    private var statusGeneration = 0

    init(shelf: ShelfStore) {
        self.shelf = shelf
    }

    func recognizeText(in url: URL) {
        runText(
            starting: localized("Recognizing Text…"),
            success: localized("Recognized Text Copied")
        ) {
            try FileToolsService.recognizeText(in: url)
        }
    }

    func convert(_ url: URL, to format: ImageOutputFormat) {
        runFile(
            starting: localized("Converting Image…"),
            success: localized("Converted Image Added to Shelf")
        ) {
            try FileToolsService.convertImage(at: url, to: format)
        }
    }

    func resize(_ url: URL, preset: ImageResizePreset) {
        runFile(
            starting: localized("Reducing Image…"),
            success: localized("Reduced Image Added to Shelf")
        ) {
            try FileToolsService.resizeImage(at: url, maxPixelSize: preset.rawValue)
        }
    }

    func combineIntoPDF(_ urls: [URL]) {
        runFile(
            starting: localized("Creating PDF…"),
            success: localized("PDF Added to Shelf")
        ) {
            try FileToolsService.combineImagesIntoPDF(urls)
        }
    }

    func removeBackground(from url: URL) {
        runFile(
            starting: localized("Removing Background…"),
            success: localized("Transparent Image Added to Shelf")
        ) {
            try FileToolsService.removeBackground(from: url)
        }
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
            let updated = try shelf.rename(item, baseName: field.stringValue)
            showStatus(localized("Renamed to %@", updated.name))
        } catch {
            showError(error)
        }
    }

    private func runText(
        starting message: String,
        success successMessage: String,
        operation: @escaping @Sendable () throws -> String
    ) {
        guard !isWorking else { return }
        isWorking = true
        showStatus(message, isError: false, automaticallyClear: false)
        Task {
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    try operation()
                }.value
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setData(Data(), forType: .impulsInternal)
                pasteboard.setString(text, forType: .string)
                showStatus(successMessage)
            } catch {
                showError(error)
            }
            isWorking = false
        }
    }

    private func runFile(
        starting message: String,
        success successMessage: String,
        operation: @escaping @Sendable () throws -> URL
    ) {
        guard !isWorking else { return }
        isWorking = true
        showStatus(message, isError: false, automaticallyClear: false)
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try operation()
                }.value
                shelf.add([url])
                showStatus(successMessage)
            } catch {
                showError(error)
            }
            isWorking = false
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
