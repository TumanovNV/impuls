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

/// Why `load` came back with nothing.
///
/// "There is no history yet" and "the history is there but this process could
/// not open it" are the same empty list to a caller that only sees `[ClipItem]`,
/// and they call for opposite behaviour: the first is safe to write over, the
/// second is the user's data. The login keychain being locked, an interrupted
/// write or an archive from a newer build all land in the second case and all
/// recover on their own later — but only if nothing sealed an empty list over
/// them in the meantime.
enum ClipboardHistoryLoad: Equatable {
    case loaded([ClipItem])
    case unreadable

    var items: [ClipItem] {
        switch self {
        case .loaded(let items): return items
        case .unreadable: return []
        }
    }

    var isUnreadable: Bool { self == .unreadable }
}

/// Stores the optional clipboard archive encrypted with AES-GCM. The random
/// 256-bit encryption key never enters UserDefaults or the archive itself; it
/// lives as a device-only generic password in the user's macOS Keychain.
final class ClipboardHistoryPersistence: @unchecked Sendable {
    private static let maximumArchiveBytes = 64 * 1_024 * 1_024
    private static let saveDelay: TimeInterval = 0.75

    static let defaultService = "io.tumanov.impuls.clipboard-history"
    static let defaultAccount = "archive-key.v1"

    private let fileURL: URL
    private let service: String
    private let account: String
    private let writeQueue = DispatchQueue(
        label: "io.tumanov.impuls.clipboard-history.writer",
        qos: .utility
    )
    private let stateLock = NSLock()
    private var pendingItems: [ClipItem]?
    private var saveGeneration = 0

    /// The write latch. Set when `load` found an archive it could not open,
    /// cleared when a later `load` succeeds or the user deliberately deletes
    /// the archive.
    ///
    /// It lives here rather than in `ClipboardStore` because this object is the
    /// only one that touches the file, and every write funnels through
    /// `saveImmediately` — the debounced `save`, the queued `writePendingItems`
    /// and the shutdown `flush` alike. One guard there cannot be stepped around
    /// by a new caller, which a guard in `configurePersistence` could be, and
    /// was: the toggle was protected while the very next clipboard change,
    /// retention edit or quit still sealed an empty list over the archive.
    private var archiveIsUnreadable = false

    /// The keychain coordinates are injectable for the same reason
    /// `DeviceIdentityResolver`'s are: a test that exercises the write path must
    /// not be able to mint or delete the key that decrypts the developer's own
    /// clipboard archive.
    init(fileURL: URL? = nil, service: String = defaultService, account: String = defaultAccount) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.service = service
        self.account = account
    }

    /// Whether an existing archive could not be read, so no write may land.
    ///
    /// Exposed so the store can retry the read at the few explicit moments it
    /// already has — configuration and shutdown — rather than this class
    /// growing a poller for a condition that changes only when the user does
    /// something.
    var isBlockedByUnreadableArchive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return archiveIsUnreadable
    }

    func load() -> ClipboardHistoryLoad {
        // No archive yet is the ordinary first-run case and is safe to write
        // over. Every other failure below means one exists and this process
        // could not open it, which is not the same thing.
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            setArchiveIsUnreadable(false)
            return .loaded([])
        }
        do {
            let encrypted = try BoundedFileReader.read(
                from: fileURL,
                maximumBytes: Self.maximumArchiveBytes
            )
            let key = try keyData(createIfMissing: false)
            let items = try EncryptedClipboardArchive.open(encrypted, keyData: key).items
            // Reading is what proves the archive is ours to replace. This is
            // the only path that unlatches, and recovery therefore cannot
            // happen by accident.
            setArchiveIsUnreadable(false)
            return .loaded(items)
        } catch {
            NSLog("Impuls: cannot read encrypted clipboard history: \(error.localizedDescription)")
            setArchiveIsUnreadable(true)
            return .unreadable
        }
    }

    private func setArchiveIsUnreadable(_ value: Bool) {
        stateLock.lock()
        archiveIsUnreadable = value
        stateLock.unlock()
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

    /// The one place the archive file is written, and therefore the one place
    /// the latch has to hold.
    private func saveImmediately(_ items: [ClipItem]) {
        guard !isBlockedByUnreadableArchive else {
            // Not silent: the items are still in memory and still shown, but a
            // reader of the log has to be able to tell that this session's
            // history is not reaching disk, and why.
            NSLog(
                "Impuls: clipboard history not written — an existing archive could not be read; "
                    + "\(items.count) item(s) are kept in memory only until a read succeeds"
            )
            return
        }
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

    /// Switching persistence off is the explicit destructive reset, and it is
    /// the only action allowed past the latch: the user is asking for the
    /// archive and its key to be gone, unreadable or not. Nothing automatic
    /// reaches here.
    func delete() {
        stateLock.lock()
        saveGeneration += 1
        pendingItems = nil
        archiveIsUnreadable = false
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
