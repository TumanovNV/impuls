import Foundation
import UserNotifications

enum LowBatteryNotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

struct LowBatteryNotification: Equatable, Sendable {
    let title: String
    let body: String
    let devicePreferenceKey: String
}

protocol LowBatteryNotificationDelivering: AnyObject {
    var onNotificationOpened: (@MainActor @Sendable (String?) -> Void)? { get set }
    func authorizationStatus() async -> LowBatteryNotificationAuthorization
    func requestAuthorization() async -> LowBatteryNotificationAuthorization
    func deliver(_ notification: LowBatteryNotification) async throws
}

final class UserNotificationLowBatteryDelivery: NSObject, LowBatteryNotificationDelivering, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let center: UNUserNotificationCenter
    private let lock = NSLock()
    private var openHandler: (@MainActor @Sendable (String?) -> Void)?

    var onNotificationOpened: (@MainActor @Sendable (String?) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return openHandler
        }
        set {
            lock.lock()
            openHandler = newValue
            lock.unlock()
        }
    }

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func authorizationStatus() async -> LowBatteryNotificationAuthorization {
        let settings = await center.notificationSettings()
        return Self.map(settings.authorizationStatus)
    }

    func requestAuthorization() async -> LowBatteryNotificationAuthorization {
        let current = await authorizationStatus()
        guard current == .notDetermined else { return current }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return await authorizationStatus()
        }
        return await authorizationStatus()
    }

    func deliver(_ notification: LowBatteryNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.userInfo = ["devicePreferenceKey": notification.devicePreferenceKey]
        let request = UNNotificationRequest(
            identifier: "low-battery-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let key = response.notification.request.content.userInfo["devicePreferenceKey"] as? String
        let handler = onNotificationOpened
        Task { @MainActor in handler?(key) }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private static func map(_ status: UNAuthorizationStatus) -> LowBatteryNotificationAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default: return .denied
        }
    }
}

/// Permission, policy and delivery orchestration. The engine stays synchronous
/// and deterministic; this object is the only layer that crosses into macOS.
@MainActor
final class LowBatteryAlertService: ObservableObject {
    @Published private(set) var authorization: LowBatteryNotificationAuthorization = .notDetermined
    @Published private(set) var testNotificationInFlight = false
    /// Low-battery deliveries currently crossing the Notification Center
    /// boundary. Observable so a caller — a diagnostics view, or a test —
    /// can wait for `confirmDelivery`/`cancelDelivery` to actually land
    /// instead of guessing how many actor hops that takes.
    @Published private(set) var pendingDeliveryCount = 0

    private let engine: LowBatteryAlertEngine
    private let delivery: LowBatteryNotificationDelivering
    private var isEnabled = false
    private var latestEvaluation: (snapshots: [AppleDeviceSnapshot], now: Date, staleAfter: TimeInterval)?
    private var permissionTask: Task<Void, Never>?
    private var didDeliverQATrigger = false

    var onOpenPowerCenter: (() -> Void)?

    init(engine: LowBatteryAlertEngine, delivery: LowBatteryNotificationDelivering) {
        self.engine = engine
        self.delivery = delivery
        delivery.onNotificationOpened = { [weak self] _ in
            self?.onOpenPowerCenter?()
        }
    }

    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            engine: LowBatteryAlertEngine(store: UserDefaultsLowBatteryAlertStateStore(defaults: defaults)),
            delivery: UserNotificationLowBatteryDelivery()
        )
    }

    deinit {
        permissionTask?.cancel()
    }

    func setEnabled(_ enabled: Bool, requestAuthorization: Bool) {
        isEnabled = enabled
        guard enabled else { return }
        refreshAuthorization(requestIfNeeded: requestAuthorization)
    }

    /// Explicit Settings action. Restoring a persisted preference continues to
    /// call `setEnabled(... requestAuthorization: false)` and therefore never
    /// produces a TCC prompt by itself.
    func requestAuthorization() {
        refreshAuthorization(requestIfNeeded: true)
    }

    func refreshAuthorization(requestIfNeeded: Bool = false) {
        permissionTask?.cancel()
        permissionTask = Task { [weak self] in
            guard let self else { return }
            var status = await delivery.authorizationStatus()
            guard !Task.isCancelled else { return }
            if requestIfNeeded, status == .notDetermined {
                status = await delivery.requestAuthorization()
                guard !Task.isCancelled else { return }
            }
            authorization = status
            evaluateLatestIfPossible()
            deliverQATriggerIfRequested()
        }
    }

    /// Sends a deliberately synthetic notification from an explicit Settings
    /// action. It never calls the alert engine, never fabricates a percentage,
    /// and therefore cannot arm, re-arm or persist low-battery policy state.
    func sendTestNotification() {
        guard authorization == .authorized, !testNotificationInFlight else { return }
        testNotificationInFlight = true
        let notification = Self.testNotification()
        Task { [weak self, delivery] in
            do {
                try await delivery.deliver(notification)
                DevicePowerLog.note("notification test accepted by Notification Center")
            } catch {
                DevicePowerLog.note("notification test delivery failed")
            }
            guard let self else { return }
            testNotificationInFlight = false
        }
    }

    func evaluate(
        _ snapshots: [AppleDeviceSnapshot],
        now: Date,
        staleAfter: TimeInterval
    ) {
        latestEvaluation = (snapshots, now, staleAfter)
        evaluateLatestIfPossible()
    }

    func backgroundPollingInterval(
        for snapshots: [AppleDeviceSnapshot],
        now: Date,
        staleAfter: TimeInterval
    ) -> TimeInterval? {
        guard isEnabled else { return nil }
        let hasLowUnchargedReading = snapshots.contains { snapshot in
            guard !snapshot.identity.isLocalMac, snapshot.availability == .connected else { return false }
            return snapshot.components.contains { component in
                guard let percentage = component.percentage, percentage <= 25,
                      component.chargingState != .charging,
                      let updated = component.lastUpdated ?? snapshot.lastUpdated else { return false }
                return now.timeIntervalSince(updated) <= staleAfter
            }
        }
        return hasLowUnchargedReading ? 60 : 5 * 60
    }

    private func evaluateLatestIfPossible() {
        guard isEnabled, authorization == .authorized, let latestEvaluation else { return }
        let alerts = engine.evaluate(
            latestEvaluation.snapshots,
            now: latestEvaluation.now,
            staleAfter: latestEvaluation.staleAfter
        )
        for alert in alerts {
            let notification = Self.notification(for: alert)
            let evaluationNow = latestEvaluation.now
            pendingDeliveryCount += 1
            Task { [weak self, delivery] in
                // Runs on this MainActor-isolated task before it yields the
                // executor again, immediately after `confirmDelivery` /
                // `cancelDelivery` below — so anyone observing the count
                // reach zero also observes the engine's pending state as
                // already settled, not merely the delivery attempt as made.
                defer { self?.pendingDeliveryCount -= 1 }
                do {
                    try await delivery.deliver(notification)
                    guard let self else { return }
                    // The engine keeps this threshold pending while the async
                    // Notification Center boundary is in flight. Only an
                    // accepted request becomes durable fired state.
                    engine.confirmDelivery(alert.deliveryID, now: evaluationNow)
                    DevicePowerLog.note("low-battery notification delivered for \(alert.deviceKind.rawValue) at \(alert.severity.rawValue)")
                } catch {
                    guard let self else { return }
                    // A transient delivery failure must be retryable on the
                    // next ordinary provider evaluation. No extra retry timer
                    // or higher polling cadence is introduced here.
                    engine.cancelDelivery(alert.deliveryID)
                    DevicePowerLog.note("low-battery notification delivery failed for \(alert.deviceKind.rawValue) at \(alert.severity.rawValue)")
                }
            }
        }
    }

    /// Release QA can prove the Notification Center boundary without claiming
    /// a fabricated device percentage. The hook requires an explicit process
    /// environment and labels itself as a test; normal launches never enter it.
    private func deliverQATriggerIfRequested() {
        guard isEnabled,
              authorization == .authorized,
              !didDeliverQATrigger,
              ProcessInfo.processInfo.environment["IMPULS_LOW_BATTERY_NOTIFICATION_QA"] == "1" else { return }
        didDeliverQATrigger = true
        sendTestNotification()
    }

    private static func testNotification() -> LowBatteryNotification {
        LowBatteryNotification(
            title: localized("Impuls Notification QA"),
            body: localized("Test notification only. No device battery reading was used."),
            devicePreferenceKey: "qa"
        )
    }

    static func notification(for alert: LowBatteryAlert) -> LowBatteryNotification {
        let title = alert.severity == .critical
            ? localized("Critical Battery")
            : localized("Low Battery")
        let readings = alert.components.map { component in
            localized("%@: %d%%", AppleDevicePresentation.componentTitle(component.kind), component.percentage)
        }.joined(separator: ", ")
        let readingLine: String
        if alert.components.count == 1, alert.components.first?.kind == .primary,
           let percentage = alert.components.first?.percentage {
            readingLine = localized("%@ — %d%% remaining.", alert.displayName, percentage)
        } else {
            readingLine = localized("%@ — %@.", alert.displayName, readings)
        }
        let guidance = alert.severity == .critical
            ? localized("This device may turn off soon.")
            : localized("Consider charging this device.")
        return LowBatteryNotification(
            title: title,
            body: "\(readingLine)\n\(guidance)",
            devicePreferenceKey: alert.devicePreferenceKey
        )
    }
}
