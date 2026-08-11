import CryptoKit
import Foundation
import Security

/// A device's identity inside Impuls, with the hardware identifier removed.
///
/// Deduplication needs a stable key: the same iPhone seen over USB and over
/// Wi-Fi has to be one row. The obvious key — the UDID, the serial number, the
/// Bluetooth address — is exactly what must not travel through the application,
/// because every value that exists somewhere eventually gets logged, exported
/// or attached to a report by someone who did not know what it was.
///
/// A plain `SHA256(serial)` is not an answer either. Serial numbers and UDIDs
/// come from a small, structured space, so a deterministic digest of one is
/// recoverable by enumeration; treating such a digest as anonymous is a
/// comfortable mistake rather than a protection. What is used instead:
///
/// - this Mac has no derived value at all. It is `.localMac`, a case, and its
///   serial number is never read because nothing needs it;
/// - every other device gets an HMAC keyed with 32 random bytes generated on
///   this Mac and kept in its Keychain. Without that key the value cannot be
///   linked back to a device or matched against the same device on another
///   machine, and the key never leaves this one;
/// - the type is deliberately **not** `Codable`, so it cannot be swept into a
///   backup, a feedback payload or a settings blob by an outer type that just
///   added `Codable` to its own declaration;
/// - `description` and `debugDescription` are overridden, so interpolating an
///   identity into a log line — the way these things actually leak — prints a
///   redaction rather than the value.
///
/// The raw identifier exists only as an argument to `DeviceIdentityResolver`.
/// It is not stored, not returned and not reachable from the domain model.
struct AppleDeviceIdentity: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private enum Storage: Hashable, Sendable {
        case localMac
        case keyed(String)
    }

    private let storage: Storage

    private init(storage: Storage) {
        self.storage = storage
    }

    /// The Mac running Impuls. One machine, one identity, no derivation.
    static let localMac = AppleDeviceIdentity(storage: .localMac)

    fileprivate init(keyedValue: String) {
        storage = .keyed(keyedValue)
    }

    var isLocalMac: Bool { storage == .localMac }

    var description: String {
        switch storage {
        case .localMac: return "AppleDeviceIdentity(localMac)"
        case .keyed: return "AppleDeviceIdentity(redacted)"
        }
    }

    var debugDescription: String { description }

    /// The only way to obtain a storable string, named so that writing one into
    /// a file is a deliberate act rather than a side effect of serialisation.
    ///
    /// Per-device preferences in Settings need a key that survives a relaunch.
    /// That key belongs in local `UserDefaults` on this Mac and nowhere else:
    /// not in an exported backup, not in a feedback report. Being derived
    /// rather than raw is not a reason to move it.
    var localPreferenceKey: String {
        switch storage {
        case .localMac: return "localMac"
        case .keyed(let value): return value
        }
    }
}

/// Turns a hardware identifier into an `AppleDeviceIdentity` and forgets it.
///
/// This is the identity-resolution boundary the providers hand raw values to.
/// It is the only place in Impuls where a UDID or a Bluetooth address is a
/// `String`, and it returns nothing that could be used to reconstruct one.
///
/// Providers call this from their own I/O contexts, so it is thread-safe by
/// lock rather than by actor: the work is a single HMAC and the lock is held
/// only while the key is being fetched once.
final class DeviceIdentityResolver: @unchecked Sendable {
    static let shared = DeviceIdentityResolver()

    private let service: String
    private let account: String
    private let lock = NSLock()
    private var cachedKey: SymmetricKey?

    init(service: String = "io.tumanov.impuls.device-identity", account: String = "device-identity-key.v1") {
        self.service = service
        self.account = account
    }

    /// `kind` participates in the digest so that two different devices which
    /// somehow present the same string — a Bluetooth address reused by a
    /// successor product, a placeholder value — do not collapse into one row.
    func identity(forRawIdentifier rawIdentifier: String, kind: AppleDeviceKind) -> AppleDeviceIdentity? {
        let trimmed = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var message = Data(kind.rawValue.utf8)
        message.append(0x1F)
        message.append(Data(trimmed.lowercased().utf8))

        let code = HMAC<SHA256>.authenticationCode(for: message, using: key())
        // Half the digest. 128 bits cannot collide by accident across the
        // handful of devices one person owns, and a shorter value is less
        // tempting to treat as a general-purpose device key.
        let hex = code.prefix(16).map { String(format: "%02x", $0) }.joined()
        return AppleDeviceIdentity(keyedValue: hex)
    }

    private func key() -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        let key = SymmetricKey(data: keyMaterial())
        cachedKey = key
        return key
    }

    /// Keychain first; a process-lifetime key if the Keychain is unavailable.
    ///
    /// The fallback keeps deduplication working inside one run — which is what
    /// the Battery Center actually needs — and degrades only the persistence of
    /// per-device preferences. A test runner, a locked keychain or a sandbox
    /// without the entitlement must not take the module down with them.
    private func keyMaterial() -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }

        var fresh = Data(count: 32)
        let randomStatus = fresh.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard randomStatus == errSecSuccess else {
            return Data(SymmetricKey(size: .bits256).withUnsafeBytes(Array.init))
        }

        if status == errSecItemNotFound {
            query[kSecValueData as String] = fresh
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(query as CFDictionary, nil)
        }
        return fresh
    }
}
