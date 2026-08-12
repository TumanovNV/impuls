import Foundation

/// Reads the Bluetooth section of `system_profiler`'s JSON output.
///
/// Pure, and separate from the process that produces the bytes, so every shape
/// this parser has to survive — a missing battery, a value outside 0…100, a
/// duplicated entry, a schema Apple changes next year — is a fixture rather
/// than a hardware state.
///
/// The JSON keys are stable identifiers (`device_batteryLevelRight`), not
/// localised labels, so nothing here depends on the language the Mac is set to.
/// The plain-text output does depend on it, which is why the JSON form is the
/// one used.
enum SystemProfilerAccessoryParser {
    /// Apple's Bluetooth vendor identifier, as this output spells it.
    static let appleVendorID = 0x004C

    enum Key {
        static let root = "SPBluetoothDataType"
        static let connected = "device_connected"
        static let address = "device_address"
        static let vendorID = "device_vendorID"
        static let productID = "device_productID"
        static let minorType = "device_minorType"
        static let batteryMain = "device_batteryLevelMain"
        static let batteryLeft = "device_batteryLevelLeft"
        static let batteryRight = "device_batteryLevelRight"
        static let batteryCase = "device_batteryLevelCase"
    }

    static func devices(
        fromJSON data: Data,
        now: Date,
        resolver: DeviceIdentityResolver = .shared
    ) throws -> [AppleDeviceSnapshot] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root[Key.root] as? [[String: Any]] else {
            throw MobileDeviceError.malformedResponse("unexpected system_profiler schema")
        }

        var devices: [AppleDeviceIdentity: AppleDeviceSnapshot] = [:]
        var order: [AppleDeviceIdentity] = []

        for section in sections {
            // Only connected devices. A disconnected accessory has no battery
            // value in this output, and inventing one from its last known state
            // is precisely what this module does not do.
            let connected = section[Key.connected] as? [[String: Any]] ?? []
            for entry in connected {
                for (name, value) in entry {
                    guard let properties = value as? [String: Any],
                          let device = device(
                              named: name,
                              properties: properties,
                              now: now,
                              resolver: resolver
                          ) else { continue }
                    // The same accessory can appear under two controllers.
                    // Identity decides, not the name.
                    if devices[device.identity] == nil { order.append(device.identity) }
                    devices[device.identity] = device
                }
            }
        }

        return order.compactMap { devices[$0] }
    }

    static func device(
        named name: String,
        properties: [String: Any],
        now: Date,
        resolver: DeviceIdentityResolver
    ) -> AppleDeviceSnapshot? {
        guard isApple(properties) else { return nil }
        guard let address = string(properties[Key.address]) else { return nil }

        let kind = AppleAccessoryNaming.kind(fromProductName: name)
        guard let identity = resolver.identity(forRawIdentifier: address, kind: kind) else { return nil }

        let components = self.components(from: properties, now: now)
        guard !components.isEmpty else { return nil }

        return AppleDeviceSnapshot(
            identity: identity,
            kind: kind,
            displayName: AppleDeviceNormalizer.displayName(name, fallback: "Apple device"),
            modelName: string(properties[Key.minorType]),
            connection: .bluetooth,
            availability: .connected,
            // Nothing in this output says an accessory is charging. A case that
            // is plugged in does not report it here, so it is not claimed.
            externalPower: .unknown,
            components: components,
            lastSeen: now,
            lastUpdated: now,
            source: .systemProfilerAccessory,
            capabilities: AppleDeviceNormalizer.capabilities(for: components)
        )
    }

    /// Left, right and case when they are published; otherwise the single main
    /// value; otherwise nothing. Never both, for the same reason as the
    /// registry path: the main value is a summary, not a fourth battery.
    static func components(from properties: [String: Any], now: Date) -> [DeviceBatteryComponent] {
        let split = [
            (DeviceBatteryComponentKind.left, Key.batteryLeft),
            (DeviceBatteryComponentKind.right, Key.batteryRight),
            (DeviceBatteryComponentKind.chargingCase, Key.batteryCase),
        ].compactMap { kind, key in
            AppleDeviceNormalizer.component(
                kind: kind,
                percentage: percentage(properties[key]),
                lastUpdated: now
            )
        }
        if !split.isEmpty { return split }

        guard let main = AppleDeviceNormalizer.component(
            kind: .primary,
            percentage: percentage(properties[Key.batteryMain]),
            lastUpdated: now
        ) else { return [] }
        return [main]
    }

    /// Values arrive as strings with a unit — `"89 %"`. Everything that is not
    /// a plain number in range reads as absent.
    static func percentage(_ value: Any?) -> Int? {
        guard let text = string(value) else { return nil }
        let digits = text.prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        return AppleDeviceNormalizer.percentage(fromPercent: number)
    }

    /// `"0x004C"` or `"0x004C (Apple)"`, and nothing else counts as Apple.
    static func isApple(_ properties: [String: Any]) -> Bool {
        guard let raw = string(properties[Key.vendorID]) else { return false }
        let hex = raw.drop { $0 != "x" }.dropFirst().prefix { $0.isHexDigit }
        guard !hex.isEmpty, let value = Int(hex, radix: 16) else { return false }
        return value == appleVendorID
    }

    static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Product names, in one place, because two sources now describe the same
/// accessories and they must agree on what a Magic Mouse is called.
enum AppleAccessoryNaming {
    static func kind(fromProductName name: String?) -> AppleDeviceKind {
        guard let name = name?.lowercased() else { return .unknown }
        if name.contains("airpods max") { return .airPodsMax }
        if name.contains("airpods pro") { return .airPodsPro }
        if name.contains("airpods") { return .airPods }
        if name.contains("magic mouse") { return .magicMouse }
        if name.contains("magic keyboard") { return .magicKeyboard }
        if name.contains("magic trackpad") { return .magicTrackpad }
        return .unknown
    }
}
