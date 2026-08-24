import Foundation
import Security

/// The third and deliberately narrow network boundary in Impuls.
///
/// Update checks and web music have separate owners. This service sends one
/// allow-listed version heartbeat only after an explicit opt-in, and an absent
/// endpoint makes the boundary inert even when consent was recorded earlier.
final class VersionTelemetryService: @unchecked Sendable {
    enum Consent: String, Sendable {
        case unknown, allowed, denied
    }

    enum SendResult: Equatable, Sendable {
        case notAllowed
        case endpointUnavailable
        case throttled
        case sent
        case failed
    }

    struct Payload: Codable, Equatable, Sendable {
        let schema: Int
        let installationID: String
        let appVersion: String
        let previousVersion: String?

        enum CodingKeys: String, CodingKey {
            case schema
            case installationID = "installation_id"
            case appVersion = "app_version"
            case previousVersion = "previous_version"
        }
    }

    typealias Sender = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let consentKey = "versionStatistics.consent.v1"
    static let lastAttemptKey = "versionStatistics.lastAttempt.v1"
    static let lastAttemptVersionKey = "versionStatistics.lastAttemptVersion.v1"
    static let lastSuccessKey = "versionStatistics.lastSuccess.v1"
    static let lastObservedVersionKey = "versionStatistics.lastObservedVersion.v1"
    static let pendingPreviousVersionKey = "versionStatistics.pendingPreviousVersion.v1"
    static let endpointInfoKey = "ImpulsVersionStatisticsEndpoint"
    static let heartbeatInterval: TimeInterval = 60 * 60
    private static let maximumResponseBytes = 1_024
    private static let telemetrySession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        return URLSession(
            configuration: configuration,
            delegate: VersionTelemetrySessionDelegate(),
            delegateQueue: nil
        )
    }()

    private let defaults: UserDefaults
    private let endpoint: URL?
    private let appVersion: String
    private let installationID: @Sendable () throws -> UUID
    private let now: @Sendable () -> Date
    private let sender: Sender
    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        endpoint: URL? = VersionTelemetryService.configuredEndpoint(),
        appVersion: String = Bundle.main.shortVersion,
        installationID: @escaping @Sendable () throws -> UUID = {
            try KeychainInstallationIDStore.shared.identifier()
        },
        now: @escaping @Sendable () -> Date = { Date() },
        sender: @escaping Sender = { request in try await VersionTelemetryService.perform(request) }
    ) {
        self.defaults = defaults
        self.endpoint = Self.validatedEndpoint(endpoint)
        self.appVersion = appVersion
        self.installationID = installationID
        self.now = now
        self.sender = sender
        observeCurrentVersion()
    }

    var consent: Consent {
        lock.withLock {
            defaults.string(forKey: Self.consentKey).flatMap(Consent.init(rawValue:)) ?? .unknown
        }
    }

    var isEndpointConfigured: Bool { endpoint != nil }

    func setConsent(_ consent: Consent) {
        lock.withLock {
            defaults.set(consent.rawValue, forKey: Self.consentKey)
        }
    }

    /// Records the attempt before suspension. A failed server must not turn
    /// each relaunch into another request and exceed the once-per-hour promise.
    ///
    /// The throttle is scoped to `(appVersion, hour)` rather than a bare
    /// timestamp: `lastAttemptVersionKey` is compared alongside `lastAttemptKey`,
    /// so a fresh app version always gets one immediate attempt even when the
    /// previous version attempted minutes ago. Without this, an update that
    /// lands inside a still-cooling-down hour would report the old version to
    /// the dashboard until the next manual relaunch. A version that keeps
    /// failing still gets only one attempt per hour, because both keys are
    /// written together before every attempt, failed or not.
    func sendHeartbeatIfNeeded() async -> SendResult {
        let request: URLRequest
        let previousVersion: String?
        let attemptDate: Date

        do {
            (request, previousVersion, attemptDate) = try lock.withLock {
                guard consentUnlocked == .allowed else { throw Preparation.notAllowed }
                guard let endpoint else { throw Preparation.endpointUnavailable }
                guard let currentVersion = validVersion(appVersion) else { throw Preparation.invalidState }

                let attemptDate = now()
                let lastAttemptVersion = defaults.string(forKey: Self.lastAttemptVersionKey)
                if lastAttemptVersion == currentVersion,
                   let lastAttempt = defaults.object(forKey: Self.lastAttemptKey) as? Date,
                   attemptDate.timeIntervalSince(lastAttempt) < Self.heartbeatInterval {
                    throw Preparation.throttled
                }

                let identifier = try installationID()
                guard (identifier.uuid.6 & 0xF0) >> 4 == 4 else { throw Preparation.invalidState }
                let previous = validVersion(defaults.string(forKey: Self.pendingPreviousVersionKey))
                let payload = Payload(
                    schema: 1,
                    installationID: identifier.uuidString.lowercased(),
                    appVersion: currentVersion,
                    previousVersion: previous
                )
                let body = try Self.encodedPayload(payload)

                var prepared = URLRequest(url: endpoint)
                prepared.httpMethod = "POST"
                prepared.timeoutInterval = 10
                prepared.httpBody = body
                prepared.setValue("application/json", forHTTPHeaderField: "Content-Type")
                prepared.setValue("application/json", forHTTPHeaderField: "Accept")
                defaults.set(attemptDate, forKey: Self.lastAttemptKey)
                defaults.set(currentVersion, forKey: Self.lastAttemptVersionKey)
                return (prepared, previous, attemptDate)
            }
        } catch Preparation.notAllowed {
            return .notAllowed
        } catch Preparation.endpointUnavailable {
            return .endpointUnavailable
        } catch Preparation.throttled {
            return .throttled
        } catch {
            return .failed
        }

        do {
            let (_, response) = try await sender(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 204 else {
                return .failed
            }
            lock.withLock {
                // Distinct from `lastAttemptKey`: an attempt records that the
                // request was made, this records that the collector actually
                // accepted it. Diagnostics tells the two apart by comparing
                // both timestamps rather than reusing one key for both events.
                defaults.set(attemptDate, forKey: Self.lastSuccessKey)
                if let previousVersion, defaults.string(forKey: Self.pendingPreviousVersionKey) == previousVersion {
                    defaults.removeObject(forKey: Self.pendingPreviousVersionKey)
                }
            }
            return .sent
        } catch {
            // Telemetry can never affect launch or any user-facing operation.
            return .failed
        }
    }

    /// A read-only snapshot of local heartbeat state, for a Settings
    /// diagnostics screen or a test — never for the request itself. Building
    /// it touches no network and mutates nothing; it exists so a caller does
    /// not have to reconstruct throttle/success logic that `sendHeartbeatIfNeeded`
    /// already owns.
    struct Diagnostics: Equatable, Sendable {
        enum LastOutcome: Equatable, Sendable {
            case neverAttempted
            case succeeded
            case failed
        }

        enum NextAttempt: Equatable, Sendable {
            case eligibleNow
            case at(Date)
        }

        let consent: Consent
        let isEndpointConfigured: Bool
        /// The exact version string a heartbeat would place in `app_version`
        /// right now — the same value `sendHeartbeatIfNeeded` computes via
        /// `validVersion(appVersion)`, not a second reading of the bundle.
        let currentVersion: String?
        let lastAttemptAt: Date?
        let lastSuccessAt: Date?
        let nextAttempt: NextAttempt
        let lastOutcome: LastOutcome
    }

    func diagnostics() -> Diagnostics {
        lock.withLock {
            let currentVersion = validVersion(appVersion)
            let lastAttemptAt = defaults.object(forKey: Self.lastAttemptKey) as? Date
            let lastAttemptVersion = defaults.string(forKey: Self.lastAttemptVersionKey)
            let lastSuccessAt = defaults.object(forKey: Self.lastSuccessKey) as? Date

            let lastOutcome: Diagnostics.LastOutcome
            if lastAttemptAt == nil {
                lastOutcome = .neverAttempted
            } else if lastAttemptAt == lastSuccessAt {
                lastOutcome = .succeeded
            } else {
                lastOutcome = .failed
            }

            let nextAttempt: Diagnostics.NextAttempt
            if let currentVersion, lastAttemptVersion == currentVersion, let lastAttemptAt {
                let eligibleAt = lastAttemptAt.addingTimeInterval(Self.heartbeatInterval)
                nextAttempt = eligibleAt > now() ? .at(eligibleAt) : .eligibleNow
            } else {
                // No matching prior attempt for this exact version throttles
                // it — the same rule `sendHeartbeatIfNeeded` uses to let an
                // update report itself without waiting out the old version's
                // cooldown.
                nextAttempt = .eligibleNow
            }

            return Diagnostics(
                consent: consentUnlocked,
                isEndpointConfigured: endpoint != nil,
                currentVersion: currentVersion,
                lastAttemptAt: lastAttemptAt,
                lastSuccessAt: lastSuccessAt,
                nextAttempt: nextAttempt,
                lastOutcome: lastOutcome
            )
        }
    }

    static func configuredEndpoint(bundle: Bundle = .main) -> URL? {
        guard let raw = bundle.object(forInfoDictionaryKey: endpointInfoKey) as? String else {
            return nil
        }
        return validatedEndpoint(URL(string: raw))
    }

    static func validatedEndpoint(_ endpoint: URL?) -> URL? {
        guard let endpoint,
              endpoint.scheme == "https",
              let host = endpoint.host, !host.isEmpty,
              endpoint.port == nil,
              endpoint.path == "/v1/heartbeat",
              endpoint.query == nil,
              endpoint.fragment == nil,
              endpoint.user == nil,
              endpoint.password == nil else { return nil }
        return endpoint
    }

    static func encodedPayload(_ payload: Payload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    private static func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await telemetrySession.bytes(for: request)
        var body = Data()
        let advertisedBytes = response.expectedContentLength > 0
            ? min(Int64(maximumResponseBytes), response.expectedContentLength)
            : 0
        body.reserveCapacity(Int(advertisedBytes))
        for try await byte in bytes {
            guard body.count < maximumResponseBytes else { throw TransportError.responseTooLarge }
            body.append(byte)
        }
        return (body, response)
    }

    private enum Preparation: Error {
        case notAllowed
        case endpointUnavailable
        case throttled
        case invalidState
    }

    private enum TransportError: Error {
        case responseTooLarge
    }

    private var consentUnlocked: Consent {
        defaults.string(forKey: Self.consentKey).flatMap(Consent.init(rawValue:)) ?? .unknown
    }

    private func observeCurrentVersion() {
        lock.withLock {
            guard let current = validVersion(appVersion) else { return }
            guard let observed = validVersion(defaults.string(forKey: Self.lastObservedVersionKey)) else {
                // 1.4.9 did not persist its running version. Guessing that it
                // preceded the first 1.4.10 launch would make the metric false,
                // so the first observable transition intentionally has no
                // previous_version.
                defaults.set(current, forKey: Self.lastObservedVersionKey)
                return
            }
            guard observed != current else { return }
            defaults.set(observed, forKey: Self.pendingPreviousVersionKey)
            defaults.set(current, forKey: Self.lastObservedVersionKey)
        }
    }

    private func validVersion(_ value: String?) -> String? {
        guard let value,
              value.count <= 32,
              value.range(
                of: #"^[0-9]+(?:\.[0-9]+){2}(?:[-.][0-9A-Za-z]+)*$"#,
                options: .regularExpression
              ) != nil else { return nil }
        return value
    }
}

private final class VersionTelemetrySessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // The configured collector is the whole boundary. A redirect must not
        // silently turn consent for it into a request to another host.
        completionHandler(nil)
    }
}

final class KeychainInstallationIDStore: @unchecked Sendable {
    static let shared = KeychainInstallationIDStore()

    private let service: String
    private let account: String
    private let lock = NSLock()
    private var cachedIdentifier: UUID?

    init(
        service: String = "io.tumanov.impuls.version-statistics",
        account: String = "installation-id.v1"
    ) {
        self.service = service
        self.account = account
    }

    func identifier() throws -> UUID {
        try lock.withLock {
            if let cachedIdentifier { return cachedIdentifier }
            if let stored = try read() {
                cachedIdentifier = stored
                return stored
            }

            let fresh = UUID()
            let data = Data(fresh.uuidString.lowercased().utf8)
            var add = identityQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem, let stored = try read() {
                cachedIdentifier = stored
                return stored
            }
            guard status == errSecSuccess else { throw StoreError.keychain(status) }
            cachedIdentifier = fresh
            return fresh
        }
    }

    private func read() throws -> UUID? {
        var query = identityQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              data.count <= 64,
              let string = String(data: data, encoding: .utf8),
              let identifier = UUID(uuidString: string) else {
            throw StoreError.keychain(status)
        }
        return identifier
    }

    private var identityQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private enum StoreError: Error {
        case keychain(OSStatus)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
