import Foundation

/// Diagnostics for the device layer, with nothing in them worth leaking.
///
/// Development needs to see which providers started, how many devices came
/// back and when one went away. None of that requires a UDID, a serial number
/// or a Bluetooth address, and a log line is the easiest way for such a value
/// to end up in a screenshot attached to a public issue. `AppleDeviceIdentity`
/// already redacts itself when interpolated; this keeps the rest short and
/// silent by default.
enum DevicePowerLog {
    /// Off unless asked for. Production logs stay minimal, and a release build
    /// that chattered on every refresh would be its own privacy problem.
    static var isEnabled: Bool = ProcessInfo.processInfo.environment["IMPULS_DEVICE_LOG"] == "1"

    private static let maximumMessageCharacters = 200

    static func note(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        NSLog("[DevicePowerCenter] %@", BoundedText.prefix(message(), maximumCharacters: maximumMessageCharacters))
    }
}

/// What each provider is doing right now, for tests and for a future
/// diagnostics view. Counts and states only — never a device identifier.
struct DeviceProviderDiagnostic: Equatable, Sendable, Identifiable {
    let provider: DeviceProviderIdentifier
    let status: DeviceProviderStatus
    let deviceCount: Int

    var id: DeviceProviderIdentifier { provider }
}
