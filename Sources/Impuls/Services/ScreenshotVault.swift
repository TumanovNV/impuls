import AppKit

/// Where clipboard screenshots are kept.
///
/// A screenshot taken to the clipboard exists only in memory: paste it once and
/// it is gone. The vault writes it to disk so the shelf can hold on to it.
/// Nothing here is ever deleted automatically — the folder is the user's.
enum ScreenshotVault {
    private final class PendingSaves: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func begin(maximum: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard count < maximum else { return false }
            count += 1
            return true
        }

        func end() {
            lock.lock()
            count = max(0, count - 1)
            lock.unlock()
        }
    }

    private static let ioQueue = DispatchQueue(
        label: "io.tumanov.impuls.screenshot-vault",
        qos: .utility
    )
    private static let pendingSaves = PendingSaves()
    private static let maximumPendingSaves = 2

    /// `~/Pictures/Impuls` when it can be created — it is findable, and unlike
    /// Desktop or Documents it is not behind a TCC prompt. Falls back to the
    /// app's own support folder, which always works.
    static let folder: URL = {
        let fm = FileManager.default
        let pictures = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent("Impuls", isDirectory: true)
        if (try? fm.createDirectory(at: pictures, withIntermediateDirectories: true)) != nil {
            return pictures
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Impuls", isDirectory: true)
            .appendingPathComponent("Screenshots", isDirectory: true)
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }()

    private static func formattedStamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = localized("yyyy-MM-dd 'at' HH.mm.ss")
        return formatter.string(from: date)
    }

    /// File writes are serialized away from the panel's main thread. The same
    /// queue also orders save, usage and clear operations, so a menu action can
    /// never race an in-flight atomic screenshot write.
    static func save(
        _ png: Data,
        at date: Date = Date(),
        completion: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        guard pendingSaves.begin(maximum: maximumPendingSaves) else {
            Task { @MainActor in completion(nil) }
            return
        }
        ioQueue.async {
            let url = saveSynchronously(png, at: date)
            pendingSaves.end()
            Task { @MainActor in completion(url) }
        }
    }

    private static func saveSynchronously(_ png: Data, at date: Date) -> URL? {
        let base = "\(localized("Screenshot")) \(formattedStamp(for: date))"
        var url = folder.appendingPathComponent("\(base).png")
        // Two screenshots inside one second would otherwise collide.
        var attempt = 2
        while attempt <= 1_000, FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(attempt)).png")
            attempt += 1
        }
        if FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(UUID().uuidString).png")
        }
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            NSLog("Impuls: failed to save image: \(error.localizedDescription)")
            return nil
        }
    }

    static func reveal() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
    }

    /// What the folder holds right now — for the menu item that offers to
    /// clear it, so the offer names its price.
    static func usage(
        completion: @escaping @MainActor @Sendable ((files: Int, bytes: Int64)) -> Void
    ) {
        ioQueue.async {
            let fm = FileManager.default
            let urls = (try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let usage = urls.reduce(into: (files: 0, bytes: Int64(0))) { result, url in
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true else { return }
                result.files += 1
                result.bytes += Int64(values.fileSize ?? 0)
            }
            Task { @MainActor in completion(usage) }
        }
    }

    /// To the Trash, not gone. The folder's promise is that nothing in it is
    /// ever deleted behind the user's back; the menu item is the user's own
    /// hand, and the Trash keeps even that reversible.
    static func clear(completion: @escaping @MainActor @Sendable () -> Void) {
        ioQueue.async {
            let fm = FileManager.default
            let urls = (try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in urls {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                    continue
                }
                try? fm.trashItem(at: url, resultingItemURL: nil)
            }
            Task { @MainActor in completion() }
        }
    }
}
