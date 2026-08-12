import Foundation

/// Deduplication, merging, freshness and order — as pure functions.
///
/// One iPhone that is visible over USB and over Wi-Fi is one row. Getting that
/// wrong is not a cosmetic bug: three cards for the same phone, each with a
/// slightly different number, destroys any reason to trust the panel.
///
/// Nothing here touches the main actor or the clock directly, so every rule
/// below is testable by calling it.
enum DeviceSnapshotMerger {
    /// How long a reading stays believable before it is shown with its age.
    ///
    /// Two minutes is chosen against the refresh cadence rather than against
    /// intuition: external devices are polled far more slowly than this Mac, so
    /// anything under a minute would mark ordinary readings stale between two
    /// scheduled reads. It is a default, not a constant of nature — callers
    /// pass their own where a source has different rhythm.
    static let defaultStaleInterval: TimeInterval = 120

    /// Collapses everything the providers reported into the list the panel
    /// shows, in display order.
    static func merge(
        _ updates: [[AppleDeviceSnapshot]],
        now: Date,
        staleAfter: TimeInterval = defaultStaleInterval
    ) -> [AppleDeviceSnapshot] {
        var byIdentity: [AppleDeviceIdentity: AppleDeviceSnapshot] = [:]
        var order: [AppleDeviceIdentity] = []

        for group in updates {
            for snapshot in group {
                if let existing = byIdentity[snapshot.identity] {
                    byIdentity[snapshot.identity] = combine(
                        existing,
                        snapshot,
                        now: now,
                        staleAfter: staleAfter
                    )
                } else {
                    byIdentity[snapshot.identity] = snapshot
                    order.append(snapshot.identity)
                }
            }
        }

        return sorted(order.compactMap { byIdentity[$0] })
    }

    /// Merges two views of the same device.
    ///
    /// The identity is what proves they are the same device. Names are not
    /// evidence: two people in one household own "iPhone", and a Magic Keyboard
    /// borrowed from a desk looks exactly like the one on this one. Merging on
    /// a matching name would silently hide a device, which is worse than
    /// showing two.
    ///
    /// Per field, the more reliable source wins — **unless** its reading has
    /// gone stale while the less reliable one is current. A phone that has been
    /// unplugged still has its last USB reading on file; once that reading is
    /// old, the Wi-Fi one that arrived a moment ago is the better answer even
    /// though its source ranks lower.
    static func combine(
        _ lhs: AppleDeviceSnapshot,
        _ rhs: AppleDeviceSnapshot,
        now: Date,
        staleAfter: TimeInterval = defaultStaleInterval
    ) -> AppleDeviceSnapshot {
        precondition(lhs.identity == rhs.identity, "only snapshots of one device may be combined")

        let primary = preferred(lhs, over: rhs, now: now, staleAfter: staleAfter)
        let secondary = primary == lhs ? rhs : lhs

        var components: [DeviceBatteryComponentKind: DeviceBatteryComponent] = [:]
        for component in secondary.components where component.hasReading {
            components[component.kind] = component
        }
        for component in primary.components where component.hasReading {
            guard let rival = components[component.kind] else {
                components[component.kind] = component
                continue
            }
            components[component.kind] = preferredComponent(
                component,
                fromPrimary: primary,
                over: rival,
                fromSecondary: secondary,
                now: now,
                staleAfter: staleAfter
            )
        }

        return AppleDeviceSnapshot(
            identity: primary.identity,
            kind: primary.kind == .unknown ? secondary.kind : primary.kind,
            displayName: primary.displayName.isEmpty ? secondary.displayName : primary.displayName,
            modelName: primary.modelName ?? secondary.modelName,
            connection: primary.connection,
            // Reachable through any transport means reachable. A provider that
            // has lost the device must not overrule one that still has it.
            availability: [primary.availability, secondary.availability].min(by: availabilityIsBetter) ?? primary.availability,
            externalPower: primary.externalPower == .unknown ? secondary.externalPower : primary.externalPower,
            components: Array(components.values),
            lastSeen: latest(primary.lastSeen, secondary.lastSeen),
            lastUpdated: latest(primary.lastUpdated, secondary.lastUpdated),
            source: primary.source,
            // The union, not the intersection: a source that is momentarily
            // silent has not stopped being able to report what it reports, and
            // erasing the capability would make the pane redraw the device as a
            // different kind of thing every time a read is missed.
            capabilities: primary.capabilities.union(secondary.capabilities)
        )
    }

    static func freshness(
        for snapshot: AppleDeviceSnapshot,
        now: Date,
        staleAfter: TimeInterval = defaultStaleInterval
    ) -> DeviceFreshness {
        guard snapshot.availability != .unavailable else { return .unavailable }
        guard let lastUpdated = snapshot.lastUpdated else { return .unavailable }
        return now.timeIntervalSince(lastUpdated) <= staleAfter ? .fresh : .stale
    }

    /// This Mac first, then whatever is connected, then what was here recently.
    ///
    /// Inside a group the order is the name, never the charge. A list that
    /// reorders itself because a mouse dropped a percent is a list nobody can
    /// click on.
    static func sorted(_ devices: [AppleDeviceSnapshot]) -> [AppleDeviceSnapshot] {
        devices.sorted { lhs, rhs in
            if lhs.identity.isLocalMac != rhs.identity.isLocalMac { return lhs.identity.isLocalMac }
            if lhs.availability != rhs.availability {
                return availabilityIsBetter(lhs.availability, rhs.availability)
            }
            let names = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if names != .orderedSame { return names == .orderedAscending }
            return lhs.identity.localPreferenceKey < rhs.identity.localPreferenceKey
        }
    }

    // MARK: - Private

    private static func preferred(
        _ lhs: AppleDeviceSnapshot,
        over rhs: AppleDeviceSnapshot,
        now: Date,
        staleAfter: TimeInterval
    ) -> AppleDeviceSnapshot {
        let lhsFresh = freshness(for: lhs, now: now, staleAfter: staleAfter) == .fresh
        let rhsFresh = freshness(for: rhs, now: now, staleAfter: staleAfter) == .fresh
        if lhsFresh != rhsFresh { return lhsFresh ? lhs : rhs }
        if lhs.source.priority != rhs.source.priority {
            return lhs.source.priority > rhs.source.priority ? lhs : rhs
        }
        switch (lhs.lastUpdated, rhs.lastUpdated) {
        case (let left?, let right?): return left >= right ? lhs : rhs
        case (nil, .some): return rhs
        default: return lhs
        }
    }

    private static func preferredComponent(
        _ component: DeviceBatteryComponent,
        fromPrimary primary: AppleDeviceSnapshot,
        over rival: DeviceBatteryComponent,
        fromSecondary secondary: AppleDeviceSnapshot,
        now: Date,
        staleAfter: TimeInterval
    ) -> DeviceBatteryComponent {
        let componentDate = component.lastUpdated ?? primary.lastUpdated
        let rivalDate = rival.lastUpdated ?? secondary.lastUpdated
        let componentFresh = componentDate.map { now.timeIntervalSince($0) <= staleAfter } ?? false
        let rivalFresh = rivalDate.map { now.timeIntervalSince($0) <= staleAfter } ?? false
        if componentFresh != rivalFresh { return componentFresh ? component : rival }
        if primary.source.priority != secondary.source.priority {
            return primary.source.priority > secondary.source.priority ? component : rival
        }
        switch (componentDate, rivalDate) {
        case (let left?, let right?): return left >= right ? component : rival
        case (nil, .some): return rival
        default: return component
        }
    }

    private static func availabilityIsBetter(_ lhs: DeviceAvailability, _ rhs: DeviceAvailability) -> Bool {
        rank(lhs) < rank(rhs)
    }

    private static func rank(_ availability: DeviceAvailability) -> Int {
        switch availability {
        case .connected: return 0
        case .recentlyDisconnected: return 1
        case .unavailable: return 2
        }
    }

    private static func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (let left?, let right?): return max(left, right)
        case (let left?, nil): return left
        case (nil, let right?): return right
        case (nil, nil): return nil
        }
    }
}
