import Foundation
import Security

/// The TLS upgrade lockdownd demands after `StartSession`.
///
/// One narrow adapter, and the only file in Impuls that knows Secure Transport
/// exists. It is legacy API — deprecated in favour of Network.framework — but
/// Network.framework configures TLS when a connection is established and cannot
/// upgrade a stream that is already carrying a protocol, which is exactly what
/// this needs. Secure Transport is public Security-framework API, not a private
/// framework, so it costs nothing in signing or notarization; it costs
/// maintenance, and it is quarantined here so that the cost stays in one file.
///
/// Nothing above this type knows about it: it presents the same
/// `MobileDeviceByteChannel` as a plain socket, so the conversation code is
/// identical before and after the upgrade.
final class LockdownTLSChannel: MobileDeviceByteChannel {
    /// A handshake that has not converged in this long is not going to.
    static let handshakeTimeout: TimeInterval = 10
    /// Belt to the deadline's braces: a peer that keeps returning "would block"
    /// without consuming anything cannot spin here forever.
    static let maximumHandshakeIterations = 256

    private let underlying: MobileDeviceByteChannel
    private let io: IOBox
    private var context: SSLContext?
    private var closed = false

    /// - Parameters:
    ///   - channel: the socket already talking to lockdownd.
    ///   - identity: the client identity built from the pair record, in memory.
    ///   - pinnedCertificates: the device and root certificates from that same
    ///     record. The peer is accepted only if it proves to be one of them.
    init(
        upgrading channel: MobileDeviceByteChannel,
        identity: SecIdentity,
        pinnedCertificates: [SecCertificate],
        timeout: TimeInterval
    ) throws {
        underlying = channel
        io = IOBox(channel: channel, timeout: timeout)

        guard let context = SSLCreateContext(kCFAllocatorDefault, .clientSide, .streamType) else {
            throw MobileDeviceError.transportUnavailable
        }
        self.context = context

        let raw = Unmanaged.passUnretained(io).toOpaque()
        guard SSLSetIOFuncs(context, Self.read, Self.write) == errSecSuccess,
              SSLSetConnection(context, raw) == errSecSuccess,
              SSLSetCertificate(context, [identity] as CFArray) == errSecSuccess,
              // Stop at server authentication and judge the peer ourselves.
              // Without this the handshake would fail on a self-signed device
              // certificate; with it, acceptance is a decision made against the
              // pairing rather than a check switched off.
              SSLSetSessionOption(context, .breakOnServerAuth, true) == errSecSuccess else {
            throw MobileDeviceError.transportUnavailable
        }

        try handshake(pinnedCertificates: pinnedCertificates)
    }

    deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        if let context {
            SSLClose(context)
            self.context = nil
        }
        underlying.close()
    }

    func write(_ data: Data, timeout: TimeInterval) throws {
        guard let context, !closed else { throw MobileDeviceError.deviceDisconnected }
        var offset = 0
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while offset < buffer.count {
                var written = 0
                let status = SSLWrite(context, base.advanced(by: offset), buffer.count - offset, &written)
                offset += written
                if status == errSSLWouldBlock { continue }
                guard status == errSecSuccess else { throw Self.error(for: status) }
            }
        }
    }

    func read(_ count: Int, timeout: TimeInterval) throws -> Data {
        guard let context, !closed else { throw MobileDeviceError.deviceDisconnected }
        guard count > 0 else { return Data() }

        var result = Data()
        result.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: min(count, 32 * 1024))
        while result.count < count {
            var got = 0
            let wanted = min(buffer.count, count - result.count)
            let status = buffer.withUnsafeMutableBytes { pointer -> OSStatus in
                guard let base = pointer.baseAddress else { return errSSLInternal }
                return SSLRead(context, base, wanted, &got)
            }
            if got > 0 { result.append(contentsOf: buffer[0..<got]) }
            if status == errSSLWouldBlock { continue }
            guard status == errSecSuccess else {
                if let failure = io.failure { throw failure }
                throw Self.error(for: status)
            }
        }
        return result
    }

    // MARK: - Handshake

    private func handshake(pinnedCertificates: [SecCertificate]) throws {
        guard let context else { throw MobileDeviceError.transportUnavailable }
        let deadline = Date().addingTimeInterval(Self.handshakeTimeout)
        var iterations = 0
        var validated = false

        while true {
            let status = SSLHandshake(context)
            switch status {
            case errSecSuccess:
                guard validated else { throw MobileDeviceError.serviceUnavailable("peer was never validated") }
                return
            case errSSLPeerAuthCompleted:
                try validatePeer(context, pinnedCertificates: pinnedCertificates)
                validated = true
            case errSSLWouldBlock:
                break
            default:
                if let failure = io.failure { throw failure }
                throw Self.error(for: status)
            }

            iterations += 1
            guard iterations < Self.maximumHandshakeIterations, Date() < deadline else {
                throw MobileDeviceError.timedOut
            }
        }
    }

    /// Accept the paired device, and nothing else.
    ///
    /// Two ways to be satisfied, both real. The ordinary one is a trust
    /// evaluation anchored **only** on the certificates in the pair record. The
    /// fallback is a direct comparison of the peer's leaf certificate against
    /// the device certificate this Mac was given when it paired — pinning,
    /// which is stronger than a generic evaluation and is what actually applies
    /// here: these certificates carry no hostname and are not meant to chain to
    /// a public root.
    ///
    /// What is deliberately absent is the third option: accepting whatever
    /// turned up.
    private func validatePeer(_ context: SSLContext, pinnedCertificates: [SecCertificate]) throws {
        guard !pinnedCertificates.isEmpty else {
            throw MobileDeviceError.serviceUnavailable("pair record has no device certificate")
        }
        var trust: SecTrust?
        guard SSLCopyPeerTrust(context, &trust) == errSecSuccess, let trust else {
            throw MobileDeviceError.serviceUnavailable("peer offered no certificate")
        }

        SecTrustSetAnchorCertificates(trust, pinnedCertificates as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
        if SecTrustEvaluateWithError(trust, nil) { return }

        // Pinning. A lockdown certificate is self-signed, has no subject
        // alternative name and may be older than any policy would like; being
        // byte-for-byte the certificate from our own pair record is a stronger
        // statement than any of that.
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            throw MobileDeviceError.serviceUnavailable("peer certificate unreadable")
        }
        let leafData = SecCertificateCopyData(leaf) as Data
        let matches = pinnedCertificates.contains { SecCertificateCopyData($0) as Data == leafData }
        guard matches else {
            throw MobileDeviceError.serviceUnavailable("peer is not the paired device")
        }
    }

    // MARK: - Secure Transport plumbing

    /// Holds the socket for the C callbacks, and carries a failure back out.
    ///
    /// Secure Transport flattens every I/O problem into one status code, so the
    /// real reason — timed out, peer hung up — is recorded here and rethrown by
    /// the caller instead of being lost.
    private final class IOBox {
        let channel: MobileDeviceByteChannel
        let timeout: TimeInterval
        var failure: MobileDeviceError?

        init(channel: MobileDeviceByteChannel, timeout: TimeInterval) {
            self.channel = channel
            self.timeout = timeout
        }
    }

    private static let read: SSLReadFunc = { connection, data, dataLength in
        let box = Unmanaged<IOBox>.fromOpaque(connection).takeUnretainedValue()
        let wanted = dataLength.pointee
        do {
            let chunk = try box.channel.read(wanted, timeout: box.timeout)
            chunk.withUnsafeBytes { source in
                guard let base = source.baseAddress else { return }
                data.copyMemory(from: base, byteCount: chunk.count)
            }
            dataLength.pointee = chunk.count
            return chunk.count == wanted ? errSecSuccess : errSSLWouldBlock
        } catch {
            box.failure = error as? MobileDeviceError ?? .deviceDisconnected
            dataLength.pointee = 0
            return errSSLClosedAbort
        }
    }

    private static let write: SSLWriteFunc = { connection, data, dataLength in
        let box = Unmanaged<IOBox>.fromOpaque(connection).takeUnretainedValue()
        let count = dataLength.pointee
        let bytes = Data(bytes: data, count: count)
        do {
            try box.channel.write(bytes, timeout: box.timeout)
            return errSecSuccess
        } catch {
            box.failure = error as? MobileDeviceError ?? .deviceDisconnected
            dataLength.pointee = 0
            return errSSLClosedAbort
        }
    }

    /// Status codes become states. The numeric code never reaches the interface
    /// and no certificate or key material appears in any of these.
    private static func error(for status: OSStatus) -> MobileDeviceError {
        switch status {
        case errSSLClosedGraceful, errSSLClosedAbort, errSSLClosedNoNotify:
            return .deviceDisconnected
        case errSSLPeerHandshakeFail, errSSLBadCert, errSSLPeerBadCert, errSSLXCertChainInvalid:
            return .serviceUnavailable("TLS handshake rejected")
        default:
            return .serviceUnavailable("TLS error")
        }
    }
}
