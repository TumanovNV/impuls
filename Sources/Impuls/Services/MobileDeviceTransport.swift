import Darwin
import Foundation

/// The wire format Impuls speaks to a connected iPhone or iPad, and the socket
/// it speaks it over.
///
/// There is no public Apple API for a paired device's battery, and the two
/// paths other applications take are both closed to Impuls: the private
/// `MobileDevice.framework`, and libimobiledevice with its LGPL library and
/// five native dependencies. What is left is the protocol itself, spoken by us,
/// to the `usbmuxd` daemon macOS already runs.
///
/// That daemon's socket is a local UNIX socket — `/var/run/usbmuxd`, world
/// readable and writable, no root, no entitlement, no network. Nothing here
/// opens a TCP connection, and the module's network boundary is untouched.
///
/// Everything in this file is deliberately outside the main actor.

// MARK: - Errors

/// What can go wrong, in terms the interface can act on.
///
/// `notTrusted` is the important one: it is not an error to show, it is a
/// sentence to show — unlock the phone and tap Trust — and it must never
/// surface as a number or a code.
enum MobileDeviceError: Error, Equatable {
    case transportUnavailable
    case timedOut
    case deviceDisconnected
    case malformedResponse(String)
    case payloadTooLarge(Int)
    case notTrusted
    case deviceLocked
    case sessionRequired
    case serviceUnavailable(String)
    case batteryUnavailable
}

// MARK: - Byte channel

/// One connection, as the protocol code sees it.
///
/// An abstraction rather than a socket so the protocol can be tested against a
/// scripted peer: truncated frames, absurd lengths, a peer that closes
/// mid-request and one that never answers are all ordinary test cases here and
/// impossible to arrange with real hardware.
protocol MobileDeviceByteChannel: AnyObject {
    func write(_ data: Data, timeout: TimeInterval) throws
    func read(_ count: Int, timeout: TimeInterval) throws -> Data
    func close()
}

protocol MobileDeviceChannelFactory: Sendable {
    func connect() throws -> MobileDeviceByteChannel
}

/// The real socket.
///
/// Every call carries a deadline. A phone that has just been unplugged, or one
/// that is deciding whether to trust this Mac, can leave a read outstanding
/// forever, and forever is not an acceptable duration for anything the panel
/// waits on.
final class UnixSocketChannel: MobileDeviceByteChannel {
    private var descriptor: Int32

    init(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MobileDeviceError.transportUnavailable }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw MobileDeviceError.transportUnavailable
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { destination in
                for (index, byte) in pathBytes.enumerated() { destination[index] = CChar(bitPattern: byte) }
                destination[pathBytes.count] = 0
            }
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw MobileDeviceError.transportUnavailable
        }
        descriptor = fd
    }

    deinit { close() }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    func write(_ data: Data, timeout: TimeInterval) throws {
        guard descriptor >= 0 else { throw MobileDeviceError.deviceDisconnected }
        try setTimeout(timeout, option: SO_SNDTIMEO)
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { buffer -> Int in
                Darwin.write(descriptor, buffer.baseAddress, buffer.count)
            }
            if written > 0 {
                remaining = remaining.dropFirst(written)
                continue
            }
            throw errno == EAGAIN || errno == EWOULDBLOCK
                ? MobileDeviceError.timedOut
                : MobileDeviceError.deviceDisconnected
        }
    }

    func read(_ count: Int, timeout: TimeInterval) throws -> Data {
        guard descriptor >= 0 else { throw MobileDeviceError.deviceDisconnected }
        guard count > 0 else { return Data() }
        try setTimeout(timeout, option: SO_RCVTIMEO)

        var result = Data()
        result.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: min(count, 32 * 1024))
        while result.count < count {
            let wanted = min(buffer.count, count - result.count)
            let got = buffer.withUnsafeMutableBytes { pointer -> Int in
                Darwin.read(descriptor, pointer.baseAddress, wanted)
            }
            if got > 0 {
                result.append(contentsOf: buffer[0..<got])
                continue
            }
            // Zero means the peer closed — a cable pulled mid-answer.
            if got == 0 { throw MobileDeviceError.deviceDisconnected }
            throw errno == EAGAIN || errno == EWOULDBLOCK
                ? MobileDeviceError.timedOut
                : MobileDeviceError.deviceDisconnected
        }
        return result
    }

    private func setTimeout(_ timeout: TimeInterval, option: Int32) throws {
        var value = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
        )
        guard setsockopt(descriptor, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw MobileDeviceError.transportUnavailable
        }
    }
}

struct UnixSocketChannelFactory: MobileDeviceChannelFactory {
    static let usbmuxdPath = "/var/run/usbmuxd"

    let path: String

    init(path: String = usbmuxdPath) {
        self.path = path
    }

    func connect() throws -> MobileDeviceByteChannel {
        try UnixSocketChannel(path: path)
    }
}

// MARK: - Framing

/// Both framings, as pure functions over bytes.
///
/// A length field arriving from outside is an instruction to allocate memory,
/// so it is treated as hostile until proven otherwise: below a ceiling, above
/// the header it belongs to, and never trusted to describe a plist that turns
/// out to be something else.
enum MobileDeviceFraming {
    /// Generous for a property list describing a handful of devices, and small
    /// enough that a corrupt length cannot ask for a gigabyte.
    static let maximumPayloadBytes = 512 * 1024

    static let usbmuxHeaderBytes = 16
    static let usbmuxPlistVersion: UInt32 = 1
    static let usbmuxPlistMessage: UInt32 = 8

    // MARK: usbmux

    static func encodeUsbmux(_ payload: [String: Any], tag: UInt32) throws -> Data {
        let body = try serialize(payload)
        guard body.count <= maximumPayloadBytes else {
            throw MobileDeviceError.payloadTooLarge(body.count)
        }
        var frame = Data()
        for value in [
            UInt32(usbmuxHeaderBytes + body.count),
            usbmuxPlistVersion,
            usbmuxPlistMessage,
            tag,
        ] {
            withUnsafeBytes(of: value.littleEndian) { frame.append(contentsOf: $0) }
        }
        frame.append(body)
        return frame
    }

    /// How many payload bytes follow a usbmux header.
    static func usbmuxPayloadLength(from header: Data) throws -> Int {
        guard header.count == usbmuxHeaderBytes else {
            throw MobileDeviceError.malformedResponse("short usbmux header")
        }
        let total = header.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
        }
        guard total >= UInt32(usbmuxHeaderBytes) else {
            throw MobileDeviceError.malformedResponse("usbmux frame shorter than its header")
        }
        let payload = Int(total) - usbmuxHeaderBytes
        guard payload <= maximumPayloadBytes else { throw MobileDeviceError.payloadTooLarge(payload) }
        return payload
    }

    // MARK: lockdown

    static func encodeLockdown(_ payload: [String: Any]) throws -> Data {
        let body = try serialize(payload)
        guard body.count <= maximumPayloadBytes else {
            throw MobileDeviceError.payloadTooLarge(body.count)
        }
        var frame = Data()
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(body)
        return frame
    }

    static func lockdownPayloadLength(from header: Data) throws -> Int {
        guard header.count == 4 else {
            throw MobileDeviceError.malformedResponse("short lockdown header")
        }
        let length = header.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian
        }
        guard length > 0 else { throw MobileDeviceError.malformedResponse("empty lockdown frame") }
        guard length <= UInt32(maximumPayloadBytes) else {
            throw MobileDeviceError.payloadTooLarge(Int(length))
        }
        return Int(length)
    }

    // MARK: Payloads

    /// A truncated or non-dictionary payload is a malformed response, not a
    /// crash and not an empty dictionary that later code would read as "the
    /// phone said nothing".
    static func decodePayload(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { throw MobileDeviceError.malformedResponse("empty payload") }
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw MobileDeviceError.malformedResponse("payload is not a property list")
        }
        guard let dictionary = plist as? [String: Any] else {
            throw MobileDeviceError.malformedResponse("payload is not a dictionary")
        }
        return dictionary
    }

    private static func serialize(_ payload: [String: Any]) throws -> Data {
        do {
            return try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        } catch {
            throw MobileDeviceError.malformedResponse("cannot serialise request")
        }
    }
}

// MARK: - Conversation

/// One request/response conversation over a channel.
///
/// Deliberately small: open, ask, read, close. There is no long-lived session,
/// no reconnect loop and no state machine spanning refreshes, because the only
/// thing Impuls wants from a phone is one number, occasionally.
struct MobileDeviceConversation {
    /// Long enough for a phone that is busy, short enough that nothing in the
    /// panel waits on a device that is not going to answer.
    static let defaultTimeout: TimeInterval = 5

    let channel: MobileDeviceByteChannel
    var timeout: TimeInterval = defaultTimeout

    func sendUsbmux(_ payload: [String: Any], tag: UInt32) throws {
        try channel.write(MobileDeviceFraming.encodeUsbmux(payload, tag: tag), timeout: timeout)
    }

    func receiveUsbmux() throws -> [String: Any] {
        let header = try channel.read(MobileDeviceFraming.usbmuxHeaderBytes, timeout: timeout)
        let length = try MobileDeviceFraming.usbmuxPayloadLength(from: header)
        guard length > 0 else { throw MobileDeviceError.malformedResponse("usbmux frame with no payload") }
        return try MobileDeviceFraming.decodePayload(channel.read(length, timeout: timeout))
    }

    func sendLockdown(_ payload: [String: Any]) throws {
        try channel.write(MobileDeviceFraming.encodeLockdown(payload), timeout: timeout)
    }

    func receiveLockdown() throws -> [String: Any] {
        let header = try channel.read(4, timeout: timeout)
        let length = try MobileDeviceFraming.lockdownPayloadLength(from: header)
        return try MobileDeviceFraming.decodePayload(channel.read(length, timeout: timeout))
    }
}
