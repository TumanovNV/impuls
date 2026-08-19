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
    private let statusCode: Int
    private let error: Error?
    private let returnsHTTPResponse: Bool

    init(statusCode: Int = 204, error: Error? = nil, returnsHTTPResponse: Bool = true) {
        self.statusCode = statusCode
        self.error = error
        self.returnsHTTPResponse = returnsHTTPResponse
    }

    var count: Int { requests.count }

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
