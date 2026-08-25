import Foundation

/// One accessory battery reading from `pmset -g accps -xml`.
///
/// Deliberately not an `AppleDeviceSnapshot`: this is an **overlay**, never a
/// device. `system_profiler` remains the only source of connected-Bluetooth
/// identity, and a reading that cannot be matched to a device it already found
/// is discarded rather than promoted into a card of its own.
///
/// The accessory UUID that `pmset` also publishes is deliberately **not** a
/// field here. Reading it would make it available to store, log or display, and
/// none of those is wanted: identity stays address-derived from
/// `system_profiler`, so the UUID's stability across a reconnect is not
/// something Impuls has to depend on — or find out.
struct PowerAccessoryReading: Equatable, Sendable {
    let name: String
    let category: String
    let percentage: Int
    let externalPower: DeviceExternalPowerState
    let partIdentifier: String?
}

/// Reads the accessory power sources `pmset` prints, and nothing else.
///
/// **What this surface is.** `/usr/bin/pmset` is a shipped system binary, so
/// Impuls calls no private symbol to reach it. But `-g accps` and `-xml` appear
/// in no `man pmset` page: this is an undocumented compatibility surface, and
/// it is treated as one. Every failure mode — a missing tool, a non-zero exit,
/// a timeout, a schema Apple changes, output that is not a plist at all — must
/// degrade to *no extra battery value*, never to a broken Power module and
/// never to a guess.
///
/// It exists because a measurement forced it, the same way the `system_profiler`
/// source did: a third-party headset that macOS itself shows at 80% publishes
/// no battery field in `SPBluetoothDataType`, and the only non-private route to
/// that number is this tool.
enum PowerAccessoryBatteryParser {
    /// Only what the overlay needs. The accessory identifier is absent from
    /// this list on purpose — see `PowerAccessoryReading`.
    enum Key {
        static let type = "Type"
        static let name = "Name"
        static let category = "Accessory Category"
        static let currentCapacity = "Current Capacity"
        static let maximumCapacity = "Max Capacity"
        static let isCharging = "Is Charging"
        static let isCharged = "Is Charged"
        static let transportType = "Transport Type"
        static let partIdentifier = "Part Identifier"
    }

    static let accessoryType = "Accessory Source"
    static let bluetoothTransport = "Bluetooth"

    /// A person owns a handful of accessories, not hundreds. The bound is here
    /// so a malformed or hostile output cannot turn into unbounded work.
    static let maximumRecords = 32

    /// Splits the multi-document output and keeps the Bluetooth accessories.
    ///
    /// `pmset` prints one `<?xml …>…</plist>` document **per power source**,
    /// so the whole output is not a single plist and `PropertyListSerialization`
    /// rejects it. Documents are separated before parsing, and a document that
    /// fails to parse is skipped rather than failing the batch: one unfamiliar
    /// record must not cost the readings that came out fine.
    static func readings(fromXML data: Data) -> [PowerAccessoryReading] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var readings: [PowerAccessoryReading] = []

        for document in documents(in: text) {
            guard readings.count < maximumRecords else { break }
            guard let parsed = try? PropertyListSerialization.propertyList(
                from: Data(document.utf8),
                options: [],
                format: nil
            ) as? [String: Any] else { continue }
            guard let reading = reading(from: parsed) else { continue }
            readings.append(reading)
        }
        return readings
    }

    /// One record, or nothing.
    ///
    /// Every guard here is a refusal: not an accessory, not Bluetooth, no name,
    /// no usable capacity. A record that cannot answer all of them is not a
    /// battery Impuls is willing to show against somebody's device.
    static func reading(from properties: [String: Any]) -> PowerAccessoryReading? {
        guard string(properties[Key.type]) == accessoryType else { return nil }
        // Transport is part of the correlation rule, not decoration: a
        // non-Bluetooth accessory cannot be the Bluetooth device the other
        // source found, so it is dropped before any matching is attempted.
        guard string(properties[Key.transportType]) == bluetoothTransport else { return nil }
        guard let name = string(properties[Key.name]) else { return nil }
        guard let category = string(properties[Key.category]) else { return nil }
        guard let percentage = percentage(properties) else { return nil }

        return PowerAccessoryReading(
            name: name,
            category: category,
            percentage: percentage,
            externalPower: externalPower(properties),
            partIdentifier: string(properties[Key.partIdentifier])
        )
    }

    /// `Current Capacity` against `Max Capacity`, both required.
    ///
    /// The maximum is read rather than assumed to be 100: this output states it,
    /// and a source that starts reporting a different scale must not be silently
    /// rescaled as if it were percent. Anything out of range, non-numeric or
    /// missing is absent — never a zero.
    static func percentage(_ properties: [String: Any]) -> Int? {
        guard let current = integer(properties[Key.currentCapacity]),
              let maximum = integer(properties[Key.maximumCapacity]),
              maximum > 0,
              current >= 0,
              current <= maximum else { return nil }
        return AppleDeviceNormalizer.percentage(
            roundingPercent: Double(current) * 100 / Double(maximum)
        )
    }

    /// Charging state, only when the source actually states it.
    ///
    /// `Is Charging` is the field that means what it says. `Is Charged` is not
    /// treated as evidence of external power: a full battery is not a cable,
    /// and this module's whole premise is that 100% is not proof of charging.
    /// Absent, malformed or contradictory reads as `unknown`.
    static func externalPower(_ properties: [String: Any]) -> DeviceExternalPowerState {
        guard let charging = bool(properties[Key.isCharging]) else { return .unknown }
        return charging ? .connected : .disconnected
    }

    /// The document boundaries of a concatenated plist stream.
    static func documents(in text: String) -> [String] {
        var documents: [String] = []
        var remainder = Substring(text)
        let opening = "<?xml"
        let closing = "</plist>"

        while documents.count < maximumRecords,
              let start = remainder.range(of: opening),
              let end = remainder.range(of: closing, range: start.upperBound..<remainder.endIndex) {
            documents.append(String(remainder[start.lowerBound..<end.upperBound]))
            remainder = remainder[end.upperBound...]
        }
        return documents
    }

    // MARK: - Defensive value reading

    /// `Is Charging` arrives as an integer here and as a real boolean in the
    /// neighbouring `Is Charged`, so both shapes are accepted — and nothing
    /// else is. A string, a dictionary or a key reused for something else reads
    /// as absent rather than as "charging".
    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        switch number.intValue {
        case 0: return false
        case 1: return true
        default: return nil
        }
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
