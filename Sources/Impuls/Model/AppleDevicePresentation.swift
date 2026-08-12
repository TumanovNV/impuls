import Foundation

/// Human-facing vocabulary for the Apple Device Battery Center.
///
/// Hardware and transport types deliberately carry no presentation strings.
/// Keeping the translation here gives the panel, Settings and VoiceOver one
/// answer for every state, without letting an NSError or a raw provider value
/// escape into the interface.
enum AppleDevicePresentation {
    static func symbol(for kind: AppleDeviceKind) -> String {
        switch kind {
        case .mac: return "laptopcomputer"
        case .iPhone: return "iphone"
        case .iPad: return "ipad"
        case .airPods, .airPodsPro: return "airpodspro"
        case .airPodsMax: return "airpodsmax"
        case .magicMouse: return "computermouse.fill"
        case .magicKeyboard: return "keyboard.fill"
        case .magicTrackpad: return "rectangle.and.hand.point.up.left.fill"
        case .appleWatch: return "applewatch"
        case .applePencil: return "applepencil"
        case .visionPro: return "visionpro"
        case .airTag: return "airtag.fill"
        case .siriRemote: return "appletvremote.gen1.fill"
        case .unknown: return "battery.50percent"
        }
    }

    static func kindTitle(_ kind: AppleDeviceKind) -> String {
        switch kind {
        case .mac: return localized("Mac")
        case .iPhone: return localized("iPhone")
        case .iPad: return localized("iPad")
        case .airPods: return localized("AirPods")
        case .airPodsPro: return localized("AirPods Pro")
        case .airPodsMax: return localized("AirPods Max")
        case .magicMouse: return localized("Magic Mouse")
        case .magicKeyboard: return localized("Magic Keyboard")
        case .magicTrackpad: return localized("Magic Trackpad")
        case .appleWatch: return localized("Apple Watch")
        case .applePencil: return localized("Apple Pencil")
        case .visionPro: return localized("Apple Vision Pro")
        case .airTag: return localized("AirTag")
        case .siriRemote: return localized("Siri Remote")
        case .unknown: return localized("Apple Device")
        }
    }

    static func componentTitle(_ kind: DeviceBatteryComponentKind) -> String {
        switch kind {
        case .primary: return localized("Battery")
        case .left: return localized("Left")
        case .right: return localized("Right")
        case .chargingCase: return localized("Case")
        case .external: return localized("External")
        case .accessory: return localized("Accessory")
        }
    }

    static func chargingTitle(_ state: DeviceChargingState?) -> String? {
        switch state {
        case .charging: return localized("Charging")
        case .discharging: return localized("On Battery")
        case .charged: return localized("Charged")
        case .notCharging: return localized("Not Charging")
        case .unknown, nil: return nil
        }
    }

    static func statusTitle(_ status: DeviceBatteryStatus?) -> String? {
        switch status {
        case .ok: return localized("Battery OK")
        case .low: return localized("Low Battery")
        case .critical: return localized("Critical Battery")
        case nil: return nil
        }
    }

    static func connectionTitle(_ connection: DeviceConnectionKind) -> String {
        switch connection {
        case .builtIn: return localized("Built In")
        case .bluetooth: return localized("Bluetooth")
        case .usb: return localized("USB")
        case .wifi: return localized("Wi-Fi")
        case .unknown: return localized("Unknown Connection")
        }
    }

    static func readingTitle(_ component: DeviceBatteryComponent) -> String {
        if let percentage = component.percentage { return "\(percentage)%" }
        if let status = statusTitle(component.status) { return status }
        if let charging = chargingTitle(component.chargingState) { return charging }
        return localized("No Current Reading")
    }

    static func freshness(
        for snapshot: AppleDeviceSnapshot,
        now: Date = Date(),
        staleAfter: TimeInterval = DeviceSnapshotMerger.defaultStaleInterval
    ) -> DeviceFreshness {
        DeviceSnapshotMerger.freshness(for: snapshot, now: now, staleAfter: staleAfter)
    }

    static func freshness(
        for component: DeviceBatteryComponent,
        availability: DeviceAvailability,
        fallbackDate: Date?,
        now: Date = Date(),
        staleAfter: TimeInterval = DeviceSnapshotMerger.defaultStaleInterval
    ) -> DeviceFreshness {
        guard availability != .unavailable else { return .unavailable }
        guard let updated = component.lastUpdated ?? fallbackDate else { return .unavailable }
        return now.timeIntervalSince(updated) <= staleAfter ? .fresh : .stale
    }

    static func ageTitle(
        since date: Date?,
        freshness: DeviceFreshness,
        now: Date = Date(),
        locale: Locale = .current,
        abbreviated: Bool = false
    ) -> String {
        guard let date, freshness != .unavailable else {
            return localized("No Current Reading")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = abbreviated ? .abbreviated : .full
        let relative = formatter.localizedString(fromTimeInterval: min(0, date.timeIntervalSince(now)))
        switch freshness {
        case .fresh: return localized("Updated %@", relative)
        case .stale: return localized("Stale · %@", relative)
        case .unavailable: return localized("No Current Reading")
        }
    }

    static func isBeta(_ kind: AppleDeviceKind) -> Bool {
        kind == .iPhone || kind == .iPad
    }

    static func accessibilityValue(
        for snapshot: AppleDeviceSnapshot,
        now: Date = Date()
    ) -> String {
        var values = snapshot.components.map { component in
            var parts = [componentTitle(component.kind), readingTitle(component)]
            if let charging = chargingTitle(component.chargingState),
               charging != readingTitle(component) {
                parts.append(charging)
            }
            let componentFreshness = freshness(
                for: component,
                availability: snapshot.availability,
                fallbackDate: snapshot.lastUpdated,
                now: now
            )
            parts.append(
                ageTitle(
                    since: component.lastUpdated ?? snapshot.lastUpdated,
                    freshness: componentFreshness,
                    now: now
                )
            )
            return parts.joined(separator: ", ")
        }
        if isBeta(snapshot.kind) { values.insert(localized("Beta"), at: 0) }
        values.append(connectionTitle(snapshot.connection))
        return values.joined(separator: "; ")
    }
}
