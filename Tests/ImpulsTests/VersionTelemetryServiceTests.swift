import Foundation
import Security
import XCTest
@testable import ImpulsCore

final class VersionTelemetryServiceTests: XCTestCase {
    func testUnknownAndDeniedConsentSendNoRequest() async throws {
        let harness = Harness()
        let unknown = harness.service()

        let unknownResult = await unknown.sendHeartbeatIfNeeded()
        let unknownCount = await harness.recorder.count
        XCTAssertEqual(unknownResult, .notAllowed)
        XCTAssertEqual(unknownCount, 0)

        unknown.setConsent(.denied)
        let deniedResult = await unknown.sendHeartbeatIfNeeded()
        let deniedCount = await harness.recorder.count
        XCTAssertEqual(deniedResult, .notAllowed)
        XCTAssertEqual(deniedCount, 0)
    }

    func testAllowedConsentSendsOnlyTheMinimalAllowListedPayload() async throws {
        let harness = Harness()
        harness.defaults.set("1.4.9", forKey: VersionTelemetryService.lastObservedVersionKey)
        let service = harness.service()
        service.setConsent(.allowed)

        let result = await service.sendHeartbeatIfNeeded()
        let requests = await harness.recorder.requests
        XCTAssertEqual(result, .sent)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://stats.example/v1/heartbeat")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["schema", "installation_id", "app_version", "previous_version"])
        XCTAssertEqual(object["schema"] as? Int, 1)
        XCTAssertEqual(object["installation_id"] as? String, harness.identifier.uuidString.lowercased())
        XCTAssertEqual(object["app_version"] as? String, "1.4.10")
        XCTAssertEqual(object["previous_version"] as? String, "1.4.9")
    }

    func testFirstObservedVersionIsNotGuessedAsAnUpgrade() async throws {
        let harness = Harness()
        let service = harness.service()
        service.setConsent(.allowed)

        let result = await service.sendHeartbeatIfNeeded()
        let requests = await harness.recorder.requests
        XCTAssertEqual(result, .sent)
        let request = try XCTUnwrap(requests.first)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["schema", "installation_id", "app_version"])
    }

    func testSuccessfulHeartbeatIsThrottledForOneHour() async {
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let harness = Harness(clock: clock)
        let service = harness.service()
        service.setConsent(.allowed)

        let first = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(first, .sent)

        clock.advance(by: 59 * 60 + 59)
        let throttled = await service.sendHeartbeatIfNeeded()
        let firstCount = await harness.recorder.count
        XCTAssertEqual(throttled, .throttled)
        XCTAssertEqual(firstCount, 1)

        clock.advance(by: 1)
        let second = await service.sendHeartbeatIfNeeded()
        let secondCount = await harness.recorder.count
        XCTAssertEqual(second, .sent)
        XCTAssertEqual(secondCount, 2)
    }

    func testFailedHeartbeatIsAlsoThrottledForOneHour() async {
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let recorder = RequestRecorder(statusCode: 500)
        let harness = Harness(clock: clock, recorder: recorder)
        let service = harness.service()
        service.setConsent(.allowed)

        let first = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(first, .failed)
        clock.advance(by: 59 * 60 + 59)
        let throttled = await service.sendHeartbeatIfNeeded()
        let firstCount = await recorder.count
        XCTAssertEqual(throttled, .throttled)
        XCTAssertEqual(firstCount, 1)

        clock.advance(by: 1)
        let second = await service.sendHeartbeatIfNeeded()
        let secondCount = await recorder.count
        XCTAssertEqual(second, .failed)
        XCTAssertEqual(secondCount, 2)
    }

    func testAnAttemptFromAnOlderVersionDoesNotThrottleAFreshVersionsFirstAttempt() async {
        // The exact scenario this throttle change exists to fix: 1.4.13 attempts,
        // the Mac updates to 1.4.14 minutes later, and the new version must not
        // wait out the old version's hour before it can report itself.
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let harness = Harness(clock: clock)
        let oldService = harness.service(appVersion: "1.4.13")
        oldService.setConsent(.allowed)
        let firstResult = await oldService.sendHeartbeatIfNeeded()
        XCTAssertEqual(firstResult, .sent)

        clock.advance(by: 10 * 60)
        let newService = harness.service(appVersion: "1.4.14")
        let secondResult = await newService.sendHeartbeatIfNeeded()
        XCTAssertEqual(secondResult, .sent)
        let count = await harness.recorder.count
        XCTAssertEqual(count, 2)
    }

    func testSameVersionSecondAttemptWithinTheHourIsThrottled() async {
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let harness = Harness(clock: clock)
        let service = harness.service(appVersion: "1.4.14")
        service.setConsent(.allowed)
        let first = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(first, .sent)

        clock.advance(by: 30 * 60)
        let relaunched = harness.service(appVersion: "1.4.14")
        let second = await relaunched.sendHeartbeatIfNeeded()
        XCTAssertEqual(second, .throttled)
        let count = await harness.recorder.count
        XCTAssertEqual(count, 1)
    }

    func testSameVersionAttemptAtExactlyOneHourIsAllowed() async {
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let harness = Harness(clock: clock)
        let service = harness.service(appVersion: "1.4.14")
        service.setConsent(.allowed)
        let first = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(first, .sent)

        clock.advance(by: VersionTelemetryService.heartbeatInterval)
        let second = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(second, .sent)
        let count = await harness.recorder.count
        XCTAssertEqual(count, 2)
    }

    func testFailureOfANewVersionIsThrottledOnAnImmediateRelaunch() async {
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let recorder = RequestRecorder(statusCode: 500)
        let harness = Harness(clock: clock, recorder: recorder)
        let service = harness.service(appVersion: "1.4.14")
        service.setConsent(.allowed)
        let first = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(first, .failed)

        // A new process, same version, same clock: the failed attempt already
        // recorded must still gate the retry.
        let relaunched = harness.service(appVersion: "1.4.14")
        let second = await relaunched.sendHeartbeatIfNeeded()
        XCTAssertEqual(second, .throttled)
        let count = await recorder.count
        XCTAssertEqual(count, 1)
    }

    func testFailureIsRetriedOnlyAfterAFullHour() async {
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let recorder = RequestRecorder(statusCode: 500)
        let harness = Harness(clock: clock, recorder: recorder)
        let service = harness.service(appVersion: "1.4.14")
        service.setConsent(.allowed)
        let first = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(first, .failed)

        clock.advance(by: VersionTelemetryService.heartbeatInterval)
        let second = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(second, .failed)
        let count = await recorder.count
        XCTAssertEqual(count, 2)
    }

    func testMigrationFromBeforeVersionAwareThrottleAllowsAnImmediateAttempt() async {
        // An install upgraded from before `lastAttemptVersionKey` existed has a
        // recent `lastAttemptKey` but no recorded version. That must not block
        // the first 1.4.14 attempt.
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let harness = Harness(clock: clock)
        harness.defaults.set(clock.now(), forKey: VersionTelemetryService.lastAttemptKey)
        let service = harness.service(appVersion: "1.4.14")
        service.setConsent(.allowed)

        let result = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(result, .sent)
    }

    func testPendingPreviousVersionSurvivesAFailedAttempt() async {
        let harness = Harness(recorder: RequestRecorder(statusCode: 500))
        harness.defaults.set("1.4.9", forKey: VersionTelemetryService.lastObservedVersionKey)
        let service = harness.service()
        service.setConsent(.allowed)

        let result = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(
            harness.defaults.string(forKey: VersionTelemetryService.pendingPreviousVersionKey),
            "1.4.9"
        )
    }

    func testPendingPreviousVersionIsRemovedOnlyAfterASuccessful204() async {
        let harness = Harness()
        harness.defaults.set("1.4.9", forKey: VersionTelemetryService.lastObservedVersionKey)
        let service = harness.service()
        service.setConsent(.allowed)

        XCTAssertEqual(
            harness.defaults.string(forKey: VersionTelemetryService.pendingPreviousVersionKey),
            "1.4.9"
        )
        let result = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(result, .sent)
        XCTAssertNil(harness.defaults.string(forKey: VersionTelemetryService.pendingPreviousVersionKey))
    }

    func testMissingEndpointSendsNoRequest() async {
        let harness = Harness()
        let recorder = harness.recorder
        let identifier = harness.identifier
        let clock = harness.clock
        let service = VersionTelemetryService(
            defaults: harness.defaults,
            endpoint: nil,
            appVersion: "1.4.14",
            installationID: { identifier },
            now: { clock.now() },
            sender: { request in try await recorder.send(request) }
        )
        service.setConsent(.allowed)

        let result = await service.sendHeartbeatIfNeeded()
        let count = await recorder.count
        XCTAssertEqual(result, .endpointUnavailable)
        XCTAssertEqual(count, 0)
    }

    func testNetworkErrorDoesNotEscapeAndCannotAffectTheApplication() async {
        let harness = Harness(recorder: RequestRecorder(error: URLError(.timedOut)))
        let service = harness.service()
        service.setConsent(.allowed)

        let result = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(result, .failed)
    }

    func testMalformedNonHTTPResponseDoesNotEscape() async {
        let harness = Harness(recorder: RequestRecorder(returnsHTTPResponse: false))
        let service = harness.service()
        service.setConsent(.allowed)

        let result = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(result, .failed)
    }

    func testPreviousVersionIsSentOnceAfterASuccessfulTransition() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let harness = Harness(clock: clock)
        harness.defaults.set("1.4.9", forKey: VersionTelemetryService.lastObservedVersionKey)
        let service = harness.service()
        service.setConsent(.allowed)

        let firstResult = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(firstResult, .sent)
        clock.advance(by: VersionTelemetryService.heartbeatInterval)
        let secondResult = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(secondResult, .sent)

        let requests = await harness.recorder.requests
        let first = try jsonObject(requests[0])
        let second = try jsonObject(requests[1])
        XCTAssertEqual(first["previous_version"] as? String, "1.4.9")
        XCTAssertNil(second["previous_version"])
    }

    func testObservedUpgradeFrom1_4_10To1_4_11SendsTheExactTransitionPayload() async throws {
        let harness = Harness()
        harness.defaults.set("1.4.10", forKey: VersionTelemetryService.lastObservedVersionKey)
        let service = harness.service(appVersion: "1.4.11")
        service.setConsent(.allowed)

        let result = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(result, .sent)

        let requests = await harness.recorder.requests
        let request = try XCTUnwrap(requests.first)
        let payload = try jsonObject(request)
        XCTAssertEqual(payload["app_version"] as? String, "1.4.11")
        XCTAssertEqual(payload["previous_version"] as? String, "1.4.10")
    }

    func testEndpointMustBeTheExactHTTPSHeartbeatRoute() throws {
        XCTAssertNotNil(VersionTelemetryService.validatedEndpoint(
            try XCTUnwrap(URL(string: "https://stats.example/v1/heartbeat"))
        ))
        for raw in [
            "http://stats.example/v1/heartbeat",
            "https://stats.example/v1/heartbeat?installation_id=leak",
            "https://user@stats.example/v1/heartbeat",
            "https://stats.example/another-path",
        ] {
            XCTAssertNil(VersionTelemetryService.validatedEndpoint(try XCTUnwrap(URL(string: raw))))
        }
    }

    func testInstallationIdentifierIsRandomStableAndNotHardwareDerived() throws {
        let service = "io.tumanov.impuls.tests.version-statistics.\(UUID().uuidString)"
        let independentService = "io.tumanov.impuls.tests.version-statistics.\(UUID().uuidString)"
        let account = "installation-id.v1"
        defer {
            for keychainService in [service, independentService] {
                SecItemDelete([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: keychainService,
                    kSecAttrAccount as String: account,
                ] as CFDictionary)
            }
        }

        let first = try KeychainInstallationIDStore(service: service, account: account).identifier()
        let second = try KeychainInstallationIDStore(service: service, account: account).identifier()
        let independent = try KeychainInstallationIDStore(
            service: independentService,
            account: account
        ).identifier()

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(
            first,
            independent,
            "Separate installations must not collapse to a Mac-derived identifier"
        )
        XCTAssertEqual((first.uuid.6 & 0xF0) >> 4, 4, "Foundation UUID() produces a random version-4 UUID")
        XCTAssertEqual((independent.uuid.6 & 0xF0) >> 4, 4)
    }

    // MARK: - Diagnostics

    func testDiagnosticsShowsDisabledWhenConsentIsNotAllowed() async {
        let harness = Harness()
        let unknown = harness.service()
        XCTAssertNotEqual(unknown.diagnostics().consent, .allowed)

        unknown.setConsent(.denied)
        XCTAssertEqual(unknown.diagnostics().consent, .denied)
        XCTAssertNotEqual(unknown.diagnostics().consent, .allowed)
    }

    func testDiagnosticsEnabledButNeverAttempted() {
        let harness = Harness()
        let service = harness.service()
        service.setConsent(.allowed)

        let diagnostics = service.diagnostics()
        XCTAssertEqual(diagnostics.consent, .allowed)
        XCTAssertNil(diagnostics.lastAttemptAt)
        XCTAssertNil(diagnostics.lastSuccessAt)
        XCTAssertEqual(diagnostics.lastOutcome, .neverAttempted)
        XCTAssertEqual(diagnostics.nextAttempt, .eligibleNow)
    }

    func testSuccessfulAttemptRecordsBothAttemptAndSuccess() async {
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let harness = Harness(clock: clock)
        let service = harness.service()
        service.setConsent(.allowed)

        let result = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(result, .sent)

        let diagnostics = service.diagnostics()
        XCTAssertEqual(diagnostics.lastAttemptAt, clock.now())
        XCTAssertEqual(diagnostics.lastSuccessAt, clock.now())
        XCTAssertEqual(diagnostics.lastOutcome, .succeeded)
    }

    func testFailedAttemptRecordsAttemptButNotSuccess() async {
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let harness = Harness(clock: clock, recorder: RequestRecorder(statusCode: 500))
        let service = harness.service()
        service.setConsent(.allowed)

        let result = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(result, .failed)

        let diagnostics = service.diagnostics()
        XCTAssertEqual(diagnostics.lastAttemptAt, clock.now(), "a failed attempt is still an attempt")
        XCTAssertNil(diagnostics.lastSuccessAt, "a failed attempt must never be recorded as a success")
        XCTAssertEqual(diagnostics.lastOutcome, .failed)
    }

    func testASucceedingRetryAfterAFailureUpdatesOutcomeToSucceeded() async {
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let recorder = RequestRecorder(statusCode: 500)
        let harness = Harness(clock: clock, recorder: recorder)
        let service = harness.service()
        service.setConsent(.allowed)

        let first = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(first, .failed)
        XCTAssertEqual(service.diagnostics().lastOutcome, .failed)

        await recorder.setStatusCode(204)
        clock.advance(by: VersionTelemetryService.heartbeatInterval)
        let second = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(second, .sent)

        let diagnostics = service.diagnostics()
        XCTAssertEqual(diagnostics.lastOutcome, .succeeded)
        XCTAssertEqual(diagnostics.lastAttemptAt, diagnostics.lastSuccessAt)
    }

    func testDiagnosticsCurrentVersionMatchesTheExactHeartbeatPayloadVersion() async throws {
        let harness = Harness()
        let service = harness.service(appVersion: "1.4.16")
        service.setConsent(.allowed)

        let diagnostics = service.diagnostics()
        let result = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(result, .sent)

        let requests = await harness.recorder.requests
        let payload = try jsonObject(try XCTUnwrap(requests.first))
        XCTAssertEqual(diagnostics.currentVersion, payload["app_version"] as? String)
        XCTAssertEqual(diagnostics.currentVersion, "1.4.16")
    }

    func testDiagnosticsNextAttemptMatchesTheExistingThrottleCadence() async {
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let harness = Harness(clock: clock)
        let service = harness.service(appVersion: "1.4.16")
        service.setConsent(.allowed)

        let result = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(
            service.diagnostics().nextAttempt,
            .at(clock.now().addingTimeInterval(VersionTelemetryService.heartbeatInterval))
        )

        clock.advance(by: 59 * 60 + 59)
        XCTAssertNotEqual(service.diagnostics().nextAttempt, .eligibleNow, "still inside the one-hour window")

        clock.advance(by: 1)
        XCTAssertEqual(service.diagnostics().nextAttempt, .eligibleNow)
    }

    func testDiagnosticsForANewVersionIsEligibleNowDespiteAnOldVersionsRecentAttempt() async {
        // The exact update scenario the throttle carve-out exists for: the old
        // version's cooldown must not make diagnostics claim the new version
        // has to wait too.
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let harness = Harness(clock: clock)
        let oldService = harness.service(appVersion: "1.4.15")
        oldService.setConsent(.allowed)
        let oldResult = await oldService.sendHeartbeatIfNeeded()
        XCTAssertEqual(oldResult, .sent)

        clock.advance(by: 60)
        let newService = harness.service(appVersion: "1.4.16")
        let diagnostics = newService.diagnostics()
        XCTAssertEqual(diagnostics.currentVersion, "1.4.16")
        XCTAssertEqual(diagnostics.nextAttempt, .eligibleNow)
    }

    func testReadingDiagnosticsNeverSendsARequestEvenWhenCalledRepeatedly() async {
        let harness = Harness()
        let service = harness.service()
        service.setConsent(.allowed)

        for _ in 0..<5 {
            _ = service.diagnostics()
        }
        let count = await harness.recorder.count
        XCTAssertEqual(count, 0, "reading diagnostics must never be the trigger for a heartbeat")
    }

    func testDiagnosticsSurvivesRelaunchViaTheSamePersistedState() async {
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let harness = Harness(clock: clock)
        let service = harness.service()
        service.setConsent(.allowed)
        let result = await service.sendHeartbeatIfNeeded()
        XCTAssertEqual(result, .sent)

        // A new process reading the same UserDefaults suite/Keychain: only the
        // consent, throttle and success state that were actually persisted
        // survive, not any process-local value.
        let relaunched = harness.service()
        let diagnostics = relaunched.diagnostics()
        XCTAssertEqual(diagnostics.consent, .allowed)
        XCTAssertEqual(diagnostics.lastAttemptAt, clock.now())
        XCTAssertEqual(diagnostics.lastSuccessAt, clock.now())
        XCTAssertEqual(diagnostics.lastOutcome, .succeeded)
    }

    func testDiagnosticsNeverExposesTheRawInstallationIdentifier() async {
        let harness = Harness()
        let service = harness.service()
        service.setConsent(.allowed)
        _ = await service.sendHeartbeatIfNeeded()

        let diagnostics = service.diagnostics()
        let rawIdentifier = harness.identifier.uuidString
        for child in Mirror(reflecting: diagnostics).children {
            let value = String(describing: child.value)
            XCTAssertFalse(
                value.localizedCaseInsensitiveContains(rawIdentifier),
                "diagnostics must never carry the raw installation identifier"
            )
        }
    }

    private func jsonObject(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private actor RequestRecorder {
    private(set) var requests: [URLRequest] = []
    private var statusCode: Int
    private let error: Error?
    private let returnsHTTPResponse: Bool

    init(statusCode: Int = 204, error: Error? = nil, returnsHTTPResponse: Bool = true) {
        self.statusCode = statusCode
        self.error = error
        self.returnsHTTPResponse = returnsHTTPResponse
    }

    var count: Int { requests.count }

    /// Lets one test simulate a collector that starts rejecting requests and
    /// later recovers, without needing a second recorder/service pair.
    func setStatusCode(_ statusCode: Int) {
        self.statusCode = statusCode
    }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        if let error { throw error }
        if !returnsHTTPResponse {
            return (Data("malformed".utf8), URLResponse(
                url: request.url!,
                mimeType: "application/json",
                expectedContentLength: 9,
                textEncodingName: "utf-8"
            ))
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (Data(), response)
    }
}

private final class Harness {
    let defaults: UserDefaults
    let identifier = UUID(uuidString: "3E5DC194-6512-44BB-B24A-1C700DB39D90")!
    let clock: TestClock
    let recorder: RequestRecorder
    private let suite: String

    init(
        clock: TestClock = TestClock(Date(timeIntervalSince1970: 10_000)),
        recorder: RequestRecorder = RequestRecorder()
    ) {
        suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        self.clock = clock
        self.recorder = recorder
    }

    deinit { defaults.removePersistentDomain(forName: suite) }

    func service(appVersion: String = "1.4.10") -> VersionTelemetryService {
        let recorder = recorder
        let identifier = identifier
        let clock = clock
        return VersionTelemetryService(
            defaults: defaults,
            endpoint: URL(string: "https://stats.example/v1/heartbeat"),
            appVersion: appVersion,
            installationID: { identifier },
            now: { clock.now() },
            sender: { request in try await recorder.send(request) }
        )
    }
}
