import Foundation

/// One place where a battery number is allowed to become a battery number.
///
/// The same discipline `PowerNormalizer` already applies to this Mac, applied
/// to devices whose values arrive from far less predictable places: an
/// undocumented registry property, a plist from a phone, a firmware that
/// reports 255 for "unknown". `-1`, `255`, `101`, `NaN` and `Infinity` all mean
/// the same thing here — no reading — and none of them may reach the panel as
/// `-100%` or `25500%`.
///
/// Invalid input becomes `nil`, never `0`. A zero is a real state a real
/// battery reaches, so it cannot double as the value we print when we have
/// nothing.
enum AppleDeviceNormalizer {
    /// Names arrive from the devices themselves, so they can be long, empty,
    /// or full of whitespace and control characters. 64 characters is past the
    /// point where any panel would still be showing the end of one.
    static let maximumDisplayNameCharacters = 64

    static func percentage(fromPercent value: Int?) -> Int? {
        guard let value, (0...100).contains(value) else { return nil }
        return value
    }

    /// For sources that report a fraction of full charge.
    static func percentage(fromFraction value: Double?) -> Int? {
        guard let value, value.isFinite, (0.0...1.0).contains(value) else { return nil }
        return Int((value * 100).rounded())
    }

    /// For sources that hand over a percentage as a number rather than an
    /// integer. Distinct name rather than an overload: `percentage(fromPercent: 0)`
    /// would otherwise be ambiguous at every call site.
    static func percentage(roundingPercent value: Double?) -> Int? {
        guard let value, value.isFinite, (0.0...100.0).contains(value) else { return nil }
        return Int(value.rounded())
    }

    /// Builds a component, or nothing if there is nothing to say.
    ///
    /// Returning `nil` rather than an empty component is what keeps an absent
    /// AirPod out of the list instead of putting it there at 0%.
    static func component(
        kind: DeviceBatteryComponentKind,
        percentage: Int?,
        chargingState: DeviceChargingState? = nil,
        status: DeviceBatteryStatus? = nil,
        lastUpdated: Date? = nil
    ) -> DeviceBatteryComponent? {
        let component = DeviceBatteryComponent(
            kind: kind,
            percentage: self.percentage(fromPercent: percentage),
            chargingState: chargingState,
            status: status,
            lastUpdated: lastUpdated
        )
        return component.hasReading ? component : nil
    }

    /// A device name for display: trimmed, single-line and bounded.
    ///
    /// Cyrillic, emoji and right-to-left names pass through unchanged — the
    /// only thing removed is the ability of a 4 000-character name to decide
    /// the panel's layout.
    static func displayName(_ raw: String?, fallback: String) -> String {
        guard let raw else { return fallback }
        let line = BoundedText.firstLine(raw, maximumCharacters: maximumDisplayNameCharacters)
        return line.isEmpty ? fallback : line
    }

    /// Which of the declared capabilities the readings actually exercise.
    ///
    /// Derived rather than hand-written at each call site, so a provider cannot
    /// promise `.percentage` for a device that never reports one.
    static func capabilities(for components: [DeviceBatteryComponent]) -> Set<DeviceCapability> {
        var capabilities = Set<DeviceCapability>()
        if components.contains(where: { $0.percentage != nil }) { capabilities.insert(.percentage) }
        if components.contains(where: { ($0.chargingState ?? .unknown) != .unknown }) {
            capabilities.insert(.chargingState)
        }
        if components.contains(where: { $0.status != nil }) { capabilities.insert(.categoricalStatus) }
        if components.filter(\.hasReading).count > 1 { capabilities.insert(.multipleComponents) }
        return capabilities
    }
}
