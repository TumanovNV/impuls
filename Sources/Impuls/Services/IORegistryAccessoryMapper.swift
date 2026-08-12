import Foundation

/// Turns one IORegistry property dictionary into a device, or into nothing.
///
/// Split out from the registry walk so that every decision below can be tested
/// against a fixture instead of against whatever happens to be plugged into the
/// machine running the tests. The rules are deliberately strict: this reads
/// properties that Apple documents nowhere, so the parser has to assume the
/// next macOS release renames, retypes or removes any of them.
///
/// Nothing here is a promise. A missing key is a normal Tuesday, not an error,
/// and the only outcome of an unrecognised node is `nil`.
enum IORegistryAccessoryMapper {
    /// Apple's USB/Bluetooth vendor identifier. Used instead of matching the
    /// word "Apple" in a product string, which any third-party accessory is
    /// free to put there.
    static let appleVendorID = 0x05AC

    /// The service class carrying accessory battery state. Public IOKit reaches
    /// it; the property names on it are the undocumented part.
    static let serviceClass = "AppleDeviceManagementHIDEventService"

    enum Key {
        static let batteryPercent = "BatteryPercent"
        static let batteryPercentLeft = "BatteryPercentLeft"
        static let batteryPercentRight = "BatteryPercentRight"
        static let batteryPercentCase = "BatteryPercentCase"
        static let product = "Product"
        static let vendorID = "VendorID"
        static let manufacturer = "Manufacturer"
        static let transport = "Transport"
        static let deviceAddress = "DeviceAddress"
        static let serialNumber = "SerialNumber"
    }

    /// Transports that mean "this is part of the Mac", not "this is an
    /// accessory". A MacBook's own keyboard and trackpad publish through the
    /// same service family, and listing the built-in trackpad as a battery
    /// device would be both wrong and confusing.
    ///
    /// A second guard rather than the only one: internal devices do not publish
    /// a battery percentage either, so they are already excluded by the time
    /// this is consulted.
    private static let internalTransports: Set<String> = ["spi", "spu", "fifo", "i2c", "bus", "internal"]

    static func device(
        from properties: [String: Any],
        now: Date,
        resolver: DeviceIdentityResolver = .shared
    ) -> AppleDeviceSnapshot? {
        guard isAppleAccessory(properties) else { return nil }
        guard !isBuiltIn(properties) else { return nil }

        // Identity comes from hardware, or the device is not listed at all.
        //
        // The registry entry ID would always be available and is tempting, but
        // it is assigned per session: the same mouse gets a different one after
        // a reconnect or a reboot, so it cannot carry a per-device preference
        // and cannot recognise a device that comes back. It is not a user
        // identifier and is not used as one.
        guard let rawIdentifier = string(properties[Key.deviceAddress])
                ?? string(properties[Key.serialNumber]),
              let identity = resolver.identity(forRawIdentifier: rawIdentifier, kind: kind(from: properties))
        else { return nil }

        let components = components(from: properties, now: now)
        // No reading means no device. An accessory that exists but tells us
        // nothing is not worth a card that says nothing.
        guard !components.isEmpty else { return nil }

        let productName = string(properties[Key.product])
        return AppleDeviceSnapshot(
            identity: identity,
            kind: kind(from: properties),
            displayName: AppleDeviceNormalizer.displayName(productName, fallback: "Apple device"),
            modelName: productName,
            connection: .bluetooth,
            availability: .connected,
            // Deliberately unknown. macOS does not publish a property here that
            // reliably says an accessory is charging, and a Magic Keyboard on a
            // cable is not evidence — it charges when it feels like it. Guessing
            // is exactly what this module refuses to do.
            externalPower: .unknown,
            components: components,
            lastSeen: now,
            lastUpdated: now,
            source: .ioRegistryAccessory,
            capabilities: AppleDeviceNormalizer.capabilities(for: components)
        )
    }

    /// Left, right and case if the system publishes them; otherwise the single
    /// overall value; otherwise nothing.
    ///
    /// The two are not mixed. When per-component values exist the overall one
    /// is a summary of them, and adding it as a fourth battery would show the
    /// same charge twice.
    static func components(from properties: [String: Any], now: Date) -> [DeviceBatteryComponent] {
        let split = [
            (DeviceBatteryComponentKind.left, Key.batteryPercentLeft),
            (DeviceBatteryComponentKind.right, Key.batteryPercentRight),
            (DeviceBatteryComponentKind.chargingCase, Key.batteryPercentCase),
        ].compactMap { kind, key in
            AppleDeviceNormalizer.component(
                kind: kind,
                percentage: integer(properties[key]),
                lastUpdated: now
            )
        }
        if !split.isEmpty { return split }

        guard let overall = AppleDeviceNormalizer.component(
            kind: .primary,
            percentage: integer(properties[Key.batteryPercent]),
            lastUpdated: now
        ) else { return [] }
        return [overall]
    }

    /// The product name the device reports for itself, matched conservatively.
    ///
    /// This decides which glyph and which wording the panel uses, never whether
    /// a number is believed. An accessory whose name is not recognised is still
    /// a real Apple accessory with a real battery, so it is shown as itself
    /// rather than dropped or guessed into a category.
    static func kind(from properties: [String: Any]) -> AppleDeviceKind {
        AppleAccessoryNaming.kind(fromProductName: string(properties[Key.product]))
    }

    static func isAppleAccessory(_ properties: [String: Any]) -> Bool {
        if let vendor = integer(properties[Key.vendorID]) { return vendor == appleVendorID }
        // Only when the numeric marker is absent. Some services publish a
        // manufacturer string and no vendor identifier at all.
        guard let manufacturer = string(properties[Key.manufacturer])?.lowercased() else { return false }
        return manufacturer.contains("apple")
    }

    static func isBuiltIn(_ properties: [String: Any]) -> Bool {
        guard let transport = string(properties[Key.transport])?.lowercased() else { return false }
        return internalTransports.contains(transport)
    }

    // MARK: - Defensive value reading

    /// IOKit hands back `CFNumber` of whatever width the driver chose, and a
    /// future release may choose another. Anything that is not a number — a
    /// string, a boolean, a dictionary, a value from a key that was reused for
    /// something else — reads as absent rather than as a battery level.
    static func integer(_ value: Any?) -> Int? {
        guard let value else { return nil }
        guard let number = value as? NSNumber else { return nil }
        // `true` bridges to NSNumber 1, and a flag misread as 1% would be a
        // wrong number rather than a missing one.
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let doubleValue = number.doubleValue
        // Range-checked before the conversion, not after: converting a `Double`
        // outside `Int`'s range is a trap, not an overflow, and a driver
        // publishing `Int.max` in a field we did not expect would take the
        // application down rather than be ignored.
        guard doubleValue.isFinite, abs(doubleValue) <= Double(Int32.max) else { return nil }
        return Int(doubleValue.rounded())
    }

    static func string(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let data = value as? Data, let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }
}
