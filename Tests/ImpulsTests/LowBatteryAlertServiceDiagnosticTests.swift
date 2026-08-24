import Combine
import XCTest
@testable import ImpulsCore

@MainActor
final class LowBatteryAlertServiceDiagnosticTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testExplicitTestNotificationUsesNoBatteryState() async {
        let store = DiagnosticAlertStateStore()
        let delivery = DiagnosticAlertDelivery(status: .authorized)
        let service = LowBatteryAlertService(
            engine: LowBatteryAlertEngine(store: store),
            delivery: delivery
        )
        let authorized = expectation(description: "authorization published")
        service.$authorization
            .dropFirst()
            .filter { $0 == .authorized }
            .prefix(1)
            .sink { _ in authorized.fulfill() }
            .store(in: &cancellables)

        service.setEnabled(true, requestAuthorization: false)
        await fulfillment(of: [authorized], timeout: 2)

        let delivered = expectation(description: "test notification delivered")
        delivery.onDelivery = delivered
        service.sendTestNotification()
        await fulfillment(of: [delivered], timeout: 2)

        XCTAssertEqual(delivery.notifications.count, 1)
        XCTAssertEqual(delivery.notifications.first?.devicePreferenceKey, "qa")
        XCTAssertEqual(delivery.notifications.first?.title, localized("Impuls Notification QA"))
        XCTAssertEqual(
            delivery.notifications.first?.body,
            localized("Test notification only. No device battery reading was used.")
        )
        XCTAssertNil(store.data, "a diagnostic notification must never mutate low-battery policy state")
        XCTAssertFalse(service.testNotificationInFlight)
    }

    func testDeniedAuthorizationCannotSendDiagnosticNotification() async {
        let delivery = DiagnosticAlertDelivery(status: .denied)
        let service = LowBatteryAlertService(
            engine: LowBatteryAlertEngine(store: DiagnosticAlertStateStore()),
            delivery: delivery
        )
        let denied = expectation(description: "denied authorization published")
        service.$authorization
            .dropFirst()
            .filter { $0 == .denied }
            .prefix(1)
            .sink { _ in denied.fulfill() }
            .store(in: &cancellables)

        service.setEnabled(true, requestAuthorization: false)
        await fulfillment(of: [denied], timeout: 2)
        service.sendTestNotification()

        XCTAssertTrue(delivery.notifications.isEmpty)
        XCTAssertFalse(service.testNotificationInFlight)
    }

    func testExplicitAuthorizationRequestIsTheOnlyPathThatPrompts() async {
        let delivery = DiagnosticAlertDelivery(status: .notDetermined)
        let service = LowBatteryAlertService(
            engine: LowBatteryAlertEngine(store: DiagnosticAlertStateStore()),
            delivery: delivery
        )

        service.setEnabled(true, requestAuthorization: false)
        let initialRead = expectation(description: "restored preference only reads status")
        delivery.onStatusRead = initialRead
        service.refreshAuthorization(requestIfNeeded: false)
        await fulfillment(of: [initialRead], timeout: 2)
        XCTAssertEqual(delivery.requestCount, 0)

        let requested = expectation(description: "explicit action requests authorization")
        delivery.onRequest = requested
        service.requestAuthorization()
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertEqual(delivery.requestCount, 1)
    }
}

private final class DiagnosticAlertStateStore: LowBatteryAlertStateStoring {
    var data: Data?
    func load() -> Data? { data }
    func save(_ data: Data) { self.data = data }
}

private final class DiagnosticAlertDelivery: LowBatteryNotificationDelivering, @unchecked Sendable {
    var onNotificationOpened: (@MainActor @Sendable (String?) -> Void)?
    var onDelivery: XCTestExpectation?
    var onStatusRead: XCTestExpectation?
    var onRequest: XCTestExpectation?
    private(set) var notifications: [LowBatteryNotification] = []
    private(set) var requestCount = 0
    private let lock = NSLock()
    private var status: LowBatteryNotificationAuthorization

    init(status: LowBatteryNotificationAuthorization) {
        self.status = status
    }

    func authorizationStatus() async -> LowBatteryNotificationAuthorization {
        onStatusRead?.fulfill()
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    func requestAuthorization() async -> LowBatteryNotificationAuthorization {
        lock.lock()
        requestCount += 1
        status = .authorized
        lock.unlock()
        onRequest?.fulfill()
        return .authorized
    }

    func deliver(_ notification: LowBatteryNotification) async throws {
        lock.lock()
        notifications.append(notification)
        lock.unlock()
        onDelivery?.fulfill()
    }
}
