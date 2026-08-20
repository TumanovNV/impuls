import Foundation

/// The exact sequence Impuls performs against a connected iPhone or iPad:
///
/// ```text
/// usbmuxd socket → ListDevices → USB and Wi-Fi-sync devices
///                → ReadPairRecord → is this Mac trusted?
///                → Connect(deviceID, port 62078) → lockdownd
///                → QueryType → is this really lockdownd?
///                → GetValue(battery) → the one number we want
/// ```
///
/// Every step is read-only. Impuls never pairs, never writes a pair record,
/// never installs anything, never asks for a backup, and never requests a value
/// it does not need. The device's serial number is required by the protocol to
/// look up an existing pair record; it exists here as a local `let`, never
/// leaves this type, and is never logged.
///
/// The list of things deliberately not requested is longer than the list of
/// things requested: no IMEI, no phone number, no Apple ID, no installed
/// applications, no contacts, no photos, no files. The protocol offers all of
/// them. Least privilege at the protocol level means asking for a battery
/// percentage and stopping.
struct MobileDeviceClient: Sendable {
    /// Where lockdownd listens on every iOS device. Sent to usbmuxd in network
    /// byte order, which is what the daemon expects in this field.
    static let lockdownPort: UInt16 = 62_078

    private let factory: MobileDeviceChannelFactory
    private let timeout: TimeInterval

    init(
        factory: MobileDeviceChannelFactory = UnixSocketChannelFactory(),
        timeout: TimeInterval = MobileDeviceConversation.defaultTimeout
    ) {
        self.factory = factory
        self.timeout = timeout
    }

    // MARK: - Devices

    /// Everything the system daemon can currently route to lockdownd.
    ///
    /// Both transports still use this local UNIX socket. Impuls does not scan
    /// the LAN, resolve Bonjour services or open a TCP connection itself;
    /// macOS owns discovery and routing for devices enabled for Wi-Fi sync.
    func listDevices() throws -> [MobileDeviceDescriptor] {
        let channel = try factory.connect()
        defer { channel.close() }
        let conversation = MobileDeviceConversation(channel: channel, timeout: timeout)

        try conversation.sendUsbmux(Self.request("ListDevices"), tag: 1)
        let reply = try conversation.receiveUsbmux()
        guard let list = reply["DeviceList"] as? [[String: Any]] else {
            // An empty Mac is not an error, but a reply without the key at all
            // means we are not talking to the daemon we think we are.
            throw MobileDeviceError.malformedResponse("ListDevices reply has no DeviceList")
        }

        return list.compactMap(Self.descriptor(from:))
    }

    static func descriptor(from entry: [String: Any]) -> MobileDeviceDescriptor? {
        let properties = entry["Properties"] as? [String: Any] ?? [:]
        guard let deviceID = integer(entry["DeviceID"]) ?? integer(properties["DeviceID"]),
              let identifier = (properties["SerialNumber"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else { return nil }
        guard deviceID > 0,
              let connection = MobileDeviceConnection(usbmuxValue: properties["ConnectionType"] as? String)
        else { return nil }
        return MobileDeviceDescriptor(
            deviceID: deviceID,
            rawIdentifier: identifier,
            connection: connection
        )
    }

    // MARK: - Trust

    /// Whether this Mac already has a pairing with the device.
    ///
    /// Impuls only ever reads this record. Pairing is a decision a person makes
    /// on the phone, by unlocking it and tapping Trust; an application that
    /// tried to create or replace a pair record behind that dialog would be
    /// doing something the owner did not ask for.
    func isTrusted(_ device: MobileDeviceDescriptor) throws -> Bool {
        (try? pairRecord(for: device)) != nil
    }

    /// The existing pairing, read and not modified.
    func pairRecord(for device: MobileDeviceDescriptor) throws -> LockdownPairRecord {
        let channel = try factory.connect()
        defer { channel.close() }
        let conversation = MobileDeviceConversation(channel: channel, timeout: timeout)

        var request = Self.request("ReadPairRecord")
        request["PairRecordID"] = device.rawIdentifier
        try conversation.sendUsbmux(request, tag: 2)
        let reply = try conversation.receiveUsbmux()
        guard let data = reply["PairRecordData"] as? Data,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let record = LockdownPairRecord(plist: dictionary) else {
            throw MobileDeviceError.notTrusted
        }
        return record
    }

    // MARK: - Battery

    /// Opens lockdownd and asks for the battery.
    ///
    /// The reply is classified rather than propagated: a phone that is locked,
    /// a Mac that is not trusted and a value that modern iOS refuses without an
    /// authenticated session are three different sentences for a person, and
    /// none of them is an error code.
    func batteryReading(for device: MobileDeviceDescriptor) throws -> MobileDeviceBatteryReading {
        let channel = try factory.connect()
        defer { channel.close() }
        let conversation = MobileDeviceConversation(channel: channel, timeout: timeout)

        var connect = Self.request("Connect")
        connect["DeviceID"] = device.deviceID
        connect["PortNumber"] = Int(Self.lockdownPort.bigEndian)
        try conversation.sendUsbmux(connect, tag: 3)
        let connected = try conversation.receiveUsbmux()
        guard Self.integer(connected["Number"]) == 0 else {
            throw MobileDeviceError.serviceUnavailable("lockdown port refused")
        }

        // From here the socket is a pipe to lockdownd and the framing changes.
        try conversation.sendLockdown(Self.lockdownRequest("QueryType"))
        let type = try conversation.receiveLockdown()
        guard (type["Type"] as? String) == "com.apple.mobile.lockdown" else {
            throw MobileDeviceError.malformedResponse("unexpected lockdown service type")
        }

        // Measured on iOS 26.5.2: the battery domain answers `GetProhibited`
        // outside a session, so the session is opened first. Name and model are
        // readable either way and are fetched after, over whichever channel the
        // conversation ended up on.
        let session = try openSession(for: device, on: conversation, channel: channel)

        let percentage = try value(
            domain: "com.apple.mobile.battery",
            key: "BatteryCurrentCapacity",
            on: session
        )
        let charging = try? value(domain: "com.apple.mobile.battery", key: "BatteryIsCharging", on: session)
        let externalPower = try? value(domain: "com.apple.mobile.battery", key: "ExternalConnected", on: session)
        // Names and model identifiers are not worth a failure: without them the
        // device is shown as an iPhone with a charge, which is the point.
        let name = try? value(domain: nil, key: "DeviceName", on: session)
        let productType = try? value(domain: nil, key: "ProductType", on: session)

        return MobileDeviceBatteryReading(
            percentage: AppleDeviceNormalizer.percentage(fromPercent: Self.integer(percentage)),
            isCharging: Self.boolean(charging),
            externallyConnected: Self.boolean(externalPower),
            deviceName: name as? String,
            productType: productType as? String
        )
    }

    /// `StartSession`, and the TLS upgrade it asks for.
    ///
    /// The session uses the pairing this Mac already has. Impuls does not pair,
    /// does not write a pair record and does not ask the phone to trust it
    /// again: if there is no record, the answer is `notTrusted`, which the
    /// interface turns into "unlock your iPhone and tap Trust".
    private func openSession(
        for device: MobileDeviceDescriptor,
        on conversation: MobileDeviceConversation,
        channel: MobileDeviceByteChannel
    ) throws -> MobileDeviceConversation {
        let record = try pairRecord(for: device)

        var request = Self.lockdownRequest("StartSession")
        request["HostID"] = record.hostID
        request["SystemBUID"] = record.systemBUID
        try conversation.sendLockdown(request)
        let reply = try conversation.receiveLockdown()

        if let error = reply["Error"] as? String { throw Self.error(for: error) }
        guard (reply["EnableSessionSSL"] as? NSNumber)?.boolValue == true else {
            // A device that does not ask for TLS is answered in plain text,
            // which is what older systems did. Nothing is forced.
            return conversation
        }

        let identity = try record.makeIdentity()
        let tls = try LockdownTLSChannel(
            upgrading: channel,
            identity: identity,
            pinnedCertificates: record.pinnedCertificates(),
            timeout: timeout
        )
        return MobileDeviceConversation(channel: tls, timeout: timeout)
    }

    /// One `GetValue`, with the reply's error strings turned into states.
    private func value(domain: String?, key: String, on conversation: MobileDeviceConversation) throws -> Any? {
        var request = Self.lockdownRequest("GetValue")
        if let domain { request["Domain"] = domain }
        request["Key"] = key
        try conversation.sendLockdown(request)
        let reply = try conversation.receiveLockdown()

        if let error = reply["Error"] as? String {
            throw Self.error(for: error)
        }
        return reply["Value"]
    }

    /// The lockdown error vocabulary, mapped to what a person has to do.
    ///
    /// `SessionInactive` and `InvalidHostID` are the interesting pair: they mean
    /// the value exists but requires an authenticated session, which is the
    /// boundary this phase deliberately stops at. See
    /// `docs/APPLE_DEVICE_BATTERY_SUPPORT.md`.
    static func error(for lockdownError: String) -> MobileDeviceError {
        switch lockdownError {
        case "PasswordProtected": return .deviceLocked
        case "InvalidHostID", "UserDeniedPairing", "PairingDialogResponsePending": return .notTrusted
        case "SessionInactive", "GetProhibited", "SessionRequired": return .sessionRequired
        case "MissingValue", "InvalidValue": return .batteryUnavailable
        default: return .serviceUnavailable(lockdownError)
        }
    }

    // MARK: - Message helpers

    private static func request(_ type: String) -> [String: Any] {
        [
            "MessageType": type,
            "ClientVersionString": "Impuls",
            "ProgName": "Impuls",
            "kLibUSBMuxVersion": 3,
        ]
    }

    private static func lockdownRequest(_ type: String) -> [String: Any] {
        ["Request": type, "Label": "Impuls"]
    }

    static func integer(_ value: Any?) -> Int? {
        RegistryNumber.integer(value)
    }

    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber else { return nil }
        return number.boolValue
    }
}

/// A device as usbmuxd describes it.
///
/// `rawIdentifier` is the device's UDID. It is required by the protocol — a
/// pair record is looked up by it — and it goes no further than this type and
/// the identity resolver. It is not part of any snapshot, is never logged, and
/// is not what identifies the device inside Impuls.
struct MobileDeviceDescriptor: Equatable, Sendable {
    let deviceID: Int
    let rawIdentifier: String
    let connection: MobileDeviceConnection

    init(
        deviceID: Int,
        rawIdentifier: String,
        connection: MobileDeviceConnection = .usb
    ) {
        self.deviceID = deviceID
        self.rawIdentifier = rawIdentifier
        self.connection = connection
    }
}

/// The route macOS usbmuxd selected for one transient device entry.
///
/// The raw plist vocabulary ends here. Unknown future values are ignored rather
/// than guessed, and the numeric `DeviceID` is never treated as identity: the
/// same phone has already been measured with different USB and Network IDs.
enum MobileDeviceConnection: Equatable, Hashable, Sendable {
    case usb
    case network

    init?(usbmuxValue: String?) {
        switch usbmuxValue {
        case "USB": self = .usb
        case "Network": self = .network
        default: return nil
        }
    }

    var snapshotConnection: DeviceConnectionKind {
        switch self {
        case .usb: return .usb
        case .network: return .wifi
        }
    }

    var snapshotSource: DeviceDataSource {
        switch self {
        case .usb: return .mobileUSB
        case .network: return .mobileWiFi
        }
    }
}

struct MobileDeviceBatteryReading: Equatable, Sendable {
    let percentage: Int?
    let isCharging: Bool?
    let externallyConnected: Bool?
    let deviceName: String?
    let productType: String?

    var hasBattery: Bool { percentage != nil }
}
