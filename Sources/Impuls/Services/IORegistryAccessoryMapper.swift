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
    /// Apple's Bluetooth SIG company identifier. Confirmed on real hardware
    /// (Magic Keyboard, Magic Mouse, Magic Trackpad, macOS Tahoe 26, 2026-08):
    /// every Bluetooth accessory publishes `VendorID = 76` on this service,
    /// which is `0x004C`, not the USB-IF identifier below.
    static let appleBluetoothVendorID = 0x004C

    /// Apple's USB-IF vendor identifier. A wired accessory reaching this same
    /// service class (a USB Magic Keyboard, for instance) publishes this one
    /// instead. Used instead of matching the word "Apple" in a product string,
    /// which any third-party accessory is free to put there.
    static let appleUSBVendorID = 0x05AC

    /// Both namespaces this service class has been observed to use. Bluetooth
    /// and USB Apple accessories share the property schema but not the vendor
    /// identifier space, so both are accepted rather than picking one.
    static let appleVendorIDs: Set<Int> = [appleBluetoothVendorID, appleUSBVendorID]

    /// The service class carrying accessory battery state. Public IOKit reaches
    /// it; the property names on it are the undocumented part.
    static let serviceClass = "AppleDeviceManagementHIDEventService"

    enum Key {
        static let batteryPercent = "BatteryPercent"
        static let batteryPercentLeft = "BatteryPercentLeft"
        static let batteryPercentRight = "BatteryPercentRight"
        static let batteryPercentCase = "BatteryPercentCase"
        static let product = "Product"
        static let productID = "ProductID"
        static let vendorID = "VendorID"
        static let manufacturer = "Manufacturer"
        static let transport = "Transport"
        static let deviceAddress = "DeviceAddress"
        static let serialNumber = "SerialNumber"
        static let builtIn = "Built-In"
    }

    /// Transports that mean "this is part of the Mac", not "this is an
    /// accessory". A MacBook's own keyboard and trackpad publish through the
    /// same service family, and listing the built-in trackpad as a battery
    /// device would be both wrong and confusing.
    ///
    /// A second guard rather than the only one: internal devices do not publish
    /// a battery percentage either, so they are already excluded by the time
    /// this is consulted. `Key.builtIn` is checked first when the service
    /// publishes it, because it is Apple's own explicit statement rather than a
    /// transport string this code has to interpret.
    private static let internalTransports: Set<String> = ["spi", "spu", "fifo", "i2c", "bus", "internal"]

    static func device(
        from properties: [String: Any],
        now: Date,
        resolver: DeviceIdentityResolver = .shared
    ) -> AppleDeviceSnapshot? {
        guard isAppleAccessory(properties) else { return nil }
        guard !isBuiltIn(properties) else { return nil }

        let resolvedKind = kind(from: properties)

        // Identity comes from hardware, or the device is not listed at all.
        //
        // The registry entry ID would always be available and is tempting, but
        // it is assigned per session: the same mouse gets a different one after
        // a reconnect or a reboot, so it cannot carry a per-device preference
        // and cannot recognise a device that comes back. It is not a user
        // identifier and is not used as one.
        guard let rawIdentifier = string(properties[Key.deviceAddress])
                ?? string(properties[Key.serialNumber]),
              let identity = resolver.identity(forRawIdentifier: rawIdentifier, kind: resolvedKind)
        else { return nil }

        let components = components(from: properties, now: now)
        // No reading means no device. An accessory that exists but tells us
        // nothing is not worth a card that says nothing.
        guard !components.isEmpty else { return nil }

        let productName = string(properties[Key.product])
        // The product name this Mac's registry publishes may be an empty
        // string rather than absent — confirmed on real hardware — in which
        // case `productName` is already `nil` and the fallback below is what a
        // person actually sees. A kind resolved from the product ID table is
        // real evidence, not a guess, so it earns a real name instead of the
        // generic one.
        let fallbackDisplayName = resolvedKind == .unknown
            ? "Apple device"
            : AppleDevicePresentation.kindTitle(resolvedKind)
        return AppleDeviceSnapshot(
            identity: identity,
            kind: resolvedKind,
            displayName: AppleDeviceNormalizer.displayName(productName, fallback: fallbackDisplayName),
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
    ///
    /// Some macOS releases publish `Product` as an empty string on this service
    /// for Bluetooth Magic accessories rather than omitting it — confirmed on
    /// real hardware. When that happens, the Bluetooth product ID is used
    /// instead: it is a stable field this project has cross-referenced against
    /// `system_profiler`'s own name for the same physical devices, not a guess.
    /// It is consulted only in the Bluetooth vendor namespace, because the same
    /// numeric ID means something else in the USB one.
    static func kind(from properties: [String: Any]) -> AppleDeviceKind {
        let named = AppleAccessoryNaming.kind(fromProductName: string(properties[Key.product]))
        guard named == .unknown else { return named }
        guard integer(properties[Key.vendorID]) == appleBluetoothVendorID else { return .unknown }
        return AppleAccessoryNaming.kind(fromBluetoothProductID: integer(properties[Key.productID]))
    }

    static func isAppleAccessory(_ properties: [String: Any]) -> Bool {
        if let vendor = integer(properties[Key.vendorID]) { return appleVendorIDs.contains(vendor) }
        // Only when the numeric marker is absent. Some services publish a
        // manufacturer string and no vendor identifier at all.
        guard let manufacturer = string(properties[Key.manufacturer])?.lowercased() else { return false }
        return manufacturer.contains("apple")
    }

    static func isBuiltIn(_ properties: [String: Any]) -> Bool {
        if let builtIn = bool(properties[Key.builtIn]) { return builtIn }
        guard let transport = string(properties[Key.transport])?.lowercased() else { return false }
        return internalTransports.contains(transport)
    }

    // MARK: - Defensive value reading

    /// IOKit hands back `CFNumber` of whatever width the driver chose, and a
    /// future release may choose another. Anything that is not a number — a
    /// string, a boolean, a dictionary, a value from a key that was reused for
    /// something else — reads as absent rather than as a battery level.
    static func integer(_ value: Any?) -> Int? {
        RegistryNumber.integer(value)
    }

    /// `Built-In` arrives as a genuine `CFBoolean` — confirmed on real
    /// hardware, where it read `false` for every external accessory. Checked
    /// the same defensive way `RegistryNumber` checks for one: plain `as?
    /// Bool` also accepts an `Int8`-boxed `NSNumber`, which would make a
    /// battery-percentage-shaped value of `1` misread as `true`. Anything that
    /// is not actually `CFBooleanGetTypeID()` reads as absent, so the
    /// transport-string fallback in `isBuiltIn` still applies.
    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
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
