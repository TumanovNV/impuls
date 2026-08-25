import Foundation

/// Attaches a `pmset` battery reading to a device `system_profiler` already
/// found, or attaches nothing.
///
/// The two sources share no identifier. `pmset`'s accessory UUID is not the
/// Bluetooth address and does not appear in `system_profiler`'s output at all —
/// measured, not assumed. So the only thing that can join them is the
/// user-visible name, and a name is weak evidence: it is user-editable and not
/// guaranteed unique. Everything here exists to make that weakness safe.
///
/// The rule is **strict one-to-one, fail closed**. A match requires all of:
///
/// 1. the reading is a Bluetooth accessory (enforced by the parser);
/// 2. the normalised names are equal;
/// 3. the device classes are compatible;
/// 4. exactly one candidate and exactly one reading carry that name.
///
/// Anything else — two devices with the same name, two readings with the same
/// name, a class that disagrees, a missing name — produces no overlay. A
/// missing battery is a correct outcome; a battery shown against the wrong
/// device is not.
///
/// Explicitly **not** used for matching: the percentage itself, record order,
/// arrival time, "there is only one accessory connected", name similarity, or
/// any attempt to relate the accessory UUID to a Bluetooth address. Each of
/// those is a guess, and a guess is what this module refuses to make.
enum PowerAccessoryOverlay {
    /// Devices built from a candidate plus its one unambiguous reading.
    static func apply(
        candidates: [SystemProfilerAccessoryParser.BatterylessDevice],
        readings: [PowerAccessoryReading],
        now: Date
    ) -> [AppleDeviceSnapshot] {
        guard !candidates.isEmpty, !readings.isEmpty else { return [] }

        let candidatesByName = uniqueByName(candidates, name: \.displayName)
        let readingsByName = uniqueByName(readings, name: \.name)

        return candidatesByName.keys.sorted().compactMap { key in
            guard let candidate = candidatesByName[key],
                  let reading = readingsByName[key],
                  isCompatible(kind: candidate.kind, category: reading.category) else { return nil }
            return snapshot(candidate: candidate, reading: reading, now: now)
        }
    }

    /// Groups by normalised name and keeps only the names that appear once.
    ///
    /// A name held by two entries is discarded from **both** sides rather than
    /// resolved: with no other shared identifier there is no evidence that
    /// would decide which is which, and picking one would be the guess this
    /// type exists to avoid.
    static func uniqueByName<T>(_ values: [T], name: KeyPath<T, String>) -> [String: T] {
        var byName: [String: T] = [:]
        var duplicated: Set<String> = []

        for value in values {
            let key = normalized(value[keyPath: name])
            guard !key.isEmpty else { continue }
            if byName[key] != nil { duplicated.insert(key) } else { byName[key] = value }
        }
        for key in duplicated { byName[key] = nil }
        return byName
    }

    /// Case- and whitespace-insensitive, and nothing more.
    ///
    /// Deliberately not clever: no punctuation stripping, no fuzzy distance, no
    /// removal of the decorative marks macOS puts in some names. Loosening this
    /// buys matches by making false matches possible, and a false match here
    /// shows one device's battery on another.
    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Whether the class `system_profiler` assigned and the class `pmset`
    /// reports can be the same physical device.
    ///
    /// Compared as families rather than as equal values: the same headset is
    /// `Headphones` to one source and `Headset` to the other, and an Apple
    /// headset is `.airPodsPro` to one and `Headset` to the other. Both are
    /// agreements about what the device *is*. A keyboard reported as a mouse is
    /// not, and produces no overlay.
    static func isCompatible(kind: AppleDeviceKind, category: String) -> Bool {
        guard let reported = family(of: AppleAccessoryNaming.kind(fromBluetoothMinorType: category)) else {
            // An unrecognised category can only be attached to a device whose
            // own class is equally unknown.
            return family(of: kind) == nil
        }
        guard let existing = family(of: kind) else { return false }
        return existing == reported
    }

    private enum DeviceFamily { case headphones, keyboard, mouse, trackpad }

    private static func family(of kind: AppleDeviceKind) -> DeviceFamily? {
        switch kind {
        case .headphones, .airPods, .airPodsPro, .airPodsMax: return .headphones
        case .keyboard, .magicKeyboard: return .keyboard
        case .mouse, .magicMouse: return .mouse
        case .trackpad, .magicTrackpad: return .trackpad
        default: return nil
        }
    }

    /// The device keeps everything `system_profiler` established — identity,
    /// name, class — and gains only the battery and, when the source states it,
    /// the charging state.
    private static func snapshot(
        candidate: SystemProfilerAccessoryParser.BatterylessDevice,
        reading: PowerAccessoryReading,
        now: Date
    ) -> AppleDeviceSnapshot? {
        guard let component = AppleDeviceNormalizer.component(
            kind: componentKind(for: reading.partIdentifier),
            percentage: reading.percentage,
            lastUpdated: now
        ) else { return nil }

        return AppleDeviceSnapshot(
            identity: candidate.identity,
            kind: candidate.kind,
            displayName: candidate.displayName,
            modelName: candidate.modelName,
            connection: .bluetooth,
            availability: .connected,
            externalPower: reading.externalPower,
            components: [component],
            lastSeen: now,
            lastUpdated: now,
            source: .systemProfilerAccessory,
            capabilities: AppleDeviceNormalizer.capabilities(for: [component])
        )
    }

    /// `Part Identifier` names which battery inside the accessory this is.
    /// `Single` is the whole device; the split values are what a multi-part
    /// accessory reports. An unfamiliar value is treated as the whole device
    /// rather than invented into a component that may not exist.
    static func componentKind(for partIdentifier: String?) -> DeviceBatteryComponentKind {
        switch partIdentifier?.lowercased() {
        case "left": return .left
        case "right": return .right
        case "case": return .chargingCase
        default: return .primary
        }
    }
}
