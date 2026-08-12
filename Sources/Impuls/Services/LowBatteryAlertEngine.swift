import Foundation

enum LowBatteryAlertSeverity: String, Equatable, Sendable {
    case warning
    case critical
}

struct LowBatteryAlertComponent: Equatable, Sendable {
    let kind: DeviceBatteryComponentKind
    let percentage: Int
}

/// A delivery request contains only presentation data and the local opaque key.
/// The latter is enough to route a click inside Impuls without putting a raw
/// hardware identifier into Notification Center.
struct LowBatteryAlert: Equatable, Sendable {
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
            var warningCandidates: [LowBatteryAlertComponent] = []
            var criticalCandidates: [LowBatteryAlertComponent] = []
            let deviceKey = snapshot.identity.localPreferenceKey

            for component in snapshot.components {
                guard let percentage = component.percentage,
                      componentIsFresh(component, in: snapshot, now: now, staleAfter: staleAfter) else { continue }

                let key = ComponentKey(device: deviceKey, component: component.kind)
                var record = records[key] ?? PersistedRecord(
                    device: deviceKey,
                    component: component.kind.rawValue,
                    warningFired: false,
                    criticalFired: false,
                    lastSeen: now
                )
                let previous = record
                // Cleanup timestamps need day-scale precision. Rewriting
                // UserDefaults on every one-minute poll would turn a bounded
                // state machine into needless disk churn.
                if now.timeIntervalSince(record.lastSeen) >= 24 * 60 * 60 {
                    record.lastSeen = now
                }

                if percentage > policy.warningRearmThreshold { record.warningFired = false }
                if percentage > policy.criticalRearmThreshold { record.criticalFired = false }

                if component.chargingState != .charging {
                    if percentage <= policy.criticalThreshold, !record.criticalFired {
                        criticalCandidates.append(.init(kind: component.kind, percentage: percentage))
                        // A critical alert subsumes the lower-priority warning.
                        record.criticalFired = true
                        record.warningFired = true
                    } else if percentage <= policy.warningThreshold, !record.warningFired {
                        warningCandidates.append(.init(kind: component.kind, percentage: percentage))
                        record.warningFired = true
                    }
                }

                if record.warningFired || record.criticalFired {
                    records[key] = record
                    if record.warningFired != previous.warningFired
                        || record.criticalFired != previous.criticalFired
                        || record.lastSeen != previous.lastSeen {
                        changed = true
                    }
                } else if records.removeValue(forKey: key) != nil {
                    // Fully re-armed state carries no information. Removing it
                    // keeps persistence proportional to outstanding alerts.
                    changed = true
                }
            }

            if !criticalCandidates.isEmpty {
                // Warning candidates from the same cycle were marked as fired
                // above, but only the actionable critical components are shown.
                alerts.append(LowBatteryAlert(
                    devicePreferenceKey: deviceKey,
                    deviceKind: snapshot.kind,
                    displayName: snapshot.displayName,
                    severity: .critical,
                    components: criticalCandidates.sorted(by: componentOrder)
                ))
            } else if !warningCandidates.isEmpty {
                alerts.append(LowBatteryAlert(
                    devicePreferenceKey: deviceKey,
                    deviceKind: snapshot.kind,
                    displayName: snapshot.displayName,
                    severity: .warning,
                    components: warningCandidates.sorted(by: componentOrder)
                ))
            }
        }

        if cleanup(now: now) { changed = true }
        if changed { persist() }
        return alerts
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
