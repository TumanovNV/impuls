import Foundation
import Security

/// The pairing this Mac already has with a device, held for as long as one
/// request takes and no longer.
///
/// Impuls does not create pairings. This is a read of a record `usbmuxd`
/// already keeps, made because the device will not answer a battery question
/// outside an authenticated session — measured, not assumed: on iOS 26.5.2 the
/// battery domain answers `GetProhibited` without one, and `StartSession`
/// replies `EnableSessionSSL = true`.
///
/// Nothing in here is logged, exported, cached on disk or attached to a report.
/// The type has no `description` worth printing and is deliberately not
/// `Codable`.
struct LockdownPairRecord {
    let hostID: String
    let systemBUID: String
    let hostCertificate: Data
    let hostPrivateKey: Data
    let deviceCertificate: Data?
    let rootCertificate: Data?

    /// Parses the record `usbmuxd` returns. Everything is DER by the time it
    /// leaves this initialiser; the PEM text is not retained.
    init?(plist: [String: Any]) {
        guard let hostID = plist["HostID"] as? String,
              let systemBUID = plist["SystemBUID"] as? String,
              let hostCertificate = PEM.der(from: plist["HostCertificate"], label: PEM.certificateLabel),
              let hostPrivateKey = PEM.rsaPrivateKeyDER(from: plist["HostPrivateKey"])
        else { return nil }

        self.hostID = hostID
        self.systemBUID = systemBUID
        self.hostCertificate = hostCertificate
        self.hostPrivateKey = hostPrivateKey
        deviceCertificate = PEM.der(from: plist["DeviceCertificate"], label: PEM.certificateLabel)
        rootCertificate = PEM.der(from: plist["RootCertificate"], label: PEM.certificateLabel)
    }

    /// Builds the client identity **entirely in memory**.
    ///
    /// `SecIdentityCreate` takes a certificate and a key and returns an
    /// identity, which is the reason none of this needs a keychain. The user's
    /// login keychain is not touched, no temporary keychain file is created,
    /// and the private key never reaches the disk in any form.
    ///
    /// Two things about it were learned the hard way and are worth keeping
    /// written down. It is declared publicly only in the macOS 26 SDK, so the
    /// project builds with Xcode 26 — the symbol itself has been in the
    /// framework since 10.12. And although its documentation says it returns
    /// nil when the key does not match the certificate, that was observed not
    /// to hold on another machine, so the match is checked here rather than
    /// assumed. A mismatched pair would otherwise fail later, inside a TLS
    /// handshake, as something unrecognisable.
    func makeIdentity() throws -> SecIdentity {
        guard let certificate = SecCertificateCreateWithData(nil, hostCertificate as CFData) else {
            throw MobileDeviceError.malformedResponse("host certificate is not a certificate")
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(hostPrivateKey as CFData, attributes as CFDictionary, &error) else {
            error?.release()
            // The error object can carry key material in its description, so it
            // is released without being read.
            throw MobileDeviceError.malformedResponse("host private key is not a key")
        }
        guard Self.keyMatchesCertificate(certificate: certificate, privateKey: key) else {
            throw MobileDeviceError.malformedResponse("certificate and key do not match")
        }
        guard let identity = SecIdentityCreate(kCFAllocatorDefault, certificate, key) else {
            throw MobileDeviceError.malformedResponse("certificate and key do not match")
        }
        return identity
    }

    /// Whether the private key really belongs to the certificate.
    ///
    /// The public key the certificate carries, compared byte for byte with the
    /// one derived from the private key. Anything that cannot be compared —
    /// a key type with no external representation, a certificate with no key —
    /// counts as "no", because an identity that cannot be verified is not one
    /// to hand to a TLS handshake.
    static func keyMatchesCertificate(certificate: SecCertificate, privateKey: SecKey) -> Bool {
        guard let certificateKey = SecCertificateCopyKey(certificate),
              let derivedKey = SecKeyCopyPublicKey(privateKey),
              let fromCertificate = SecKeyCopyExternalRepresentation(certificateKey, nil) as Data?,
              let fromPrivateKey = SecKeyCopyExternalRepresentation(derivedKey, nil) as Data? else {
            return false
        }
        return fromCertificate == fromPrivateKey
    }

    /// The certificates that prove the peer is the device this Mac is paired
    /// with, rather than whatever else turned up on the socket.
    func pinnedCertificates() -> [SecCertificate] {
        [deviceCertificate, rootCertificate]
            .compactMap { $0 }
            .compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    }
}

/// Just enough PEM to read a pair record.
///
/// Deliberately strict: the label must match, the base64 must decode, and the
/// result has a ceiling. A parser that accepted anything here would be handing
/// arbitrary bytes to the Security framework.
enum PEM {
    static let certificateLabel = "CERTIFICATE"
    /// PKCS#1: the RSA key on its own.
    static let rsaPrivateKeyLabel = "RSA PRIVATE KEY"
    /// PKCS#8: the same key inside an algorithm envelope. This is what a pair
    /// record actually contains on current macOS — measured, after the PKCS#1
    /// label failed to match anything.
    static let privateKeyLabel = "PRIVATE KEY"
    /// Certificates and RSA keys in a pair record are a few kilobytes. 64 KB is
    /// far above anything legitimate and far below anything dangerous.
    static let maximumDERBytes = 64 * 1024

    static func der(from value: Any?, label: String) -> Data? {
        let text: String
        switch value {
        case let data as Data:
            guard data.count <= maximumDERBytes * 2,
                  let decoded = String(data: data, encoding: .utf8) else { return nil }
            text = decoded
        case let string as String:
            guard string.utf8.count <= maximumDERBytes * 2 else { return nil }
            text = string
        default:
            return nil
        }
        return der(fromPEM: text, label: label)
    }

    static func der(fromPEM text: String, label: String) -> Data? {
        let header = "-----BEGIN \(label)-----"
        let footer = "-----END \(label)-----"
        guard let start = text.range(of: header),
              let end = text.range(of: footer),
              start.upperBound <= end.lowerBound else { return nil }

        let body = text[start.upperBound..<end.lowerBound]
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard !body.isEmpty,
              let der = Data(base64Encoded: body),
              !der.isEmpty,
              der.count <= maximumDERBytes else { return nil }
        return der
    }

    /// The RSA key, whichever envelope it arrived in.
    ///
    /// `SecKeyCreateWithData` with `kSecAttrKeyTypeRSA` wants PKCS#1, and a
    /// pair record carries PKCS#8, so the envelope is opened here rather than
    /// by handing the Security framework something it would reject.
    static func rsaPrivateKeyDER(from value: Any?) -> Data? {
        if let pkcs1 = der(from: value, label: rsaPrivateKeyLabel) { return pkcs1 }
        guard let pkcs8 = der(from: value, label: privateKeyLabel) else { return nil }
        return PKCS8.rsaPrivateKey(fromPrivateKeyInfo: pkcs8)
    }
}

/// Just enough DER to open a PKCS#8 envelope.
///
/// ```text
/// PrivateKeyInfo ::= SEQUENCE {
///     version              INTEGER,
///     privateKeyAlgorithm  AlgorithmIdentifier,
///     privateKey           OCTET STRING   -- PKCS#1 RSAPrivateKey
/// }
/// ```
///
/// A hand-written parser for a fixed, three-field structure, with every length
/// bounded by the buffer it came from. It refuses anything it does not
/// recognise rather than guessing — including a key that is not RSA, which
/// would otherwise be handed to an RSA constructor.
enum PKCS8 {
    /// `rsaEncryption`, 1.2.840.113549.1.1.1.
    static let rsaOID = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])

    static func rsaPrivateKey(fromPrivateKeyInfo der: Data) -> Data? {
        var reader = DERReader(der)
        guard var body = reader.readSequence(),
              body.readInteger() != nil,
              let algorithm = body.readSequence(),
              algorithm.containsOID(rsaOID),
              let key = body.readOctetString(),
              !key.isEmpty else { return nil }
        return key
    }
}

/// A cursor over DER bytes. Every read is length-checked against what remains.
private struct DERReader {
    private let bytes: Data
    private var index: Int

    init(_ data: Data) {
        bytes = data
        index = data.startIndex
    }

    mutating func readSequence() -> DERReader? { readConstructed(tag: 0x30) }

    mutating func readInteger() -> Data? { readPrimitive(tag: 0x02) }

    mutating func readOctetString() -> Data? { readPrimitive(tag: 0x04) }

    /// Whether an object identifier with these contents appears at this level.
    func containsOID(_ oid: Data) -> Bool {
        var scan = self
        while let object = scan.readPrimitive(tag: 0x06) {
            if object == oid { return true }
        }
        return false
    }

    private mutating func readConstructed(tag: UInt8) -> DERReader? {
        guard let content = readValue(tag: tag) else { return nil }
        return DERReader(content)
    }

    private mutating func readPrimitive(tag: UInt8) -> Data? {
        readValue(tag: tag)
    }

    private mutating func readValue(tag: UInt8) -> Data? {
        guard index < bytes.endIndex, bytes[index] == tag else { return nil }
        var cursor = index + 1
        guard cursor < bytes.endIndex else { return nil }

        var length = 0
        let first = bytes[cursor]
        cursor += 1
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            // Four bytes describe more than any structure here can legitimately
            // be, and zero bytes is the indefinite form DER forbids.
            guard count > 0, count <= 4, cursor + count <= bytes.endIndex else { return nil }
            for offset in 0..<count {
                length = (length << 8) | Int(bytes[cursor + offset])
            }
            cursor += count
        }
        guard length >= 0, cursor + length <= bytes.endIndex else { return nil }

        let value = bytes.subdata(in: cursor..<(cursor + length))
        index = cursor + length
        return value
    }
}
