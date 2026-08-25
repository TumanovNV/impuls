import Foundation

/// The hardware-neutral vocabulary of the Apple Device Battery Center.
///
/// `PowerSnapshot` describes one machine — this Mac — and stays exactly as it
/// is. These types describe *any* device the Mac can see, which is a different
/// shape: a device may carry several batteries, may report a category instead
/// of a percentage, and may be seen through more than one transport at once.
/// Growing `PowerSnapshot` with `airPodsLeftBattery` and `iphoneBattery` fields
/// would have made every future device a change to the local Mac's model.
///
/// Every hardware-dependent field is optional. Absence is data: it means the
/// system did not tell us, and it must never be rewritten as a zero.

enum AppleDeviceKind: String, Equatable, Hashable, Sendable, CaseIterable {
    case mac
    case iPhone
    case iPad
    case appleWatch
    case airPods
    case airPodsPro
    case airPodsMax
    case magicMouse
    case magicKeyboard
    case magicTrackpad
    case applePencil
    case visionPro
    case airTag
    case siriRemote
    /// Unrecognised **Apple** device. Kept distinct from the generic kinds
    /// below so an Apple accessory whose model this build does not know still
    /// reads as an Apple device rather than as an anonymous one.
    case unknown

    // Generic, vendor-neutral kinds.
    //
    // A Bluetooth accessory is not required to be Apple hardware to have a
    // battery macOS can read. When the system reports a usable level for a
    // third-party device, the honest presentation is its real name plus the
    // device class the system itself stated — never a guessed brand or model.
    // These are deliberately coarse: `Headset` and `Headphones` both become
    // `.headphones`, because that is the distinction the source actually
    // supports.
    case headphones
    case keyboard
    case mouse
    case trackpad
    /// A battery-carrying accessory whose class the system did not state.
    case accessory
}

/// Which battery inside a device a reading belongs to.
///
/// `chargingCase` rather than `case`, which is a Swift keyword and would have
/// to be back-ticked at every use site.
enum DeviceBatteryComponentKind: String, Equatable, Hashable, Sendable, CaseIterable {
    case primary
    case left
    case right
    case chargingCase
    case external
    case accessory

    /// Presentation order, so a device with several batteries always lists them
    /// the same way. Kept in the model because it is a property of the hardware
    /// layout — left ear before right ear before the case — and not a matter of
    /// taste for one pane to decide.
    var displayOrder: Int {
        switch self {
        case .primary: return 0
        case .left: return 1
        case .right: return 2
        case .chargingCase: return 3
        case .external: return 4
        case .accessory: return 5
        }
    }
}

enum DeviceChargingState: String, Equatable, Hashable, Sendable {
    case charging
    case discharging
    case charged
    case notCharging
    case unknown
}

/// For hardware that reports a category and never a number.
///
/// An AirTag that says "Low Battery" is not 15%, and inventing that number is
/// the exact failure this whole module is written to avoid. A device that has
/// only this may still be shown honestly; it simply has no percentage.
enum DeviceBatteryStatus: String, Equatable, Hashable, Sendable {
    case ok
    case low
    case critical
}

struct DeviceBatteryComponent: Equatable, Hashable, Sendable {
    let kind: DeviceBatteryComponentKind
    /// Whole percent, 0…100, already validated by `AppleDeviceNormalizer`.
    let percentage: Int?
    let chargingState: DeviceChargingState?
    let status: DeviceBatteryStatus?
    let lastUpdated: Date?

    init(
        kind: DeviceBatteryComponentKind,
        percentage: Int? = nil,
        chargingState: DeviceChargingState? = nil,
        status: DeviceBatteryStatus? = nil,
        lastUpdated: Date? = nil
    ) {
        self.kind = kind
        self.percentage = percentage
        self.chargingState = chargingState
        self.status = status
        self.lastUpdated = lastUpdated
    }

    /// A component that carries no reading at all is not worth showing and not
    /// worth merging. `unknown` charging on its own does not count as one.
    var hasReading: Bool {
        if percentage != nil { return true }
        if status != nil { return true }
        if let chargingState, chargingState != .unknown { return true }
        return false
    }
}

/// How the Mac is currently reaching the device.
enum DeviceConnectionKind: String, Equatable, Hashable, Sendable {
    case builtIn
    case bluetooth
    case usb
    case wifi
    case unknown
}

/// Whether the device is being fed from outside its own battery.
///
/// Deliberately not Mac-specific: an iPhone on a charger and a Mac mini in a
/// wall socket are the same statement, and a desktop Mac — which has no battery
/// at all — is described entirely by this field.
enum DeviceExternalPowerState: String, Equatable, Hashable, Sendable {
    case connected
    case disconnected
    case unknown
}

enum DeviceAvailability: String, Equatable, Hashable, Sendable {
    case connected
    case recentlyDisconnected
    case unavailable
}

/// Where a reading came from, and how much it is trusted when two sources
/// describe the same device.
///
/// Priority is a property of the source, not of the moment: a value read from
/// the local IOKit surface beats one relayed over Wi-Fi even if the Wi-Fi one
/// arrived a second later. Timestamps break ties within one priority, and a
/// newer reading never loses to an older one from the same source.
enum DeviceDataSource: String, Equatable, Hashable, Sendable {
    case localIOKit
    case ioRegistryAccessory
    case systemProfilerAccessory
    case mobileUSB
    case mobileWiFi

    var priority: Int {
        switch self {
        case .localIOKit: return 40
        // The registry, when it has anything, is the livelier of the two
        // accessory sources: it is read directly and costs nothing. The
        // system_profiler path ranks just below it because it is a process
        // spawn and its values come from a daemon's own cache — but on hardware
        // where the registry is silent, it is the only one that answers.
        case .ioRegistryAccessory: return 30
        case .systemProfilerAccessory: return 25
        case .mobileUSB: return 20
        case .mobileWiFi: return 10
        }
    }
}

/// What a device is able to tell us — not what it happens to be telling us now.
///
/// The distinction matters for the UI: a device with `.percentage` whose value
/// is momentarily missing is a device with a gap, while a device without that
/// capability will never have a number and should not be drawn as though it is
/// still loading one.
enum DeviceCapability: String, Equatable, Hashable, Sendable, CaseIterable {
    case percentage
    case chargingState
    case categoricalStatus
    case multipleComponents
}

/// How much the reading can still be believed.
enum DeviceFreshness: String, Equatable, Hashable, Sendable {
    case fresh
    case stale
    case unavailable
}

struct AppleDeviceSnapshot: Equatable, Sendable {
    let identity: AppleDeviceIdentity
    let kind: AppleDeviceKind
    /// The name a person would recognise, already trimmed and length-bounded.
    /// Never an identifier — see `AppleDeviceIdentity`.
    let displayName: String
    let modelName: String?
    let connection: DeviceConnectionKind
    let availability: DeviceAvailability
    let externalPower: DeviceExternalPowerState
    let components: [DeviceBatteryComponent]
    let lastSeen: Date?
    let lastUpdated: Date?
    let source: DeviceDataSource
    let capabilities: Set<DeviceCapability>

    init(
        identity: AppleDeviceIdentity,
        kind: AppleDeviceKind,
        displayName: String,
        modelName: String? = nil,
        connection: DeviceConnectionKind,
        availability: DeviceAvailability = .connected,
        externalPower: DeviceExternalPowerState = .unknown,
        components: [DeviceBatteryComponent] = [],
        lastSeen: Date? = nil,
        lastUpdated: Date? = nil,
        source: DeviceDataSource,
        capabilities: Set<DeviceCapability> = []
    ) {
        self.identity = identity
        self.kind = kind
        self.displayName = displayName
        self.modelName = modelName
        self.connection = connection
        self.availability = availability
        self.externalPower = externalPower
        self.components = components.sorted { $0.kind.displayOrder < $1.kind.displayOrder }
        self.lastSeen = lastSeen
        self.lastUpdated = lastUpdated
        self.source = source
        self.capabilities = capabilities
    }

    /// The single number a compact row shows, when there is one to show.
    ///
    /// The primary battery if the device has one, otherwise the lowest reading
    /// among its components — for earphones the ear that will die first is the
    /// honest summary, not their average, which would describe neither.
    var headlinePercentage: Int? {
        if let primary = components.first(where: { $0.kind == .primary })?.percentage {
            return primary
        }
        return components.compactMap(\.percentage).min()
    }

    /// A device with no battery is not a broken device. A desktop Mac reaches
    /// the coordinator exactly like a MacBook does, and only the pane decides
    /// whether a card with no percentage is worth drawing.
    var hasBatteryReading: Bool {
        components.contains { $0.hasReading }
    }
}
