import CryptoKit
import Foundation
import Security

struct ClipboardHistoryArchive: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let items: [ClipItem]

    init(items: [ClipItem]) {
        version = Self.currentVersion
        self.items = items
    }
}

enum EncryptedClipboardArchive {
    static func seal(_ archive: ClipboardHistoryArchive, keyData: Data) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let cleartext = try encoder.encode(archive)
        let sealed = try AES.GCM.seal(cleartext, using: SymmetricKey(data: keyData))
        guard let combined = sealed.combined else { throw ClipboardHistoryPersistenceError.invalidArchive }
        return combined
    }

    static func open(_ data: Data, keyData: Data) throws -> ClipboardHistoryArchive {
        let box = try AES.GCM.SealedBox(combined: data)
        let cleartext = try AES.GCM.open(box, using: SymmetricKey(data: keyData))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(ClipboardHistoryArchive.self, from: cleartext)
        guard archive.version == ClipboardHistoryArchive.currentVersion else {
            throw ClipboardHistoryPersistenceError.invalidArchive
        }
        return archive
    }
}

enum ClipboardHistoryPersistenceError: Error {
    case invalidArchive
    case keychain(OSStatus)
    case randomKey(OSStatus)
}

/// Stores the optional clipboard archive encrypted with AES-GCM. The random
/// 256-bit encryption key never enters UserDefaults or the archive itself; it
/// lives as a device-only generic password in the user's macOS Keychain.
final class ClipboardHistoryPersistence: @unchecked Sendable {
    private static let maximumArchiveBytes = 64 * 1_024 * 1_024
    private static let saveDelay: TimeInterval = 0.75

    private let fileURL: URL
    private let service = "io.tumanov.impuls.clipboard-history"
    private let account = "archive-key.v1"
    private let writeQueue = DispatchQueue(
        label: "io.tumanov.impuls.clipboard-history.writer",
        qos: .utility
    )
    private let stateLock = NSLock()
    private var pendingItems: [ClipItem]?
    private var saveGeneration = 0

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
    }

    func load() -> [ClipItem] {
        guard let encrypted = try? BoundedFileReader.read(
            from: fileURL,
            maximumBytes: Self.maximumArchiveBytes
        ) else { return [] }
        do {
            let key = try keyData(createIfMissing: false)
            return try EncryptedClipboardArchive.open(encrypted, keyData: key).items
        } catch {
            NSLog("Impuls: cannot read encrypted clipboard history: \(error.localizedDescription)")
            return []
        }
    }

    func save(_ items: [ClipItem]) {
        stateLock.lock()
        pendingItems = items
        saveGeneration += 1
        let generation = saveGeneration
        stateLock.unlock()

        writeQueue.asyncAfter(deadline: .now() + Self.saveDelay) { [weak self] in
            self?.writePendingItems(generation: generation)
        }
    }

    /// Called during application shutdown so the last clipboard change reaches
    /// disk without forcing every normal capture to encrypt on the main thread.
    func flush() {
        stateLock.lock()
        saveGeneration += 1
        let items = pendingItems
        pendingItems = nil
        stateLock.unlock()

        guard let items else { return }
        writeQueue.sync { saveImmediately(items) }
    }

    private func writePendingItems(generation: Int) {
        stateLock.lock()
        guard generation == saveGeneration, let items = pendingItems else {
            stateLock.unlock()
            return
        }
        pendingItems = nil
        stateLock.unlock()
        saveImmediately(items)
    }

    private func saveImmediately(_ items: [ClipItem]) {
        do {
            let key = try keyData(createIfMissing: true)
            let encrypted = try EncryptedClipboardArchive.seal(
                ClipboardHistoryArchive(items: items),
                keyData: key
            )
            guard encrypted.count <= Self.maximumArchiveBytes else {
                throw BoundedDataError.limitExceeded
            }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encrypted.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Impuls: cannot save encrypted clipboard history: \(error.localizedDescription)")
        }
    }

    func delete() {
        stateLock.lock()
        saveGeneration += 1
        pendingItems = nil
        stateLock.unlock()

        writeQueue.sync {
            try? FileManager.default.removeItem(at: fileURL)
            SecItemDelete(keychainIdentityQuery() as CFDictionary)
        }
    }

    private func keyData(createIfMissing: Bool) throws -> Data {
        var query = keychainIdentityQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return data }
        guard status == errSecItemNotFound, createIfMissing else {
            throw ClipboardHistoryPersistenceError.keychain(status)
        }

        var key = Data(count: 32)
        let randomStatus = key.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard randomStatus == errSecSuccess else {
            throw ClipboardHistoryPersistenceError.randomKey(randomStatus)
        }

        var add = keychainIdentityQuery()
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ClipboardHistoryPersistenceError.keychain(addStatus)
        }
        return key
    }

    private func keychainIdentityQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("Impuls", isDirectory: true)
            .appendingPathComponent("clipboard-history.v1", isDirectory: false)
    }
}
