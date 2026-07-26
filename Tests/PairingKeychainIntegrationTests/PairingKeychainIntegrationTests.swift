import Foundation
import XCTest
@testable import FoundryXKit

final class PairingKeychainIntegrationTests: XCTestCase {
    func testAccountQualifiedSecretsRoundTripInHostedIOSKeychain() throws {
        let service =
            "com.goforgeit.foundryx.pairing-keychain-proof.\(UUID().uuidString)"
        let firstAccount = "acct-first"
        let secondAccount = "acct-second"
        let store = SystemPairingSecretStore()
        defer {
            _ = store.remove(service: service, account: firstAccount)
            _ = store.remove(service: service, account: secondAccount)
        }

        XCTAssertTrue(store.add(
            "first-original",
            service: service,
            account: firstAccount))
        XCTAssertTrue(store.add(
            "second-secret",
            service: service,
            account: secondAccount))
        XCTAssertTrue(store.replace(
            "first-replacement",
            service: service,
            account: firstAccount))

        XCTAssertEqual(
            store.read(service: service, account: firstAccount),
            "first-replacement")
        XCTAssertEqual(
            store.read(service: service, account: secondAccount),
            "second-secret")
        XCTAssertTrue(store.remove(
            service: service,
            account: firstAccount))
        XCTAssertNil(store.read(
            service: service,
            account: firstAccount))
        XCTAssertEqual(
            store.read(service: service, account: secondAccount),
            "second-secret")
    }
}
