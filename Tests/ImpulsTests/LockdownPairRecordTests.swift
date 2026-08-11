import XCTest
@testable import ImpulsCore

/// The pair record, the PEM inside it, and the identity built from it.
///
/// The certificate and keys below are generated for these tests and belong to
/// nothing: a throwaway self-signed certificate and two unrelated 1024-bit RSA
/// keys. No real pairing material appears in this repository, and none of these
/// tests touch a keychain — which is the property being demonstrated.
final class LockdownPairRecordTests: XCTestCase {
    static let certificate = """
-----BEGIN CERTIFICATE-----
MIICCDCCAXGgAwIBAgIUHEL40zjMaVxDeXcBA9+dsJQ5Yj0wDQYJKoZIhvcNAQEL
BQAwFjEUMBIGA1UEAwwLSW1wdWxzIFRlc3QwHhcNMjYwODExMjA0NDIwWhcNMzYw
ODA4MjA0NDIwWjAWMRQwEgYDVQQDDAtJbXB1bHMgVGVzdDCBnzANBgkqhkiG9w0B
AQEFAAOBjQAwgYkCgYEAr4Wo98qdKI+v2xPLTl20fCP8VyBVUb0gv0hgULEMn7gz
xyzLWB45gudMx0DMm7t3E+vaHtXc10WyO4MOe/MicN7PAdxldYx6pDH95l6AqzWp
ECtY682FSYL0hLrRncC4qEEaLPHZAT5xgMrdwbcWz3BEDZRehU2MHnqX+8iIrjkC
AwEAAaNTMFEwHQYDVR0OBBYEFBiKUrqraNwfGw1+Ydl5VK9sBiWNMB8GA1UdIwQY
MBaAFBiKUrqraNwfGw1+Ydl5VK9sBiWNMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZI
hvcNAQELBQADgYEACNy1/Lv+nrMi7Eq3A7VNTQfRGrtq2IEJBtoWjoHr6rSFrQjU
JaHwsWpOunKus6sNnWaW2EMlQRvKFzaNADjLjiIU/GFMt12Hg8fmCd6+H84GhMKM
4ShkCaQvQR9clYOtKnbBtXRQxhqC5D+CvFwuliINkYpiFxjuRfzTWj1l8V0=
-----END CERTIFICATE-----
"""

    /// PKCS#8 — the envelope a real pair record actually uses, measured on
    /// macOS before this parser was written.
    static let privateKey = """
-----BEGIN PRIVATE KEY-----
MIICeAIBADANBgkqhkiG9w0BAQEFAASCAmIwggJeAgEAAoGBAK+FqPfKnSiPr9sT
y05dtHwj/FcgVVG9IL9IYFCxDJ+4M8csy1geOYLnTMdAzJu7dxPr2h7V3NdFsjuD
DnvzInDezwHcZXWMeqQx/eZegKs1qRArWOvNhUmC9IS60Z3AuKhBGizx2QE+cYDK
3cG3Fs9wRA2UXoVNjB56l/vIiK45AgMBAAECgYEAhwyHUojR3RiZTS3wus48hVvG
116oZujnHmZYvR1MwkOfizt7BcTTqVXAbHr+M0DNQUWyIRGaBwS4OzP+W/5Z20ow
I3NmUh9d9YOOhNXrFsCP5B2JPa0TWCk3+v39A+OK3hZRuykdBLmRAMC6ZKIuZtpg
IoPfrFExyDGXagNWl9ECQQDaBHG1drXg/twSsmtrHEtnAnCYmCD3rRCx0ruIarac
tntK4+nvGisRaEcl43qhOMnoPq2YPyEFRK3O5RdnW7EdAkEAzhnuZ/VBK/FLzYmB
18eNV96klPmV/70YW5eT7kaVlVcWeGs0rKvzmnqgBTqVkg/e+UuwmFDhPpjV0eTX
Ew4izQJATOsYex9g1/rTBj2wrF+VMsinlQ7HQtrqcvKYe2668ttm8Gss09D1tPSH
dZSmZU813RyP/pD3Q3aRo9crxKmS+QJBAJwUeT6TNjKv/qb+Dq25uqmju2HyjYzp
yCt85BObsqYxGJxDG9X0NnxzhwHOtvyxNjv2/RqsjZfZKHxW4CXXG7UCQQCDWsgv
HYe6Dr0RSirn5oieUFT10i9qcTrdN4fiuEcG4bor6gG67wcWf6IFQ9xkuBonj7ij
vWFC1CfmSKwdzxq0
-----END PRIVATE KEY-----
"""

    /// A perfectly valid key that simply is not the one in the certificate.
    static let unrelatedPrivateKey = """
-----BEGIN PRIVATE KEY-----
MIICdgIBADANBgkqhkiG9w0BAQEFAASCAmAwggJcAgEAAoGBAO4TfgBiyx8yZZUB
aYktgD800WlPfnWjIGorI9pYI04fhchKxiAkPXUG7TfkUmJYUAqU0ByBvN1bE4EX
FjZphz8RpIgJE3Q+jGCae+1YbBJE8MjbKkuoSQimR6u/XWlbVSGEQI5grJKcezuj
AOmcvmVbEuMy22wfBEQ5PQSBU6G3AgMBAAECgYAxojCvpekQ7PHOmcfFyI2nH7zU
xrTnk4WrfKjx2VQq8llyw1wA0W1am4ITF++w/xZYzmOAve+A+n7bd9Oyrld6gKLV
5hBKCe31ZJChNqH/cHhIky0tRxCqcKy1S2VWpPIqnrZcmNOlRRxxnZhqcTdLUUHz
hivTwB0w50Nn1D8y6QJBAPlJn+W4miilo9N9Kj2eOr9lzdfqrldHBUn8Vb0QZjwk
HsgfrFtfJG9y9Bp2ct7tjxuQ9HUOrIb2oS4RyyOwz7MCQQD0fJXd81RbfVZVczvb
qEX8E6BuQjXdy/eIARoDE273FGObJvKi/HxiBnLG6jU1D7BLvNODvy86gHlYi7du
2sPtAkEA2iVpfVdr38IDeOEBA+bhNfhah2XgppOJt1LPnKErNdnN7gZ5h4PcmIKZ
xkZ9A0QThWX15jGvHHPaXDxJ7bOeLQJAT4A/v5fDo6iDLXA2U7xJXaoILjJrj78m
s9wf2EY2fDPuG+KzXdqam8mbAyHfwWxjmI1DfoDp260xSGDOeka7FQJAI6yk1k6T
wrvTALwBiInQ8ai9PYAaMOCXpB9mDC+flyfD+LLrV+TEO8uHWxRXugpOQp67f0NE
3QBHAJDqY1vCrw==
-----END PRIVATE KEY-----
"""

    private func record(
        certificate: String? = LockdownPairRecordTests.certificate,
        privateKey: String? = LockdownPairRecordTests.privateKey,
        hostID: String? = "HOST-ID",
        systemBUID: String? = "SYSTEM-BUID"
    ) -> [String: Any] {
        var plist: [String: Any] = [:]
        if let hostID { plist["HostID"] = hostID }
        if let systemBUID { plist["SystemBUID"] = systemBUID }
        if let certificate {
            plist["HostCertificate"] = Data(certificate.utf8)
            plist["DeviceCertificate"] = Data(certificate.utf8)
            plist["RootCertificate"] = Data(certificate.utf8)
        }
        if let privateKey { plist["HostPrivateKey"] = Data(privateKey.utf8) }
        return plist
    }

    // MARK: - Parsing

    func testARealShapedPairRecordParses() throws {
        let parsed = try XCTUnwrap(LockdownPairRecord(plist: record()))

        XCTAssertEqual(parsed.hostID, "HOST-ID")
        XCTAssertEqual(parsed.systemBUID, "SYSTEM-BUID")
        XCTAssertFalse(parsed.hostCertificate.isEmpty)
        XCTAssertFalse(parsed.hostPrivateKey.isEmpty)
        // The device and root certificates are pinned; the host's own is not.
        XCTAssertEqual(parsed.pinnedCertificates().count, 2)
    }

    func testAPKCS8KeyIsUnwrappedToThePKCS1TheSecurityFrameworkWants() throws {
        let der = try XCTUnwrap(PEM.rsaPrivateKeyDER(from: Data(Self.privateKey.utf8)))

        // PKCS#1 RSAPrivateKey begins with a SEQUENCE whose first element is an
        // INTEGER version — and it is shorter than the envelope it came out of.
        XCTAssertEqual(der.first, 0x30)
        let envelope = try XCTUnwrap(PEM.der(from: Data(Self.privateKey.utf8), label: PEM.privateKeyLabel))
        XCTAssertLessThan(der.count, envelope.count)
    }

    func testAMissingFieldMeansNoRecordRatherThanAHalfBuiltOne() {
        XCTAssertNil(LockdownPairRecord(plist: record(hostID: nil)))
        XCTAssertNil(LockdownPairRecord(plist: record(systemBUID: nil)))
        XCTAssertNil(LockdownPairRecord(plist: record(certificate: nil)))
        XCTAssertNil(LockdownPairRecord(plist: record(privateKey: nil)))
        XCTAssertNil(LockdownPairRecord(plist: [:]))
    }

    // MARK: - PEM

    func testMalformedAndMislabelledPEMIsRefused() {
        XCTAssertNil(PEM.der(from: Data("not pem at all".utf8), label: PEM.certificateLabel))
        XCTAssertNil(PEM.der(from: Data(Self.certificate.utf8), label: PEM.rsaPrivateKeyLabel))
        XCTAssertNil(PEM.der(from: Data(Self.privateKey.utf8), label: PEM.certificateLabel))
        XCTAssertNil(PEM.der(from: 42, label: PEM.certificateLabel))
        XCTAssertNil(PEM.der(from: nil, label: PEM.certificateLabel))

        // Header without footer, footer before header, empty body.
        XCTAssertNil(PEM.der(fromPEM: "-----BEGIN CERTIFICATE-----\nAAAA", label: PEM.certificateLabel))
        XCTAssertNil(PEM.der(
            fromPEM: "-----END CERTIFICATE-----\nAAAA\n-----BEGIN CERTIFICATE-----",
            label: PEM.certificateLabel
        ))
        XCTAssertNil(PEM.der(
            fromPEM: "-----BEGIN CERTIFICATE-----\n\n-----END CERTIFICATE-----",
            label: PEM.certificateLabel
        ))
        XCTAssertNil(PEM.der(
            fromPEM: "-----BEGIN CERTIFICATE-----\n!!!not base64!!!\n-----END CERTIFICATE-----",
            label: PEM.certificateLabel
        ))
    }

    func testAnOversizedPEMIsRefusedBeforeItIsDecoded() {
        let huge = "-----BEGIN CERTIFICATE-----\n"
            + String(repeating: "QUFBQQ==", count: 40_000)
            + "\n-----END CERTIFICATE-----"

        XCTAssertNil(PEM.der(fromPEM: huge, label: PEM.certificateLabel))
        XCTAssertNil(PEM.der(from: Data(huge.utf8), label: PEM.certificateLabel))
    }

    // MARK: - DER

    func testTruncatedAndWrongShapedDERIsRefused() throws {
        let valid = try XCTUnwrap(PEM.der(from: Data(Self.privateKey.utf8), label: PEM.privateKeyLabel))

        XCTAssertNotNil(PKCS8.rsaPrivateKey(fromPrivateKeyInfo: valid))
        XCTAssertNil(PKCS8.rsaPrivateKey(fromPrivateKeyInfo: valid.prefix(valid.count / 2)))
        XCTAssertNil(PKCS8.rsaPrivateKey(fromPrivateKeyInfo: Data()))
        XCTAssertNil(PKCS8.rsaPrivateKey(fromPrivateKeyInfo: Data([0x30])))
        // A SEQUENCE whose length runs past the buffer.
        XCTAssertNil(PKCS8.rsaPrivateKey(fromPrivateKeyInfo: Data([0x30, 0x7F, 0x02, 0x01, 0x00])))
        // Not a SEQUENCE at all.
        XCTAssertNil(PKCS8.rsaPrivateKey(fromPrivateKeyInfo: Data([0x04, 0x02, 0x00, 0x00])))
        // A certificate is DER, and is still not a private key.
        let certificateDER = try XCTUnwrap(PEM.der(from: Data(Self.certificate.utf8), label: PEM.certificateLabel))
        XCTAssertNil(PKCS8.rsaPrivateKey(fromPrivateKeyInfo: certificateDER))
    }

    // MARK: - Identity

    func testTheClientIdentityIsBuiltInMemoryWithoutAKeychain() throws {
        let parsed = try XCTUnwrap(LockdownPairRecord(plist: record()))

        // No SecItemAdd, no SecKeychainCreate, no temporary file: the identity
        // comes from SecIdentityCreate, which is public API for exactly this.
        let identity = try parsed.makeIdentity()

        var certificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(identity, &certificate), errSecSuccess)
        XCTAssertNotNil(certificate)
        var key: SecKey?
        XCTAssertEqual(SecIdentityCopyPrivateKey(identity, &key), errSecSuccess)
        XCTAssertNotNil(key)
    }

    /// `SecIdentityCreate` documents that it returns nil for a mismatched pair.
    /// On one machine it did; on a CI runner it did not. The check therefore
    /// belongs to us, and this test proves it is ours: it compares the
    /// certificate's public key with the one derived from the private key, and
    /// does not depend on what the framework decides to do.
    func testAKeyThatDoesNotMatchTheCertificateIsRejected() throws {
        let parsed = try XCTUnwrap(LockdownPairRecord(
            plist: record(privateKey: Self.unrelatedPrivateKey)
        ))

        XCTAssertThrowsError(try parsed.makeIdentity()) { error in
            XCTAssertEqual(
                error as? MobileDeviceError,
                .malformedResponse("certificate and key do not match")
            )
        }
    }

    func testAPairRecordWithNoDeviceCertificateHasNothingToPinAgainst() throws {
        var plist = record()
        plist.removeValue(forKey: "DeviceCertificate")
        plist.removeValue(forKey: "RootCertificate")
        let parsed = try XCTUnwrap(LockdownPairRecord(plist: plist))

        XCTAssertTrue(parsed.pinnedCertificates().isEmpty, "nothing to pin means the peer cannot be accepted")
    }

    // MARK: - Privacy

    /// Nothing that could identify the pairing may appear in anything the
    /// application prints, reports or stores.
    func testNoPairingMaterialCanReachAnOutputSurface() throws {
        let parsed = try XCTUnwrap(LockdownPairRecord(plist: record()))
        let secrets = [
            "HOST-ID",
            "SYSTEM-BUID",
            Self.privateKey,
            Self.certificate,
            "BEGIN PRIVATE KEY",
            "BEGIN CERTIFICATE",
        ]

        // Every error this path can produce, rendered the way a log line would.
        let errors: [MobileDeviceError] = [
            .notTrusted, .deviceLocked, .sessionRequired, .timedOut,
            .deviceDisconnected, .transportUnavailable, .batteryUnavailable,
            .malformedResponse("host private key is not a key"),
            .malformedResponse("certificate and key do not match"),
            .serviceUnavailable("TLS handshake rejected"),
            .serviceUnavailable("peer is not the paired device"),
            .payloadTooLarge(1 << 20),
        ]
        for error in errors {
            let rendered = "\(error)"
            for secret in secrets {
                XCTAssertFalse(rendered.contains(secret), "an error leaked pairing material")
            }
        }

        // And the identity derived from the device is redacted as well.
        let resolver = DeviceIdentityResolver(
            service: "io.tumanov.impuls.tests.device-identity",
            account: "unit-test"
        )
        let identity = try XCTUnwrap(resolver.identity(forRawIdentifier: "00008120-AAAA", kind: .iPhone))
        XCTAssertEqual("\(identity)", "AppleDeviceIdentity(redacted)")
        XCTAssertFalse("\(identity)".contains("00008120-AAAA"))
        XCTAssertFalse(parsed.hostID.isEmpty)
    }

    func testTheMatchingPairIsAccepted() throws {
        let parsed = try XCTUnwrap(LockdownPairRecord(plist: record()))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, parsed.hostCertificate as CFData))
        let key = try XCTUnwrap(SecKeyCreateWithData(
            parsed.hostPrivateKey as CFData,
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            ] as CFDictionary,
            nil
        ))

        XCTAssertTrue(LockdownPairRecord.keyMatchesCertificate(certificate: certificate, privateKey: key))
    }

    func testAnUnrelatedValidKeyIsRejectedByTheComparisonItself() throws {
        let parsed = try XCTUnwrap(LockdownPairRecord(plist: record()))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, parsed.hostCertificate as CFData))
        let unrelatedDER = try XCTUnwrap(PEM.rsaPrivateKeyDER(from: Data(Self.unrelatedPrivateKey.utf8)))
        let unrelated = try XCTUnwrap(SecKeyCreateWithData(
            unrelatedDER as CFData,
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            ] as CFDictionary,
            nil
        ))

        XCTAssertFalse(LockdownPairRecord.keyMatchesCertificate(certificate: certificate, privateKey: unrelated))
    }

    /// A public key that could not be extracted, and a representation that
    /// could not be produced, both reach the comparison as nothing — and
    /// nothing is never a match. Tested at the byte layer because that is where
    /// both failures land, and it does not depend on finding a key the
    /// framework refuses to export.
    func testAFailureToExtractOrRepresentAKeyIsNotAMatch() {
        let bytes = Data([1, 2, 3, 4])

        XCTAssertFalse(LockdownPairRecord.publicKeyBytesMatch(nil, bytes))
        XCTAssertFalse(LockdownPairRecord.publicKeyBytesMatch(bytes, nil))
        XCTAssertFalse(LockdownPairRecord.publicKeyBytesMatch(nil, nil))
        XCTAssertFalse(LockdownPairRecord.publicKeyBytesMatch(Data(), Data()))
        XCTAssertFalse(LockdownPairRecord.publicKeyBytesMatch(bytes, Data([9, 9, 9, 9])))
        XCTAssertTrue(LockdownPairRecord.publicKeyBytesMatch(bytes, bytes))

        XCTAssertNil(LockdownPairRecord.externalRepresentation(of: nil))
    }

    func testAnImplausiblyLargeKeyRepresentationIsNotCompared() {
        let huge = Data(repeating: 7, count: LockdownPairRecord.maximumPublicKeyBytes + 1)

        XCTAssertFalse(LockdownPairRecord.publicKeyBytesMatch(huge, huge))
    }
}
