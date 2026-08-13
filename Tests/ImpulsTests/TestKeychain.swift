import Foundation
import Security
import XCTest
@testable import ImpulsCore

/// The suite's own corner of the login keychain, and the only thing that clears
/// it out again.
///
/// `DeviceIdentityResolver` salts a device identity with a 256-bit key kept as a
/// generic password, which is the right design — it is what keeps a UDID from
/// ever being recoverable from what the app stores. Tests have always pointed it
/// at their own service name rather than the app's, so nothing they did could
/// touch the real identity key. What they never did was take their own item back
/// out: running the suite left a `io.tumanov.impuls.tests.device-identity`
/// password in the developer's keychain, once, forever.
///
/// It is not user data and it was never a security problem. It is litter, and a
/// test that writes to a real system store should clean up after itself.
enum TestKeychain {
    static let service = "io.tumanov.impuls.tests.device-identity"
    /// Every account the suite salts under that service. Kept as a list rather
    /// than deleting the service wholesale, so this can never widen to something
    /// the app owns by someone renaming a constant.
    static let accounts = ["unit-test", "unit-test-network", "unit-test-fallback"]

    static var resolver: DeviceIdentityResolver {
        DeviceIdentityResolver(service: service, account: accounts[0])
    }

    static func removeStoredKeys() {
        for account in accounts {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
        }
    }
}

/// Base class for the cases that salt an identity. Subclassing is the smallest
/// change that cannot be forgotten by the next test to need a resolver.
class DeviceIdentityTestCase: XCTestCase {
    override func tearDown() {
        TestKeychain.removeStoredKeys()
        super.tearDown()
    }
}
