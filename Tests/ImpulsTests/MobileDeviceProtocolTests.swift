import XCTest
@testable import ImpulsCore

/// The protocol, tested against a scripted peer.
///
/// None of this needs an iPhone, and none of it substitutes for one: what it
/// proves is that malformed input, a hostile length field, a peer that hangs up
/// mid-answer and a phone that refuses all produce a defined outcome instead of
/// a crash, a hang or an invented battery level. Whether current iOS actually
/// answers the battery question is a hardware matter and is still open.
final class MobileDeviceProtocolTests: XCTestCase {

    // MARK: - Framing

    func testAUsbmuxFrameRoundTripsThroughItsOwnHeader() throws {
        let frame = try MobileDeviceFraming.encodeUsbmux(["MessageType": "ListDevices"], tag: 7)
        let header = frame.prefix(MobileDeviceFraming.usbmuxHeaderBytes)
        let length = try MobileDeviceFraming.usbmuxPayloadLength(from: Data(header))

        XCTAssertEqual(length, frame.count - MobileDeviceFraming.usbmuxHeaderBytes)
        let payload = try MobileDeviceFraming.decodePayload(Data(frame.dropFirst(MobileDeviceFraming.usbmuxHeaderBytes)))
        XCTAssertEqual(payload["MessageType"] as? String, "ListDevices")
    }

    func testALockdownFrameRoundTripsThroughItsOwnHeader() throws {
        let frame = try MobileDeviceFraming.encodeLockdown(["Request": "QueryType"])
        let length = try MobileDeviceFraming.lockdownPayloadLength(from: Data(frame.prefix(4)))

        XCTAssertEqual(length, frame.count - 4)
    }

    func testALengthSmallerThanItsOwnHeaderIsRejected() {
        var header = Data()
        withUnsafeBytes(of: UInt32(4).littleEndian) { header.append(contentsOf: $0) }
        header.append(Data(repeating: 0, count: 12))

        XCTAssertThrowsError(try MobileDeviceFraming.usbmuxPayloadLength(from: header)) { error in
            XCTAssertEqual(error as? MobileDeviceError, .malformedResponse("usbmux frame shorter than its header"))
        }
    }

    func testAnAbsurdLengthIsRefusedBeforeAnythingIsAllocated() {
        var header = Data()
        withUnsafeBytes(of: UInt32.max.littleEndian) { header.append(contentsOf: $0) }
        header.append(Data(repeating: 0, count: 12))

        XCTAssertThrowsError(try MobileDeviceFraming.usbmuxPayloadLength(from: header)) { error in
            guard case .payloadTooLarge = error as? MobileDeviceError else {
                return XCTFail("a four-gigabyte frame must be refused, not attempted")
            }
        }

        var lockdownHeader = Data()
        withUnsafeBytes(of: UInt32(900_000_000).bigEndian) { lockdownHeader.append(contentsOf: $0) }
        XCTAssertThrowsError(try MobileDeviceFraming.lockdownPayloadLength(from: lockdownHeader))
    }

    func testAZeroLengthLockdownFrameIsMalformedRatherThanEmpty() {
        var header = Data()
        withUnsafeBytes(of: UInt32(0).bigEndian) { header.append(contentsOf: $0) }

        XCTAssertThrowsError(try MobileDeviceFraming.lockdownPayloadLength(from: header))
    }

    func testAShortHeaderIsMalformed() {
        XCTAssertThrowsError(try MobileDeviceFraming.usbmuxPayloadLength(from: Data([1, 2, 3])))
        XCTAssertThrowsError(try MobileDeviceFraming.lockdownPayloadLength(from: Data([1, 2])))
    }

    func testATruncatedPlistIsMalformedAndNotAnEmptyAnswer() throws {
        let complete = try PropertyListSerialization.data(
            fromPropertyList: ["Request": "QueryType"],
            format: .xml,
            options: 0
        )

        XCTAssertThrowsError(try MobileDeviceFraming.decodePayload(complete.prefix(complete.count / 2)))
        XCTAssertThrowsError(try MobileDeviceFraming.decodePayload(Data()))
        XCTAssertThrowsError(try MobileDeviceFraming.decodePayload(Data("not a plist at all".utf8)))
    }

    func testAPayloadThatIsNotADictionaryIsRejected() throws {
        let array = try PropertyListSerialization.data(fromPropertyList: [1, 2, 3], format: .xml, options: 0)

        XCTAssertThrowsError(try MobileDeviceFraming.decodePayload(array)) { error in
            XCTAssertEqual(error as? MobileDeviceError, .malformedResponse("payload is not a dictionary"))
        }
    }

    // MARK: - Device listing

    func testOnlyUSBDevicesAreListedAndWiFiOnesAreLeftForLater() throws {
        let peer = ScriptedPeer()
        peer.enqueueUsbmux([
            "DeviceList": [
                ["DeviceID": 3, "Properties": ["ConnectionType": "USB", "SerialNumber": "00008120-AAAA"]],
                ["DeviceID": 4, "Properties": ["ConnectionType": "Network", "SerialNumber": "00008120-BBBB"]],
            ],
        ])

        let devices = try MobileDeviceClient(factory: peer).listUSBDevices()

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.deviceID, 3)
    }

    func testAMacWithNothingPluggedInIsAnEmptyListAndNotAFailure() throws {
        let peer = ScriptedPeer()
        peer.enqueueUsbmux(["DeviceList": []])

        XCTAssertEqual(try MobileDeviceClient(factory: peer).listUSBDevices().count, 0)
    }

    func testAReplyWithoutADeviceListIsTreatedAsAProtocolViolation() {
        let peer = ScriptedPeer()
        peer.enqueueUsbmux(["MessageType": "Result", "Number": 1])

        XCTAssertThrowsError(try MobileDeviceClient(factory: peer).listUSBDevices())
    }

    func testEntriesWithoutAnIdentifierAreSkippedRatherThanGuessedAt() {
        XCTAssertNil(MobileDeviceClient.descriptor(from: ["DeviceID": 3, "Properties": ["ConnectionType": "USB"]]))
        XCTAssertNil(MobileDeviceClient.descriptor(from: ["Properties": ["ConnectionType": "USB", "SerialNumber": "x"]]))
        XCTAssertNil(MobileDeviceClient.descriptor(from: [:]))
    }

    // MARK: - Trust

    func testAPairRecordMeansTrustedAndItsAbsenceMeansNotTrusted() throws {
        let device = MobileDeviceDescriptor(deviceID: 3, rawIdentifier: "00008120-AAAA")

        let trusted = ScriptedPeer()
        trusted.enqueueSessionWithoutTLS()
        XCTAssertTrue(try MobileDeviceClient(factory: trusted).isTrusted(device))

        // Bytes that are not a usable record are not a pairing either.
        let garbage = ScriptedPeer()
        garbage.enqueueUsbmux(["PairRecordData": Data("<plist/>".utf8)])
        XCTAssertFalse(try MobileDeviceClient(factory: garbage).isTrusted(device))

        let untrusted = ScriptedPeer()
        untrusted.enqueueUsbmux(["MessageType": "Result", "Number": 2])
        XCTAssertFalse(try MobileDeviceClient(factory: untrusted).isTrusted(device))
    }

    // MARK: - Battery

    func testAHappyPhoneProducesOneDeviceWithOneBattery() throws {
        let peer = ScriptedPeer()
        peer.enqueueUsbmux(["MessageType": "Result", "Number": 0])
        peer.enqueueLockdown(["Type": "com.apple.mobile.lockdown"])
        peer.enqueueSessionWithoutTLS()
        peer.enqueueLockdown(["Value": 73])
        peer.enqueueLockdown(["Value": true])
        peer.enqueueLockdown(["Value": true])
        peer.enqueueLockdown(["Value": "iPhone Николая"])
        peer.enqueueLockdown(["Value": "iPhone16,1"])

        let reading = try MobileDeviceClient(factory: peer)
            .batteryReading(for: MobileDeviceDescriptor(deviceID: 3, rawIdentifier: "00008120-AAAA"))

        XCTAssertEqual(reading.percentage, 73)
        XCTAssertEqual(reading.isCharging, true)
        XCTAssertEqual(reading.deviceName, "iPhone Николая")
        XCTAssertEqual(reading.productType, "iPhone16,1")
    }

    func testAnImpossibleBatteryValueDoesNotBecomeAPercentage() throws {
        for impossible in [-1, 101, 255] {
            let peer = ScriptedPeer()
            peer.enqueueUsbmux(["MessageType": "Result", "Number": 0])
            peer.enqueueLockdown(["Type": "com.apple.mobile.lockdown"])
            peer.enqueueSessionWithoutTLS()
            peer.enqueueLockdown(["Value": impossible])
            peer.enqueueLockdown(["Value": false])
            peer.enqueueLockdown(["Value": false])
            peer.enqueueLockdown(["Value": "iPhone"])
            peer.enqueueLockdown(["Value": "iPhone16,1"])

            let reading = try MobileDeviceClient(factory: peer)
                .batteryReading(for: MobileDeviceDescriptor(deviceID: 3, rawIdentifier: "x"))
            XCTAssertNil(reading.percentage, "\(impossible) is not a charge")
            XCTAssertFalse(reading.hasBattery)
        }
    }

    func testAMissingBatteryFieldLeavesTheReadingEmptyRatherThanZero() throws {
        let peer = ScriptedPeer()
        peer.enqueueUsbmux(["MessageType": "Result", "Number": 0])
        peer.enqueueLockdown(["Type": "com.apple.mobile.lockdown"])
        peer.enqueueSessionWithoutTLS()
        peer.enqueueLockdown(["Request": "GetValue"])  // no Value, no Error

        let reading = try MobileDeviceClient(factory: peer)
            .batteryReading(for: MobileDeviceDescriptor(deviceID: 3, rawIdentifier: "x"))

        XCTAssertNil(reading.percentage)
        XCTAssertFalse(reading.hasBattery)
    }

    func testALockedPhoneAndAnUntrustedMacAreDifferentAnswers() {
        XCTAssertEqual(MobileDeviceClient.error(for: "PasswordProtected"), .deviceLocked)
        XCTAssertEqual(MobileDeviceClient.error(for: "InvalidHostID"), .notTrusted)
        XCTAssertEqual(MobileDeviceClient.error(for: "UserDeniedPairing"), .notTrusted)
        XCTAssertEqual(MobileDeviceClient.error(for: "PairingDialogResponsePending"), .notTrusted)
        XCTAssertEqual(MobileDeviceClient.error(for: "SessionInactive"), .sessionRequired)
        XCTAssertEqual(MobileDeviceClient.error(for: "GetProhibited"), .sessionRequired)
        XCTAssertEqual(MobileDeviceClient.error(for: "MissingValue"), .batteryUnavailable)
        XCTAssertEqual(MobileDeviceClient.error(for: "SomethingNewInIOS27"), .serviceUnavailable("SomethingNewInIOS27"))
    }

    func testALockedPhoneSurfacesAsSuchRatherThanAsAFailedRead() {
        let peer = ScriptedPeer()
        peer.enqueueUsbmux(["MessageType": "Result", "Number": 0])
        peer.enqueueLockdown(["Type": "com.apple.mobile.lockdown"])
        peer.enqueueSessionWithoutTLS()
        peer.enqueueLockdown(["Error": "PasswordProtected"])

        XCTAssertThrowsError(
            try MobileDeviceClient(factory: peer)
                .batteryReading(for: MobileDeviceDescriptor(deviceID: 3, rawIdentifier: "x"))
        ) { error in
            XCTAssertEqual(error as? MobileDeviceError, .deviceLocked)
        }
    }

    func testARefusedServicePortIsUnavailableAndNotAMalformedReply() {
        let peer = ScriptedPeer()
        peer.enqueueUsbmux(["MessageType": "Result", "Number": 3])

        XCTAssertThrowsError(
            try MobileDeviceClient(factory: peer)
                .batteryReading(for: MobileDeviceDescriptor(deviceID: 3, rawIdentifier: "x"))
        ) { error in
            XCTAssertEqual(error as? MobileDeviceError, .serviceUnavailable("lockdown port refused"))
        }
    }

    func testSomethingThatIsNotLockdownOnTheOtherEndIsRejected() {
        let peer = ScriptedPeer()
        peer.enqueueUsbmux(["MessageType": "Result", "Number": 0])
        peer.enqueueLockdown(["Type": "com.apple.mobile.something.else"])

        XCTAssertThrowsError(
            try MobileDeviceClient(factory: peer)
                .batteryReading(for: MobileDeviceDescriptor(deviceID: 3, rawIdentifier: "x"))
        )
    }

    // MARK: - Session and TLS state

    func testADeviceThatDoesNotAskForTLSIsAnsweredInPlainText() throws {
        let peer = ScriptedPeer()
        peer.enqueueUsbmux(["MessageType": "Result", "Number": 0])
        peer.enqueueLockdown(["Type": "com.apple.mobile.lockdown"])
        peer.enqueueSessionWithoutTLS()
        peer.enqueueLockdown(["Value": 42])
        peer.enqueueLockdown(["Value": false])
        peer.enqueueLockdown(["Value": false])
        peer.enqueueLockdown(["Value": "iPhone"])
        peer.enqueueLockdown(["Value": "iPhone17,2"])

        let reading = try MobileDeviceClient(factory: peer)
            .batteryReading(for: MobileDeviceDescriptor(deviceID: 3, rawIdentifier: "x"))

        XCTAssertEqual(reading.percentage, 42)
    }

    func testAStartSessionErrorBecomesAStateAndNotACode() {
        for (reply, expected) in [
            ("InvalidHostID", MobileDeviceError.notTrusted),
            ("PasswordProtected", MobileDeviceError.deviceLocked),
            ("SessionInactive", MobileDeviceError.sessionRequired),
        ] {
            let peer = ScriptedPeer()
            peer.enqueueUsbmux(["MessageType": "Result", "Number": 0])
            peer.enqueueLockdown(["Type": "com.apple.mobile.lockdown"])
            peer.enqueuePairRecord()
            peer.enqueueLockdown(["Error": reply])

            XCTAssertThrowsError(
                try MobileDeviceClient(factory: peer)
                    .batteryReading(for: MobileDeviceDescriptor(deviceID: 3, rawIdentifier: "x"))
            ) { error in
                XCTAssertEqual(error as? MobileDeviceError, expected)
            }
        }
    }

    func testAMissingPairRecordStopsTheSessionBeforeAnyHandshake() {
        let peer = ScriptedPeer()
        peer.enqueueUsbmux(["MessageType": "Result", "Number": 0])
        peer.enqueueLockdown(["Type": "com.apple.mobile.lockdown"])
        peer.enqueueUsbmux(["MessageType": "Result", "Number": 2])  // no pair record

        XCTAssertThrowsError(
            try MobileDeviceClient(factory: peer)
                .batteryReading(for: MobileDeviceDescriptor(deviceID: 3, rawIdentifier: "x"))
        ) { error in
            XCTAssertEqual(error as? MobileDeviceError, .notTrusted)
        }
    }

    /// A device that asks for TLS and then cannot complete one.
    ///
    /// The handshake has a deadline and an iteration ceiling, so this ends in an
    /// error rather than a spin, and the socket underneath it is closed.
    func testATLSUpgradeThatCannotCompleteFailsAndClosesTheSocket() {
        let peer = ScriptedPeer()
        peer.enqueueUsbmux(["MessageType": "Result", "Number": 0])
        peer.enqueueLockdown(["Type": "com.apple.mobile.lockdown"])
        peer.enqueuePairRecord()
        peer.enqueueLockdown(["Request": "StartSession", "SessionID": "S", "EnableSessionSSL": true])

        let started = Date()
        XCTAssertThrowsError(
            try MobileDeviceClient(factory: peer, timeout: 0.2)
                .batteryReading(for: MobileDeviceDescriptor(deviceID: 3, rawIdentifier: "x"))
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            LockdownTLSChannel.handshakeTimeout + 2,
            "the handshake must be bounded"
        )
        XCTAssertEqual(peer.openChannels, 0, "a failed handshake must not leave a socket open")
    }

    func testATLSChannelRefusesAPeerItCannotPin() throws {
        let record = try XCTUnwrap(LockdownPairRecord(plist: [
            "HostID": "H",
            "SystemBUID": "S",
            "HostCertificate": Data(LockdownPairRecordTests.certificate.utf8),
            "HostPrivateKey": Data(LockdownPairRecordTests.privateKey.utf8),
        ]))
        XCTAssertTrue(record.pinnedCertificates().isEmpty)

        let peer = ScriptedPeer()
        peer.silent = true
        let channel = try peer.connect()
        XCTAssertThrowsError(
            try LockdownTLSChannel(
                upgrading: channel,
                identity: record.makeIdentity(),
                pinnedCertificates: record.pinnedCertificates(),
                timeout: 0.05
            )
        )
    }

    // MARK: - Hostile transport behaviour

    func testAPeerThatHangsUpMidAnswerEndsTheConversation() {
        let peer = ScriptedPeer()
        peer.enqueueRawThenClose(Data([1, 2, 3]))

        XCTAssertThrowsError(try MobileDeviceClient(factory: peer).listUSBDevices()) { error in
            XCTAssertEqual(error as? MobileDeviceError, .deviceDisconnected)
        }
    }

    func testAPeerThatNeverAnswersTimesOutInsteadOfWaitingForever() {
        let peer = ScriptedPeer()
        peer.silent = true

        XCTAssertThrowsError(try MobileDeviceClient(factory: peer, timeout: 0.05).listUSBDevices()) { error in
            XCTAssertEqual(error as? MobileDeviceError, .timedOut)
        }
    }

    func testEveryChannelIsClosedEvenWhenTheConversationFails() {
        let peer = ScriptedPeer()
        peer.silent = true

        _ = try? MobileDeviceClient(factory: peer, timeout: 0.05).listUSBDevices()

        XCTAssertEqual(peer.openChannels, 0, "a failed read must not leak a file descriptor")
        XCTAssertEqual(peer.createdChannels, 1)
    }

    // MARK: - The real daemon

    /// The one test that talks to the system.
    ///
    /// It proves the part of the path that does not need a phone: the socket at
    /// `/var/run/usbmuxd` accepts a connection without root, the framing is the
    /// one the daemon expects, and `ListDevices` comes back parseable. On a Mac
    /// with nothing plugged in the correct answer is an empty list, which is
    /// also the answer on a CI runner.
    ///
    /// Everything past device selection needs hardware and is deliberately not
    /// simulated here.
    func testTheRealUsbmuxDaemonAnswersAListDevicesRequest() throws {
        guard FileManager.default.fileExists(atPath: UnixSocketChannelFactory.usbmuxdPath) else {
            throw XCTSkip("this Mac has no usbmuxd socket")
        }

        let devices = try MobileDeviceClient().listUSBDevices()

        for device in devices {
            XCTAssertGreaterThan(device.deviceID, 0)
            XCTAssertFalse(device.rawIdentifier.isEmpty)
        }
    }

    /// The hardware probe.
    ///
    /// Skips itself when nothing is plugged in, so CI and an ordinary developer
    /// Mac are unaffected. With a device attached it walks the shipping code
    /// path and prints a trace of which step answered — never a UDID, never a
    /// name, never anything from a pair record. This is the test that decides
    /// whether the provider is viable, and it is deliberately part of the suite
    /// rather than a script that gets lost.
    func testHardwareProbeOfTheFullUSBSequence() throws {
        guard FileManager.default.fileExists(atPath: UnixSocketChannelFactory.usbmuxdPath) else {
            throw XCTSkip("this Mac has no usbmuxd socket")
        }
        let client = MobileDeviceClient()
        let devices = try client.listUSBDevices()
        guard let device = devices.first else {
            throw XCTSkip("no iPhone or iPad attached over USB")
        }

        print("PROBE ListDevices          OK — \(devices.count) USB device(s)")

        let trusted = try client.isTrusted(device)
        print("PROBE ReadPairRecord       \(trusted ? "OK — this Mac is trusted" : "NO PAIR RECORD — not trusted")")
        guard trusted else { return }

        do {
            let reading = try client.batteryReading(for: device)
            print("PROBE Connect lockdownd    OK")
            print("PROBE QueryType            OK")
            print("PROBE Battery GetValue     \(reading.percentage.map { "OK — \($0)%" } ?? "no value in reply")")
            print("PROBE   charging           \(reading.isCharging.map(String.init) ?? "nil")")
            print("PROBE   externalConnected  \(reading.externallyConnected.map(String.init) ?? "nil")")
            print("PROBE   name present       \(reading.deviceName != nil)")
            print("PROBE   productType        \(reading.productType ?? "nil")")
        } catch {
            print("PROBE Battery GetValue     FAILED: \(error)")
        }
    }

    /// Repeated reads, and what they leave behind.
    ///
    /// Skips without hardware. With a phone attached it reads five times in a
    /// row and counts this process's open file descriptors before and after:
    /// a socket or an `SSLContext` that outlives its request would show up here
    /// as a number that keeps climbing.
    func testHardwareProbeOfRepeatedReadsAndDescriptorLeaks() throws {
        guard FileManager.default.fileExists(atPath: UnixSocketChannelFactory.usbmuxdPath) else {
            throw XCTSkip("this Mac has no usbmuxd socket")
        }
        let client = MobileDeviceClient()
        guard let device = try client.listUSBDevices().first, try client.isTrusted(device) else {
            throw XCTSkip("no trusted iPhone or iPad attached over USB")
        }

        let before = Self.openDescriptorCount()
        var readings: [Int?] = []
        var durations: [TimeInterval] = []
        for _ in 0..<5 {
            let started = Date()
            let reading = try client.batteryReading(for: device)
            durations.append(Date().timeIntervalSince(started))
            readings.append(reading.percentage)
        }
        let after = Self.openDescriptorCount()

        print("PROBE repeated readings: \(readings.map { $0.map(String.init) ?? "nil" }.joined(separator: ", "))")
        print(String(format: "PROBE per-read duration: min %.2f s, max %.2f s", durations.min() ?? 0, durations.max() ?? 0))
        print("PROBE descriptors before \(before), after \(after)")

        XCTAssertEqual(readings.compactMap { $0 }.count, 5, "every read should have produced a value")
        // A few descriptors of slack for whatever else the test process does;
        // a leak would be five, one per read, and growing.
        XCTAssertLessThanOrEqual(after, before + 2, "sockets or TLS contexts are outliving their request")
    }

    /// The whole provider path, end to end, on hardware.
    ///
    /// Not the protocol this time but the thing the panel would actually show:
    /// a device snapshot with a kind, a name, a charge and a charging state.
    func testHardwareProbeOfTheDeviceSnapshot() async throws {
        guard FileManager.default.fileExists(atPath: UnixSocketChannelFactory.usbmuxdPath) else {
            throw XCTSkip("this Mac has no usbmuxd socket")
        }
        let source = MobileDeviceBatterySource(resolver: DeviceIdentityResolver(
            service: "io.tumanov.impuls.tests.device-identity",
            account: "unit-test"
        ))
        let devices: [AppleDeviceSnapshot]
        do {
            devices = try await source.read()
        } catch {
            print("PROBE snapshot read ended as: \(error)")
            throw XCTSkip("no readable device attached")
        }
        guard let device = devices.first else { throw XCTSkip("no device attached over USB") }

        print("PROBE \(device.kind.rawValue) \"\(device.displayName)\" \(device.headlinePercentage.map { "\($0)%" } ?? "no charge")")
        print("PROBE   charging=\(device.components.first?.chargingState.map(\.rawValue) ?? "nil") externalPower=\(device.externalPower.rawValue)")
        print("PROBE   connection=\(device.connection.rawValue) source=\(device.source.rawValue)")

        XCTAssertTrue(device.hasBatteryReading)
        XCTAssertEqual(device.connection, .usb)
        XCTAssertEqual(device.source, .mobileUSB)
    }

    private static func openDescriptorCount() -> Int {
        let limit = Int(getdtablesize())
        var count = 0
        for descriptor in 0..<limit where fcntl(Int32(descriptor), F_GETFD) != -1 {
            count += 1
        }
        return count
    }

    // MARK: - Snapshot mapping

    func testAReadingBecomesADeviceOnlyWhenItHasACharge() {
        let resolver = DeviceIdentityResolver(
            service: "io.tumanov.impuls.tests.device-identity",
            account: "unit-test"
        )
        let device = MobileDeviceDescriptor(deviceID: 3, rawIdentifier: "00008120-AAAA")

        let withCharge = MobileDeviceBatterySource.snapshot(
            from: MobileDeviceBatteryReading(
                percentage: 73,
                isCharging: true,
                externallyConnected: true,
                deviceName: "iPhone Николая",
                productType: "iPhone16,1"
            ),
            device: device,
            now: Fixtures.noon,
            resolver: resolver
        )
        XCTAssertEqual(withCharge?.kind, .iPhone)
        XCTAssertEqual(withCharge?.displayName, "iPhone Николая")
        XCTAssertEqual(withCharge?.headlinePercentage, 73)
        XCTAssertEqual(withCharge?.connection, .usb)
        XCTAssertEqual(withCharge?.components.first?.chargingState, .charging)

        let withoutCharge = MobileDeviceBatterySource.snapshot(
            from: MobileDeviceBatteryReading(
                percentage: nil,
                isCharging: nil,
                externallyConnected: nil,
                deviceName: "iPhone Николая",
                productType: "iPhone16,1"
            ),
            device: device,
            now: Fixtures.noon,
            resolver: resolver
        )
        XCTAssertNil(withoutCharge, "a phone we know nothing about is not a card")
    }

    func testTheDeviceIdentifierIsNowhereInTheResultingSnapshot() {
        let resolver = DeviceIdentityResolver(
            service: "io.tumanov.impuls.tests.device-identity",
            account: "unit-test"
        )
        let udid = "00008120-000A1B2C3D4E5F60"
        let snapshot = MobileDeviceBatterySource.snapshot(
            from: MobileDeviceBatteryReading(
                percentage: 73,
                isCharging: false,
                externallyConnected: false,
                deviceName: "iPhone",
                productType: "iPhone16,1"
            ),
            device: MobileDeviceDescriptor(deviceID: 3, rawIdentifier: udid),
            now: Fixtures.noon,
            resolver: resolver
        )

        XCTAssertNotNil(snapshot)
        XCTAssertFalse("\(snapshot!.identity)".contains(udid))
        XCTAssertFalse(snapshot!.identity.localPreferenceKey.contains(udid))
        XCTAssertFalse(snapshot!.displayName.contains(udid))
    }

    func testModelKindComesFromTheDevicesOwnProductTypeAndIsNotGuessed() {
        XCTAssertEqual(MobileDeviceBatterySource.kind(from: "iPhone16,1"), .iPhone)
        XCTAssertEqual(MobileDeviceBatterySource.kind(from: "iPad14,3"), .iPad)
        XCTAssertEqual(MobileDeviceBatterySource.kind(from: "AppleTV11,1"), .unknown)
        XCTAssertEqual(MobileDeviceBatterySource.kind(from: nil), .unknown)
    }

    func testChargingStateIsOnlyClaimedWhenTheDeviceSaidSomething() {
        func state(charging: Bool?, external: Bool?) -> DeviceChargingState? {
            MobileDeviceBatterySource.chargingState(
                from: MobileDeviceBatteryReading(
                    percentage: 50,
                    isCharging: charging,
                    externallyConnected: external,
                    deviceName: nil,
                    productType: nil
                )
            )
        }

        XCTAssertEqual(state(charging: true, external: true), .charging)
        XCTAssertEqual(state(charging: false, external: true), .notCharging)
        XCTAssertEqual(state(charging: false, external: false), .discharging)
        XCTAssertNil(state(charging: nil, external: true))
        XCTAssertNil(state(charging: false, external: nil))
    }
}

// MARK: - Scripted peer

/// A usbmuxd that says exactly what a test tells it to.
///
/// It also counts channels, because a leaked file descriptor is the kind of bug
/// that only shows up after a few hundred refreshes on someone else's Mac.
private final class ScriptedPeer: MobileDeviceChannelFactory, @unchecked Sendable {
    /// The pair record and `StartSession` reply that now sit between
    /// `QueryType` and the battery question. `EnableSessionSSL` is false here:
    /// a scripted peer cannot perform a TLS handshake, and the client is
    /// expected to continue in plain text when the device does not ask for one.
    func enqueueSessionWithoutTLS() {
        enqueuePairRecord()
        enqueueLockdown(["Request": "StartSession", "SessionID": "SESSION"])
    }

    func enqueuePairRecord() {
        let record: [String: Any] = [
            "HostID": "HOST-ID",
            "SystemBUID": "SYSTEM-BUID",
            "HostCertificate": Data(LockdownPairRecordTests.certificate.utf8),
            "HostPrivateKey": Data(LockdownPairRecordTests.privateKey.utf8),
            "DeviceCertificate": Data(LockdownPairRecordTests.certificate.utf8),
        ]
        let encoded = try! PropertyListSerialization.data(fromPropertyList: record, format: .xml, options: 0)
        enqueueUsbmux(["PairRecordData": encoded])
    }

    private let lock = NSLock()
    private var queued: [Data] = []
    private var silentFlag = false
    private var closeAfterFlag = false
    private(set) var createdChannels = 0
    private(set) var openChannels = 0

    var silent: Bool {
        get { lock.withLock { silentFlag } }
        set { lock.withLock { silentFlag = newValue } }
    }

    func enqueueUsbmux(_ payload: [String: Any]) {
        let frame = try! MobileDeviceFraming.encodeUsbmux(payload, tag: 1)
        lock.withLock { queued.append(frame) }
    }

    func enqueueLockdown(_ payload: [String: Any]) {
        let frame = try! MobileDeviceFraming.encodeLockdown(payload)
        lock.withLock { queued.append(frame) }
    }

    func enqueueRawThenClose(_ data: Data) {
        lock.withLock {
            queued.append(data)
            closeAfterFlag = true
        }
    }

    func connect() throws -> MobileDeviceByteChannel {
        lock.withLock {
            createdChannels += 1
            openChannels += 1
        }
        return Channel(peer: self)
    }

    fileprivate func nextBytes(_ count: Int) throws -> Data {
        try lock.withLock {
            if silentFlag { throw MobileDeviceError.timedOut }
            guard !queued.isEmpty else { throw MobileDeviceError.deviceDisconnected }
            var buffer = queued.removeFirst()
            if buffer.count < count {
                // Short answer: the peer hung up in the middle of a frame.
                if closeAfterFlag || queued.isEmpty { throw MobileDeviceError.deviceDisconnected }
            }
            let head = buffer.prefix(count)
            buffer = Data(buffer.dropFirst(count))
            if !buffer.isEmpty { queued.insert(buffer, at: 0) }
            return Data(head)
        }
    }

    fileprivate func noteClosed() {
        lock.withLock { openChannels = max(0, openChannels - 1) }
    }

    private final class Channel: MobileDeviceByteChannel {
        private let peer: ScriptedPeer
        private var closed = false

        init(peer: ScriptedPeer) {
            self.peer = peer
        }

        deinit { close() }

        func write(_ data: Data, timeout: TimeInterval) throws {}

        func read(_ count: Int, timeout: TimeInterval) throws -> Data {
            try peer.nextBytes(count)
        }

        func close() {
            guard !closed else { return }
            closed = true
            peer.noteClosed()
        }
    }
}
