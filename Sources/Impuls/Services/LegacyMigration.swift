import Foundation

enum LegacyMigration {
    private static let completedKey = "migration.cyclop.completed"

    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: completedKey) else { return }

        migrateSupportFiles()
        migrateDefaults()
        UserDefaults.standard.set(true, forKey: completedKey)
    }

    private static func migrateSupportFiles() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldFolder = support.appendingPathComponent("Cyclop", isDirectory: true)
        let newFolder = support.appendingPathComponent("Impuls", isDirectory: true)

        guard fm.fileExists(atPath: oldFolder.path) else {
            try? fm.createDirectory(at: newFolder, withIntermediateDirectories: true)
            return
        }
        try? fm.createDirectory(at: newFolder, withIntermediateDirectories: true)

        for name in ["notes.json", "snippets.json"] {
            let source = oldFolder.appendingPathComponent(name)
            let destination = newFolder.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path),
                  !fm.fileExists(atPath: destination.path) else { continue }
            do {
                try fm.copyItem(at: source, to: destination)
            } catch {
                NSLog("Impuls: failed to migrate \(name): \(error.localizedDescription)")
            }
        }
    }

    private static func migrateDefaults() {
        guard let legacy = UserDefaults(suiteName: "com.cyclop.app") else { return }
        for key in ["shelf.urls", "saveClipboardImages"] where UserDefaults.standard.object(forKey: key) == nil {
            if let value = legacy.object(forKey: key) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
    }
}
