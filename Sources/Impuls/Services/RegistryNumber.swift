import Foundation

/// Coercion for numbers that arrive from IOKit, usbmuxd property lists and the
/// other system dictionaries whose value types are not a compatibility promise.
///
/// The conversion is total. `Int(someDouble)` is a **trap** rather than an
/// overflow when the value falls outside `Int`'s range, so a driver or a device
/// publishing an unexpected magnitude under a key we happen to read would take
/// the application down instead of being ignored. Every step here turns a value
/// that cannot be represented into `nil`.
///
/// There is deliberately no upper bound of its own. What counts as a plausible
/// battery percentage, cell capacity or vendor id belongs to the caller's
/// domain, and those owners already say so: `AppleDeviceNormalizer` clamps a
/// percentage to `0...100`, `PowerSnapshot` checks its capacity pair before
/// dividing. A limit invented at this layer would silently drop values those
/// owners consider valid, which is a different bug from the one being fixed.
enum RegistryNumber {
    /// Rounds first so an ordinary fractional reading still converts, then uses
    /// the failable initialiser to reject a magnitude `Int` cannot hold.
    static func integer(_ value: Any?) -> Int? {
        guard let doubleValue = double(value) else { return nil }
        return Int(exactly: doubleValue.rounded())
    }

    static func double(_ value: Any?) -> Double? {
        guard let value, let number = value as? NSNumber else { return nil }
        // `true` bridges to NSNumber 1, and a flag misread as 1% would be a
        // wrong number rather than a missing one.
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite else { return nil }
        return doubleValue
    }
}
