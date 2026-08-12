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

    /// Returns only a model name that helps a person identify the device.
    ///
    /// Providers retain the exact public values they receive because they can
    /// be useful while diagnosing hardware support. The interface has a
    /// different job: generic accessory categories and developer-facing mobile
    /// product types are not model names a person should have to interpret.
    static func modelTitle(for snapshot: AppleDeviceSnapshot) -> String? {
        let model = snapshot.modelName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = kindTitle(snapshot.kind)

        switch snapshot.kind {
        case .iPhone:
            guard let model, !model.isEmpty else { return kind }
            return isMobileProductType(model, prefix: "iPhone") ? kind : model
        case .iPad:
            guard let model, !model.isEmpty else { return kind }
            return isMobileProductType(model, prefix: "iPad") ? kind : model
        case .airPods, .airPodsPro, .airPodsMax:
            guard let model, !model.isEmpty else { return nil }
            let generic = ["headphones", "headset", "audio"]
            guard !generic.contains(model.lowercased()),
                  !repeatsDeviceName(model, snapshot: snapshot) else { return nil }
            return model
        case .magicMouse:
            return usefulAccessoryModel(model, generic: "mouse", snapshot: snapshot)
        case .magicKeyboard:
            return usefulAccessoryModel(model, generic: "keyboard", snapshot: snapshot)
        case .magicTrackpad:
            return usefulAccessoryModel(model, generic: "trackpad", snapshot: snapshot)
        default:
            guard let model, !model.isEmpty else { return kind }
            return repeatsDeviceName(model, snapshot: snapshot) ? nil : model
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
        source: DeviceDataSource? = nil,
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
        if source == .systemProfilerAccessory {
            switch freshness {
            case .fresh: return localized("Reported by macOS %@", relative)
            case .stale: return localized("Last reported by macOS %@", relative)
            case .unavailable: return localized("No Current Reading")
            }
        }
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
                    source: snapshot.source,
                    now: now
                )
            )
            return parts.joined(separator: ", ")
        }
        if isBeta(snapshot.kind) { values.insert(localized("Beta"), at: 0) }
        values.append(connectionTitle(snapshot.connection))
        return values.joined(separator: "; ")
    }

    private static func usefulAccessoryModel(
        _ model: String?,
        generic: String,
        snapshot: AppleDeviceSnapshot
    ) -> String? {
        guard let model, !model.isEmpty,
              model.caseInsensitiveCompare(generic) != .orderedSame,
              !repeatsDeviceName(model, snapshot: snapshot) else { return nil }
        return model
    }

    private static func repeatsDeviceName(
        _ model: String,
        snapshot: AppleDeviceSnapshot
    ) -> Bool {
        snapshot.displayName.range(
            of: model,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    private static func isMobileProductType(_ model: String, prefix: String) -> Bool {
        guard model.hasPrefix(prefix) else { return false }
        let parts = model.dropFirst(prefix.count).split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber)
        }
    }
}
