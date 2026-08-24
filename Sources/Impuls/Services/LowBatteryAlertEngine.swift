import Foundation

enum LowBatteryAlertSeverity: String, Equatable, Sendable {
    case warning
    case critical
}

struct LowBatteryAlertComponent: Equatable, Sendable {
    let kind: DeviceBatteryComponentKind
    let percentage: Int
}

/// A delivery request contains only presentation data, an in-process delivery
/// token and the local opaque key. The token never leaves Impuls; the key is
/// enough to route a click without putting a raw hardware identifier into
/// Notification Center.
struct LowBatteryAlert: Equatable, Sendable {
    let deliveryID: UUID
    let devicePreferenceKey: String
    let deviceKind: AppleDeviceKind
    let displayName: String
    let severity: LowBatteryAlertSeverity
    let components: [LowBatteryAlertComponent]
}

protocol LowBatteryAlertStateStoring: AnyObject {
    func load() -> Data?
    func save(_ data: Data)
}

final class UserDefaultsLowBatteryAlertStateStore: LowBatteryAlertStateStoring {
    static let storageKey = "appleDevices.lowBatteryAlerts.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Data? {
        defaults.data(forKey: Self.storageKey)
    }

    func save(_ data: Data) {
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// Deterministic low-battery policy for every external device provider.
///
/// It deliberately knows nothing about transports or hardware. Stable opaque
/// identities and normalized component readings are the complete input, which
/// means a future provider receives the same alert semantics automatically.
///
/// A threshold has two states: pending in this process, and confirmed after
/// Notification Center accepts the delivery. Pending state prevents duplicate
/// async sends but is never persisted. If delivery fails, cancelling the token
/// re-arms that same low reading for a later normal evaluation instead of
/// silently suppressing it until the battery rises above the re-arm threshold.
final class LowBatteryAlertEngine {
    struct Policy: Equatable, Sendable {
        let warningThreshold: Int
        let criticalThreshold: Int
        let warningRearmThreshold: Int
        let criticalRearmThreshold: Int

        static let standard = Policy(
            warningThreshold: 20,
            criticalThreshold: 10,
            warningRearmThreshold: 25,
            criticalRearmThreshold: 15
        )
    }

    private struct ComponentKey: Hashable {
        let device: String
        let component: DeviceBatteryComponentKind
    }

    private struct Candidate {
        let key: ComponentKey
        let component: LowBatteryAlertComponent
    }

    private struct PendingState {
        var warningDeliveryID: UUID?
        var criticalDeliveryID: UUID?

        var isEmpty: Bool {
            warningDeliveryID == nil && criticalDeliveryID == nil
        }
    }

    private struct PersistedDocument: Codable {
        var records: [PersistedRecord]
    }

    private struct PersistedRecord: Codable {
        let device: String
        let component: String
        var warningFired: Bool
        var criticalFired: Bool
        var lastSeen: Date
    }

    static let maximumRememberedComponents = 600
    static let retentionInterval: TimeInterval = 180 * 24 * 60 * 60
    static let maximumPersistedBytes = 512 * 1_024

    let policy: Policy
    private let store: LowBatteryAlertStateStoring
    private var records: [ComponentKey: PersistedRecord]
    /// In-flight Notification Center work. Deliberately process-local: a crash
    /// or force-quit before confirmation must retry rather than persist a false
    /// claim that the user was warned.
    private var pending: [ComponentKey: PendingState] = [:]

    init(
        store: LowBatteryAlertStateStoring,
        policy: Policy = .standard,
        now: Date = Date()
    ) {
        self.store = store
        self.policy = policy
        let stored = store.load()
        records = Self.loadRecords(from: stored, now: now)
        // Rewrite an existing document through the bounded decoder once at
        // startup, so expired or excessive records leave disk as well as RAM.
        if stored != nil { persist() }
    }

    func evaluate(
        _ snapshots: [AppleDeviceSnapshot],
        now: Date,
        staleAfter: TimeInterval = DeviceSnapshotMerger.defaultStaleInterval
    ) -> [LowBatteryAlert] {
        var alerts: [LowBatteryAlert] = []
        var changed = false

        for snapshot in snapshots where !snapshot.identity.isLocalMac && snapshot.availability == .connected {
            var warningCandidates: [Candidate] = []
            var criticalCandidates: [Candidate] = []
            let deviceKey = snapshot.identity.localPreferenceKey

            for component in snapshot.components {
                guard let percentage = component.percentage,
                      componentIsFresh(component, in: snapshot, now: now, staleAfter: staleAfter) else { continue }

                let key = ComponentKey(device: deviceKey, component: component.kind)
                let hadRecord = records[key] != nil
                var record = records[key] ?? PersistedRecord(
                    device: deviceKey,
                    component: component.kind.rawValue,
                    warningFired: false,
                    criticalFired: false,
                    lastSeen: now
                )
                let previousWarning = record.warningFired
                let previousCritical = record.criticalFired
                let previousLastSeen = record.lastSeen
                var pendingState = pending[key] ?? PendingState()

                // Cleanup timestamps need day-scale precision. Rewriting
                // UserDefaults on every one-minute poll would turn a bounded
                // state machine into needless disk churn.
                if hadRecord, now.timeIntervalSince(record.lastSeen) >= 24 * 60 * 60 {
                    record.lastSeen = now
                }

                // Re-arm applies to both confirmed and in-flight state. If a
                // component recovers while Notification Center work is still
                // pending, a late confirmation for that old cycle becomes a
                // no-op and a future drop can alert normally.
                if percentage > policy.warningRearmThreshold {
                    record.warningFired = false
                    pendingState.warningDeliveryID = nil
                }
                if percentage > policy.criticalRearmThreshold {
                    record.criticalFired = false
                    pendingState.criticalDeliveryID = nil
                }

                let warningAlreadyHandled = record.warningFired || pendingState.warningDeliveryID != nil
                let criticalAlreadyHandled = record.criticalFired || pendingState.criticalDeliveryID != nil

                if component.chargingState != .charging {
                    if percentage <= policy.criticalThreshold, !criticalAlreadyHandled {
                        criticalCandidates.append(.init(
                            key: key,
                            component: .init(kind: component.kind, percentage: percentage)
                        ))
                    } else if percentage <= policy.warningThreshold, !warningAlreadyHandled {
                        warningCandidates.append(.init(
                            key: key,
                            component: .init(kind: component.kind, percentage: percentage)
                        ))
                    }
                }

                if record.warningFired || record.criticalFired {
                    records[key] = record
                    if !hadRecord
                        || record.warningFired != previousWarning
                        || record.criticalFired != previousCritical
                        || record.lastSeen != previousLastSeen {
                        changed = true
                    }
                } else if records.removeValue(forKey: key) != nil {
                    // Fully re-armed confirmed state carries no information.
                    changed = true
                }

                if pendingState.isEmpty {
                    pending.removeValue(forKey: key)
                } else {
                    pending[key] = pendingState
                }
            }

            if !criticalCandidates.isEmpty {
                let deliveryID = UUID()
                // A critical notification subsumes lower-priority warnings from
                // the same device/cycle. Those warning candidates become
                // pending under the same delivery token and are committed only
                // if the critical notification is accepted.
                for candidate in criticalCandidates {
                    var state = pending[candidate.key] ?? PendingState()
                    state.criticalDeliveryID = deliveryID
                    if records[candidate.key]?.warningFired != true,
                       state.warningDeliveryID == nil {
                        state.warningDeliveryID = deliveryID
                    }
                    pending[candidate.key] = state
                }
                for candidate in warningCandidates {
                    var state = pending[candidate.key] ?? PendingState()
                    state.warningDeliveryID = deliveryID
                    pending[candidate.key] = state
                }
                alerts.append(LowBatteryAlert(
                    deliveryID: deliveryID,
                    devicePreferenceKey: deviceKey,
                    deviceKind: snapshot.kind,
                    displayName: snapshot.displayName,
                    severity: .critical,
                    components: criticalCandidates.map(\.component).sorted(by: componentOrder)
                ))
            } else if !warningCandidates.isEmpty {
                let deliveryID = UUID()
                for candidate in warningCandidates {
                    var state = pending[candidate.key] ?? PendingState()
                    state.warningDeliveryID = deliveryID
                    pending[candidate.key] = state
                }
                alerts.append(LowBatteryAlert(
                    deliveryID: deliveryID,
                    devicePreferenceKey: deviceKey,
                    deviceKind: snapshot.kind,
                    displayName: snapshot.displayName,
                    severity: .warning,
                    components: warningCandidates.map(\.component).sorted(by: componentOrder)
                ))
            }
        }

        if cleanup(now: now) { changed = true }
        if changed { persist() }
        return alerts
    }

    /// Promotes only state that is still pending under this exact delivery.
    /// This makes late async completion safe after a component has re-armed or
    /// a newer critical cycle has superseded an older warning delivery.
    func confirmDelivery(_ deliveryID: UUID, now: Date) {
        var changed = false
        for key in Array(pending.keys) {
            guard var state = pending[key] else { continue }
            let confirmsCritical = state.criticalDeliveryID == deliveryID
            let confirmsWarning = state.warningDeliveryID == deliveryID
            guard confirmsCritical || confirmsWarning else { continue }

            var record = records[key] ?? PersistedRecord(
                device: key.device,
                component: key.component.rawValue,
                warningFired: false,
                criticalFired: false,
                lastSeen: now
            )
            if confirmsCritical {
                record.criticalFired = true
                record.warningFired = true
                state.criticalDeliveryID = nil
                // A delivered critical alert makes any older warning delivery
                // for this component redundant as well.
                state.warningDeliveryID = nil
            } else if confirmsWarning {
                record.warningFired = true
                state.warningDeliveryID = nil
            }
            record.lastSeen = now
            records[key] = record
            if state.isEmpty {
                pending.removeValue(forKey: key)
            } else {
                pending[key] = state
            }
            changed = true
        }

        if cleanup(now: now) { changed = true }
        if changed { persist() }
    }

    /// Delivery failure must not become durable policy state. Clearing the
    /// matching in-process token lets the next ordinary provider evaluation
    /// retry without adding a new timer or retry loop.
    func cancelDelivery(_ deliveryID: UUID) {
        for key in Array(pending.keys) {
            guard var state = pending[key] else { continue }
            if state.warningDeliveryID == deliveryID { state.warningDeliveryID = nil }
            if state.criticalDeliveryID == deliveryID { state.criticalDeliveryID = nil }
            if state.isEmpty {
                pending.removeValue(forKey: key)
            } else {
                pending[key] = state
            }
        }
    }

    private func componentIsFresh(
        _ component: DeviceBatteryComponent,
        in snapshot: AppleDeviceSnapshot,
        now: Date,
        staleAfter: TimeInterval
    ) -> Bool {
        guard let updated = component.lastUpdated ?? snapshot.lastUpdated else { return false }
        return now.timeIntervalSince(updated) <= staleAfter
    }

    private func cleanup(now: Date) -> Bool {
        let previousCount = records.count
        records = records.filter { now.timeIntervalSince($0.value.lastSeen) <= Self.retentionInterval }
        if records.count > Self.maximumRememberedComponents {
            let retained = records.sorted { $0.value.lastSeen > $1.value.lastSeen }
                .prefix(Self.maximumRememberedComponents)
            records = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
        }
        return records.count != previousCount
    }

    private func persist() {
        let document = PersistedDocument(records: records.values.sorted {
            if $0.device != $1.device { return $0.device < $1.device }
            return $0.component < $1.component
        })
        guard let data = try? JSONEncoder().encode(document) else { return }
        store.save(data)
    }

    private static func loadRecords(from data: Data?, now: Date) -> [ComponentKey: PersistedRecord] {
        guard let data,
              data.count <= maximumPersistedBytes,
              let document = try? JSONDecoder().decode(PersistedDocument.self, from: data) else { return [:] }
        var loaded: [ComponentKey: PersistedRecord] = [:]
        for record in document.records.prefix(10_000) {
            guard validPreferenceKey(record.device),
                  let component = DeviceBatteryComponentKind(rawValue: record.component),
                  record.warningFired || record.criticalFired,
                  now.timeIntervalSince(record.lastSeen) >= -24 * 60 * 60,
                  now.timeIntervalSince(record.lastSeen) <= retentionInterval else { continue }
            loaded[ComponentKey(device: record.device, component: component)] = record
        }
        if loaded.count > maximumRememberedComponents {
            return Dictionary(uniqueKeysWithValues: loaded.sorted { $0.value.lastSeen > $1.value.lastSeen }
                .prefix(maximumRememberedComponents)
                .map { ($0.key, $0.value) })
        }
        return loaded
    }

    private static func validPreferenceKey(_ value: String) -> Bool {
        value.count == 32 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    private func componentOrder(_ lhs: LowBatteryAlertComponent, _ rhs: LowBatteryAlertComponent) -> Bool {
        lhs.kind.displayOrder < rhs.kind.displayOrder
    }
}
